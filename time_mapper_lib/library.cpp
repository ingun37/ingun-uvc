#include "library.h"

#include <algorithm>
#include <array>
#include <cerrno>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <stdexcept>
#include <string>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

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
        pid_ = fork();
        if (pid_ < 0) {
            close(sockets[0]);
            close(sockets[1]);
            throw std::runtime_error("Could not start OCR worker");
        }
        if (pid_ == 0) {
            close(sockets[0]);
            if (dup2(sockets[1], STDIN_FILENO) < 0 ||
                dup2(sockets[1], STDOUT_FILENO) < 0) _exit(127);
            close(sockets[1]);
            const char* python = std::getenv("TIME_MAPPER_PYTHON");
            if (!python || !*python) python = TIME_MAPPER_PYTHON;
            const std::string width = std::to_string(region.width);
            const std::string height = std::to_string(region.height);
            execl(python, python, "-u", TIME_MAPPER_OCR_SCRIPT,
                  width.c_str(), height.c_str(), static_cast<char*>(nullptr));
            _exit(127);
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

void add_sample(GameTimeMap& result, int game_second,
                double start, double end) {
    auto& ranges = result[game_second];
    if (!ranges.empty() && start <= ranges.back().end_seconds + 0.000001) {
        ranges.back().end_seconds = std::max(ranges.back().end_seconds, end);
    } else {
        ranges.push_back({start, end});
    }
}

} // namespace

GameTimeMap map_gametime_to_videotime(
    const std::filesystem::path& video_path, Region region,
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
    GameTimeMap result;
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
    return result;
}

GameTimeMap map_gametime_to_videotime(
    const std::filesystem::path& video_path, Region region) {
    PythonOcr worker(region);
    return map_gametime_to_videotime(video_path, region,
        [&worker](const std::vector<std::uint8_t>& rgb, int, int) {
            return worker.recognize(rgb);
        });
}

} // namespace time_mapper
