#include "library.h"

#include <cassert>
#include <cmath>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

using namespace time_mapper;

namespace {

void near(double actual, double expected) {
    if (std::abs(actual - expected) > 0.001)
        throw std::runtime_error("Unexpected video time range");
}

void exercise_video(const char* filename, double duration) {
    const auto path = std::filesystem::path(TEST_DATA_DIR) / filename;
    int calls = 0;
    auto result = map_gametime_to_videotime(path, {75, 8, 100, 58},
        [&](const std::vector<std::uint8_t>& rgb, int width, int height)
            -> std::optional<int> {
            if (width != 100 || height != 58 || rgb.size() != 17400)
                throw std::runtime_error("Incorrect crop dimensions");
            bool has_pixels = false;
            for (const auto value : rgb) has_pixels |= value != 0;
            if (!has_pixels) throw std::runtime_error("Empty video crop");
            const int index = calls++;
            if (index == 3) return std::nullopt; // Missing clock: a gap.
            if (index == 6) return 42;            // Same second after gap.
            return index < 4 ? 42 : 41;
        });

    const int expected_samples = static_cast<int>(std::ceil(duration / 0.5));
    if (calls != expected_samples)
        throw std::runtime_error("Video was not sampled every 0.5 seconds");
    const auto& forty_two = result.at(42);
    if (forty_two.size() != 2) throw std::runtime_error("Gap was incorrectly merged");
    near(forty_two[0].start_seconds, 0.0);
    near(forty_two[0].end_seconds, 1.5);
    near(forty_two[1].start_seconds, 3.0);
    near(forty_two[1].end_seconds, 3.5);
    const auto& forty_one = result.at(41);
    near(forty_one[0].start_seconds, 2.0);
    near(forty_one.back().end_seconds, duration);
}

} // namespace

int main() {
    exercise_video("minutes-seconds.mp4", 19.452767);
    exercise_video("seconds-fractional.mp4", 7.941267);
    try {
        map_gametime_to_videotime(
            std::filesystem::path(TEST_DATA_DIR) / "minutes-seconds.mp4",
            {240, 0, 10, 10},
            [](const auto&, int, int) -> std::optional<int> { return 0; });
        throw std::runtime_error("Out of bounds region was accepted");
    } catch (const std::invalid_argument&) {
    }
    if (std::getenv("TIME_MAPPER_LIVE_OCR")) {
        for (const char* filename : {"minutes-seconds.mp4", "seconds-fractional.mp4"}) {
            const auto mapping = map_gametime_to_videotime(
                std::filesystem::path(TEST_DATA_DIR) / filename, {0, 0, 242, 80});
            if (mapping.empty()) throw std::runtime_error("Live OCR found no game clocks");
            if (std::string(filename) == "minutes-seconds.mp4") {
                near(mapping.at(440).at(0).start_seconds, 2.0); // 7:20
                near(mapping.at(440).at(0).end_seconds, 3.0);
            } else {
                near(mapping.at(22).at(0).start_seconds, 1.5); // :22.x
                near(mapping.at(22).at(0).end_seconds, 2.5);
            }
            std::cout << filename << ": " << mapping.size() << " clock seconds\n";
            for (const auto& [second, ranges] : mapping)
                for (const auto& range : ranges)
                    std::cout << "  " << second << " -> [" << range.start_seconds
                              << ", " << range.end_seconds << ")\n";
        }
    }
    std::cout << "Video sampling and mapping tests passed\n";
}
