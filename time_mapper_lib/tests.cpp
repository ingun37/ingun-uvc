#include "library.h"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <nlohmann/json.hpp>
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
    const auto output_path = std::filesystem::path(TEST_OUTPUT_DIR) /
                             (std::string(filename) + ".mapping.json");
    int calls = 0;
    std::vector<std::string> logs;
    auto result = map_gametime_to_videotime(path, {75, 8, 100, 58}, output_path,
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
        }, [&](const std::string& message) { logs.push_back(message); });

    const int expected_samples = static_cast<int>(std::ceil(duration / 0.5));
    if (calls != expected_samples)
        throw std::runtime_error("Video was not sampled every 0.5 seconds");
    if (logs.size() != static_cast<std::size_t>(expected_samples + 5) ||
        logs[2].find("0.0s → game clock 42s | decode ") != 0 ||
        logs[2].find(" ms, RGB convert ") == std::string::npos ||
        logs[2].find(" ms, crop ") == std::string::npos ||
        logs[2].find(" ms, OCR ") == std::string::npos ||
        logs[5].find("1.5s → no clock detected | decode ") != 0 ||
        logs[logs.size() - 3].find("Timing for ") != 0 ||
        logs.back().find("Mapping saved:") != 0)
        throw std::runtime_error("Processing logs missed samples or completion");
    if (result.size() != 4 || result[0].game_second != 42 ||
        result[1].game_second != 41 || result[2].game_second != 42 ||
        result[3].game_second != 41)
        throw std::runtime_error("Clock ranges lost video order or a gap");
    near(result[0].start_seconds, 0.0);
    near(result[0].end_seconds, 1.5);
    near(result[1].start_seconds, 2.0);
    near(result[1].end_seconds, 3.0);
    near(result[2].start_seconds, 3.0);
    near(result[2].end_seconds, 3.5);
    near(result[3].start_seconds, 3.5);
    near(result[3].end_seconds, duration);

    std::ifstream input(output_path);
    if (!input) throw std::runtime_error("Mapping JSON was not created");
    const auto json = nlohmann::json::parse(input);
    if (!json.is_array() || json.size() != result.size())
        throw std::runtime_error("Mapping JSON is not a chronological list");
    for (std::size_t index = 0; index < result.size(); ++index) {
        const auto& entry = json.at(index);
        if (entry.at("game_second").get<int>() != result[index].game_second)
            throw std::runtime_error("Mapping JSON lost a repeated game second");
        near(entry.at("start_seconds").get<double>(), result[index].start_seconds);
        near(entry.at("end_seconds").get<double>(), result[index].end_seconds);
    }
}

} // namespace

int main() {
    exercise_video("minutes-seconds.mp4", 19.452767);
    exercise_video("seconds-fractional.mp4", 7.941267);
    try {
        map_gametime_to_videotime(
            std::filesystem::path(TEST_DATA_DIR) / "minutes-seconds.mp4",
            {240, 0, 10, 10},
            std::filesystem::path(TEST_OUTPUT_DIR) / "invalid-region.json",
            [](const auto&, int, int) -> std::optional<int> { return 0; });
        throw std::runtime_error("Out of bounds region was accepted");
    } catch (const std::invalid_argument&) {
    }
    if (std::getenv("TIME_MAPPER_LIVE_OCR")) {
        for (const char* filename : {"minutes-seconds.mp4", "seconds-fractional.mp4"}) {
            const auto mapping = map_gametime_to_videotime(
                std::filesystem::path(TEST_DATA_DIR) / filename, {0, 0, 242, 80},
                std::filesystem::path(TEST_OUTPUT_DIR) /
                    (std::string(filename) + ".live.mapping.json"));
            if (mapping.empty()) throw std::runtime_error("Live OCR found no game clocks");
            const int expected_second = std::string(filename) == "minutes-seconds.mp4" ? 440 : 22;
            const auto found = std::find_if(mapping.begin(), mapping.end(),
                [&](const GameTimeEntry& entry) { return entry.game_second == expected_second; });
            if (found == mapping.end()) throw std::runtime_error("Expected clock was not recognized");
            near(found->start_seconds, expected_second == 440 ? 2.0 : 1.5);
            near(found->end_seconds, expected_second == 440 ? 3.0 : 2.5);
            std::cout << filename << ": " << mapping.size() << " clock seconds\n";
            for (const auto& entry : mapping)
                std::cout << "  " << entry.game_second << " -> ["
                          << entry.start_seconds << ", " << entry.end_seconds << ")\n";
        }
    }
    std::cout << "Video sampling and mapping tests passed\n";
}
