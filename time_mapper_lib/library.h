#ifndef TIME_MAPPER_LIB_LIBRARY_H
#define TIME_MAPPER_LIB_LIBRARY_H

#include <cstdint>
#include <filesystem>
#include <functional>
#include <map>
#include <optional>
#include <vector>

namespace time_mapper {

struct Region {
    int x;
    int y;
    int width;
    int height;
};

struct VideoTimeRange {
    double start_seconds;
    double end_seconds; // Exclusive.
};

// Keys are whole game seconds remaining. A clock value may have several
// disjoint video ranges (for example, across periods or replay segments).
using GameTimeMap = std::map<int, std::vector<VideoTimeRange>>;

using OcrCallback = std::function<std::optional<int>(
    const std::vector<std::uint8_t>& rgb, int width, int height)>;

GameTimeMap map_gametime_to_videotime(
    const std::filesystem::path& video_path, Region region);

// Allows a caller to provide an OCR implementation, including for tests.
GameTimeMap map_gametime_to_videotime(
    const std::filesystem::path& video_path, Region region,
    const OcrCallback& recognize);

} // namespace time_mapper

#endif // TIME_MAPPER_LIB_LIBRARY_H
