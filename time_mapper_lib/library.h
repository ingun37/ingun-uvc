#ifndef TIME_MAPPER_LIB_LIBRARY_H
#define TIME_MAPPER_LIB_LIBRARY_H

#include <cstdint>
#include <filesystem>
#include <functional>
#include <optional>
#include <string>
#include <vector>

namespace time_mapper {

struct Region {
    int x;
    int y;
    int width;
    int height;
};

struct GameTimeEntry {
    int game_second;
    double start_seconds;
    double end_seconds; // Exclusive.
};

// Chronological video ranges. Game seconds can repeat across periods or gaps.
using GameTimeMapping = std::vector<GameTimeEntry>;

using OcrCallback = std::function<std::optional<int>(
    const std::vector<std::uint8_t>& rgb, int width, int height)>;

// Called after each sampled crop with video time, raw OCR text, parsed game
// second (if valid), and OCR duration in seconds.
using ProgressCallback = std::function<void(
    double, const std::string&, std::optional<int>, double)>;

GameTimeMapping map_gametime_to_videotime(
    const std::filesystem::path& video_path, Region region,
    const std::filesystem::path& output_json_path);

GameTimeMapping map_gametime_to_videotime(
    const std::filesystem::path& video_path, Region region,
    const std::filesystem::path& output_json_path,
    const ProgressCallback& progress);

// Allows a caller to provide an OCR implementation, including for tests.
GameTimeMapping map_gametime_to_videotime(
    const std::filesystem::path& video_path, Region region,
    const std::filesystem::path& output_json_path,
    const OcrCallback& recognize);

} // namespace time_mapper

#endif // TIME_MAPPER_LIB_LIBRARY_H
