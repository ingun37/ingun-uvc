#include "library.h"

#include <algorithm>
#include <array>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <memory>
#include <iomanip>
#include <nlohmann/json.hpp>
#include <spawn.h>
#include <stdexcept>
#include <string>
#include <sstream>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

extern char** environ;

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>
}

#ifndef TIME_MAPPER_OCR_SCRIPT
#error TIME_MAPPER_OCR_SCRIPT must be defined by the build
#endif
#ifndef TIME_MAPPER_PYTHON
#error TIME_MAPPER_PYTHON must be defined by the build
#endif

namespace time_mapper {
namespace {

constexpr double sample_interval = 0.5;
using Clock = std::chrono::steady_clock;

double milliseconds(Clock::time_point start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}

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

void write_all(int fd, const void* data, std::size_t size) {
    const auto* bytes = static_cast<const std::uint8_t*>(data);
    while (size) {
#ifdef MSG_NOSIGNAL
        const auto written = send(fd, bytes, size, MSG_NOSIGNAL);
#else
        const auto written = send(fd, bytes, size, 0);
#endif
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) throw std::runtime_error("OCR worker disconnected while sending a frame");
        bytes += written;
        size -= static_cast<std::size_t>(written);
    }
}

std::string read_line(int fd) {
    std::string line;
    char character;
    while (line.size() < 128) {
        const auto count = recv(fd, &character, 1, 0);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) throw std::runtime_error("OCR worker disconnected while reading a result");
        if (character == '\n') return line;
        line += character;
    }
    throw std::runtime_error("OCR worker returned an oversized result");
}

class PythonOcr {
public:
    explicit PythonOcr(Region region) {
        int sockets[2];
        if (socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) != 0)
            throw std::runtime_error("Could not create OCR worker channel");
#ifdef SO_NOSIGPIPE
        int enabled = 1;
        setsockopt(sockets[0], SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));
#endif
        posix_spawn_file_actions_t actions;
        int spawn_status = posix_spawn_file_actions_init(&actions);
        if (spawn_status != 0) {
            close(sockets[0]);
            close(sockets[1]);
            throw std::runtime_error("Could not prepare OCR worker: " +
                                     std::string(std::strerror(spawn_status)));
        }
        const auto destroy_actions = [&] { posix_spawn_file_actions_destroy(&actions); };
        if (spawn_status == 0) spawn_status = posix_spawn_file_actions_adddup2(
            &actions, sockets[1], STDIN_FILENO);
        if (spawn_status == 0) spawn_status = posix_spawn_file_actions_adddup2(
            &actions, sockets[1], STDOUT_FILENO);
        if (spawn_status == 0) spawn_status = posix_spawn_file_actions_addclose(
            &actions, sockets[0]);
        if (spawn_status == 0) spawn_status = posix_spawn_file_actions_addclose(
            &actions, sockets[1]);
        const char* python = std::getenv("TIME_MAPPER_PYTHON");
        if (!python || !*python) python = TIME_MAPPER_PYTHON;
        const std::string width = std::to_string(region.width);
        const std::string height = std::to_string(region.height);
        const std::array<char*, 6> arguments{
            const_cast<char*>(python), const_cast<char*>("-u"),
            const_cast<char*>(TIME_MAPPER_OCR_SCRIPT),
            const_cast<char*>(width.c_str()), const_cast<char*>(height.c_str()), nullptr
        };
        if (spawn_status == 0)
            spawn_status = posix_spawn(&pid_, python, &actions, nullptr,
                                       arguments.data(), environ);
        destroy_actions();
        if (spawn_status != 0) {
            close(sockets[0]);
            close(sockets[1]);
            throw std::runtime_error("Could not start OCR worker: " +
                                     std::string(std::strerror(spawn_status)));
        }
        close(sockets[1]);
        fd_ = sockets[0];
        try {
            if (read_line(fd_) != "READY")
                throw std::runtime_error("OCR worker failed to initialize");
        } catch (...) {
            close(fd_);
            waitpid(pid_, nullptr, 0);
            fd_ = -1;
            pid_ = -1;
            throw;
        }
    }

    PythonOcr(const PythonOcr&) = delete;
    PythonOcr& operator=(const PythonOcr&) = delete;

    ~PythonOcr() {
        if (fd_ >= 0) close(fd_);
        if (pid_ > 0) {
            int status;
            while (waitpid(pid_, &status, 0) < 0 && errno == EINTR) {}
        }
    }

    std::optional<int> recognize(const std::vector<std::uint8_t>& rgb) const {
        write_all(fd_, rgb.data(), rgb.size());
        const auto result = read_line(fd_);
        if (result == "-") return std::nullopt;
        std::size_t parsed = 0;
        const int seconds = std::stoi(result, &parsed);
        if (parsed != result.size() || seconds < 0)
            throw std::runtime_error("Invalid OCR worker result: " + result);
        return seconds;
    }

