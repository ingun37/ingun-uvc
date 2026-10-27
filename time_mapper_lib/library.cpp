#include "library.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <fstream>
#include <memory>
#include <nlohmann/json.hpp>
#include <regex>
#include <stdexcept>
#include <string>
#include <tesseract/baseapi.h>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>
}

namespace time_mapper {
namespace {

constexpr double sample_interval = 0.5;

void check_ffmpeg(int result, const char* action) {
    if (result < 0) {
        std::array<char, AV_ERROR_MAX_STRING_SIZE> message{};
        av_strerror(result, message.data(), message.size());
        throw std::runtime_error(std::string(action) + ": " + message.data());
    }
}

struct FormatDeleter {
    void operator()(AVFormatContext* context) const { avformat_close_input(&context); }
};
struct CodecDeleter {
    void operator()(AVCodecContext* context) const { avcodec_free_context(&context); }
};
struct FrameDeleter {
    void operator()(AVFrame* frame) const { av_frame_free(&frame); }
};
struct PacketDeleter {
    void operator()(AVPacket* packet) const { av_packet_free(&packet); }
};
struct ScaleDeleter {
    void operator()(SwsContext* context) const { sws_freeContext(context); }
};

std::optional<int> parse_game_time(std::string text) {
    text = std::regex_replace(text, std::regex(R"(\s*([:.])\s*)"), "$1");
    static const std::regex clock(R"((^|[^0-9])(?:(\d{1,2}):(\d{2})|:?(\d{2})\.(\d))(?=$|[^0-9]))");
    std::smatch match;
    if (!std::regex_search(text, match, clock)) return std::nullopt;
    const int minutes = match[2].matched ? std::stoi(match[2].str()) : 0;
    const int seconds = std::stoi(match[2].matched ? match[3].str() : match[4].str());
    if (seconds >= 60) return std::nullopt;
    return minutes * 60 + seconds;
}

class TesseractOcr {
public:
    TesseractOcr() {
        if (engine_.Init(nullptr, "eng", tesseract::OEM_LSTM_ONLY) != 0)
            throw std::runtime_error("Could not initialize Tesseract OCR (eng trained data required)");
        engine_.SetPageSegMode(tesseract::PSM_SINGLE_LINE);
        engine_.SetVariable("tessedit_char_whitelist", "0123456789:.");
    }