private:
    int fd_ = -1;
    pid_t pid_ = -1;
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
    const OcrCallback& recognize, const LogCallback& log) {
    const auto report = [&](const std::string& message) { if (log) log(message); };
    if (region.x < 0 || region.y < 0 || region.width <= 0 || region.height <= 0)
        throw std::invalid_argument("Region must have nonnegative origin and positive size");
    if (!recognize) throw std::invalid_argument("OCR callback is empty");
    report("Opening video: " + video_path.filename().string());

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
    report("Video ready: " + std::to_string(codec->width) + " × " +
           std::to_string(codec->height) + "; sampling every 0.5 seconds");

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
    double decode_ms = 0.0;
    double total_decode_ms = 0.0;
    double total_convert_ms = 0.0;
    double total_crop_ms = 0.0;
    double total_ocr_ms = 0.0;
    std::size_t sample_count = 0;

    auto consume = [&] {
        while (true) {
            const auto decode_start = Clock::now();
            const int status = avcodec_receive_frame(codec.get(), frame.get());
            decode_ms += milliseconds(decode_start);
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
            const auto convert_start = Clock::now();
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
            const double convert_ms = milliseconds(convert_start);
            const auto crop_start = Clock::now();
            std::vector<std::uint8_t> crop(static_cast<std::size_t>(region.width) *
                                            region.height * 3);
            for (int row = 0; row < region.height; ++row) {
                const auto offset = (static_cast<std::size_t>(region.y + row) *
                                     codec->width + region.x) * 3;
                std::memcpy(crop.data() + static_cast<std::size_t>(row) *
                            region.width * 3, image.data() + offset,
                            static_cast<std::size_t>(region.width) * 3);
            }
            const double crop_ms = milliseconds(crop_start);
            const auto ocr_start = Clock::now();
            const auto game_second = recognize(crop, region.width, region.height);
            const double ocr_ms = milliseconds(ocr_start);
            total_decode_ms += decode_ms;
            total_convert_ms += convert_ms;
            total_crop_ms += crop_ms;
            total_ocr_ms += ocr_ms;
            ++sample_count;
            if (log) {
                std::ostringstream line;
                line << std::fixed << std::setprecision(1) << next_sample
                     << "s → ";
                if (game_second) line << "game clock " << *game_second << "s";
                else line << "no clock detected";
                line << std::setprecision(2) << " | decode " << decode_ms
                     << " ms, RGB convert " << convert_ms << " ms, crop "
                     << crop_ms << " ms, OCR " << ocr_ms << " ms";
                report(line.str());
            }
            decode_ms = 0.0;
            if (game_second)
                add_sample(result, *game_second, next_sample,
                           std::min(next_sample + sample_interval, duration));
            next_sample += sample_interval;
        }
    };

    while (true) {
        const auto read_start = Clock::now();
        const int status = av_read_frame(format.get(), packet.get());
        decode_ms += milliseconds(read_start);
        if (status == AVERROR_EOF) break;
        check_ffmpeg(status, "Reading video packet");
        if (packet->stream_index == stream_index) {
            const auto send_start = Clock::now();
            check_ffmpeg(avcodec_send_packet(codec.get(), packet.get()), "Sending video packet");
            decode_ms += milliseconds(send_start);
            consume();
        }
        av_packet_unref(packet.get());
    }
    const auto flush_start = Clock::now();
    check_ffmpeg(avcodec_send_packet(codec.get(), nullptr), "Flushing video decoder");
    decode_ms += milliseconds(flush_start);
    consume();
    if (log) {
        std::ostringstream summary;
        summary << std::fixed << std::setprecision(1) << "Timing for " << sample_count
                << " samples: decode " << total_decode_ms << " ms, RGB convert "
                << total_convert_ms << " ms, crop " << total_crop_ms
                << " ms, OCR " << total_ocr_ms << " ms";
        report(summary.str());
    }
    report("Writing " + std::to_string(result.size()) + " mapping ranges");
    write_mapping_json(result, output_json_path);
    report("Mapping saved: " + output_json_path.filename().string());
    return result;
}

GameTimeMapping map_gametime_to_videotime(
    const std::filesystem::path& video_path, Region region,
    const std::filesystem::path& output_json_path, const LogCallback& log) {
    if (log) log("Starting OCR worker");
    const auto worker_start = Clock::now();
    PythonOcr worker(region);
    if (log) {
        std::ostringstream line;
        line << std::fixed << std::setprecision(1)
             << "OCR worker ready in " << milliseconds(worker_start) << " ms";
        log(line.str());
    }
    return map_gametime_to_videotime(video_path, region, output_json_path,
        [&worker](const std::vector<std::uint8_t>& rgb, int, int) {
            return worker.recognize(rgb);
        }, log);
}

} // namespace time_mapper