    std::optional<int> recognize(const std::vector<std::uint8_t>& rgb,
                                 int width, int height) {
        engine_.SetImage(rgb.data(), width, height, 3, width * 3);
        std::unique_ptr<char[]> text(engine_.GetUTF8Text());
        if (!text) throw std::runtime_error("Tesseract OCR failed to read a frame");
        const auto result = parse_game_time(text.get());
        engine_.Clear();
        return result;
    }

private:
    tesseract::TessBaseAPI engine_;
};

void add_sample(GameTimeMapping& result, int game_second,
                double start, double end) {
    if (!result.empty() && result.back().game_second == game_second &&
        start <= result.back().end_seconds + 0.000001) {
        result.back().end_seconds = std::max(result.back().end_seconds, end);
    } else {
        result.push_back({game_second, start, end});
    }
}

void write_mapping_json(const GameTimeMapping& mapping,
                        const std::filesystem::path& output_path) {
    nlohmann::json document = nlohmann::json::array();
    for (const auto& entry : mapping) {
        document.push_back({
            {"game_second", entry.game_second},
            {"start_seconds", entry.start_seconds},
            {"end_seconds", entry.end_seconds},
        });
    }
    std::ofstream output(output_path);
    if (!output) throw std::runtime_error("Could not open mapping JSON: " + output_path.string());
    output << document.dump(2) << '\n';
    if (!output) throw std::runtime_error("Could not write mapping JSON: " + output_path.string());
}

} // namespace

GameTimeMapping map_gametime_to_videotime(
    const std::filesystem::path& video_path, Region region,
    const std::filesystem::path& output_json_path,
    const OcrCallback& recognize) {
    if (region.x < 0 || region.y < 0 || region.width <= 0 || region.height <= 0)
        throw std::invalid_argument("Region must have nonnegative origin and positive size");
    if (!recognize) throw std::invalid_argument("OCR callback is empty");

    AVFormatContext* input = nullptr;
    check_ffmpeg(avformat_open_input(&input, video_path.string().c_str(), nullptr, nullptr),
                 "Opening video");
    std::unique_ptr<AVFormatContext, FormatDeleter> format(input);
    check_ffmpeg(avformat_find_stream_info(format.get(), nullptr), "Reading video streams");
    const int stream_index = av_find_best_stream(format.get(), AVMEDIA_TYPE_VIDEO,
                                                  -1, -1, nullptr, 0);
    check_ffmpeg(stream_index, "Finding video stream");
    const AVStream* stream = format->streams[stream_index];
    const AVCodec* decoder = avcodec_find_decoder(stream->codecpar->codec_id);
    if (!decoder) throw std::runtime_error("Video decoder is unavailable");
    std::unique_ptr<AVCodecContext, CodecDeleter> codec(avcodec_alloc_context3(decoder));
    if (!codec) throw std::bad_alloc();
    check_ffmpeg(avcodec_parameters_to_context(codec.get(), stream->codecpar),
                 "Setting up video decoder");
    check_ffmpeg(avcodec_open2(codec.get(), decoder, nullptr), "Opening video decoder");
    if (region.x > codec->width || region.width > codec->width - region.x ||
        region.y > codec->height || region.height > codec->height - region.y)
        throw std::invalid_argument("Region lies outside the video frame");

    std::unique_ptr<AVFrame, FrameDeleter> frame(av_frame_alloc());
    std::unique_ptr<AVPacket, PacketDeleter> packet(av_packet_alloc());
    if (!frame || !packet) throw std::bad_alloc();
    const double duration = format->duration != AV_NOPTS_VALUE
        ? static_cast<double>(format->duration) / AV_TIME_BASE
        : (stream->duration != AV_NOPTS_VALUE
            ? stream->duration * av_q2d(stream->time_base) : INFINITY);
    double next_sample = 0.0;
    GameTimeMapping result;
    std::unique_ptr<SwsContext, ScaleDeleter> scaler;

    auto consume = [&] {
        while (true) {
            const int status = avcodec_receive_frame(codec.get(), frame.get());
            if (status == AVERROR(EAGAIN) || status == AVERROR_EOF) break;
            check_ffmpeg(status, "Decoding frame");
            const auto timestamp = frame->best_effort_timestamp;
            if (timestamp == AV_NOPTS_VALUE) continue;
            const auto stream_start = stream->start_time == AV_NOPTS_VALUE ? 0 : stream->start_time;
            const double video_seconds = (timestamp - stream_start) *
                                         av_q2d(stream->time_base);
            if (video_seconds + 0.000001 < next_sample ||
                next_sample >= duration) continue;
            // A frame after a timestamp gap must not stand in for every missed sample.
            if (video_seconds >= next_sample + sample_interval)
                next_sample = std::floor(video_seconds / sample_interval) * sample_interval;
            if (next_sample >= duration) continue;
            scaler.reset(sws_getCachedContext(scaler.release(), codec->width,
                codec->height, codec->pix_fmt, codec->width, codec->height,
                AV_PIX_FMT_RGB24, SWS_BILINEAR, nullptr, nullptr, nullptr));
            if (!scaler) throw std::runtime_error("Could not convert video frame to RGB");
            std::vector<std::uint8_t> image(static_cast<std::size_t>(codec->width) *
                                            codec->height * 3);
            std::uint8_t* destination[] = {image.data()};
            const int stride[] = {codec->width * 3};
            check_ffmpeg(sws_scale(scaler.get(), frame->data, frame->linesize, 0,
                                   codec->height, destination, stride), "Converting frame");
            std::vector<std::uint8_t> crop(static_cast<std::size_t>(region.width) *
                                            region.height * 3);
            for (int row = 0; row < region.height; ++row) {
                const auto offset = (static_cast<std::size_t>(region.y + row) *
                                     codec->width + region.x) * 3;
                std::memcpy(crop.data() + static_cast<std::size_t>(row) *
                            region.width * 3, image.data() + offset,
                            static_cast<std::size_t>(region.width) * 3);
            }
            if (const auto game_second = recognize(crop, region.width, region.height))
                add_sample(result, *game_second, next_sample,
                           std::min(next_sample + sample_interval, duration));
            next_sample += sample_interval;
        }
    };

    while (true) {
        const int status = av_read_frame(format.get(), packet.get());
        if (status == AVERROR_EOF) break;
        check_ffmpeg(status, "Reading video packet");
        if (packet->stream_index == stream_index) {
            check_ffmpeg(avcodec_send_packet(codec.get(), packet.get()), "Sending video packet");
            consume();
        }
        av_packet_unref(packet.get());
    }
    check_ffmpeg(avcodec_send_packet(codec.get(), nullptr), "Flushing video decoder");
    consume();
    write_mapping_json(result, output_json_path);
    return result;
}

GameTimeMapping map_gametime_to_videotime(
    const std::filesystem::path& video_path, Region region,
    const std::filesystem::path& output_json_path) {
    TesseractOcr worker;
    return map_gametime_to_videotime(video_path, region, output_json_path,
        [&worker](const std::vector<std::uint8_t>& rgb, int width, int height) {
            return worker.recognize(rgb, width, height);
        });
}

} // namespace time_mapper
