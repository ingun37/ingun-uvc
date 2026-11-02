# TestDataGenerator

TestDataGenerator creates a separate video clip and JSON metadata file for each field goal attempt it can locate in a game-time mapping. It accepts both made and missed attempts. Attempts that have no matching mapping range are skipped.

## Build

From the repository root:

```sh
xcodebuild -project TestDataGenerator/TestDataGenerator.xcodeproj \
  -scheme TestDataGenerator -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/test-data-generator-xcode CODE_SIGNING_ALLOWED=NO build
```

## Run

```sh
/tmp/test-data-generator-xcode/Build/Products/Debug/TestDataGenerator \
  VIDEO MAPPING_JSON ATTEMPTS_CSV OUTPUT_DIR \
  [--window SECONDS] [--before SECONDS] [--after SECONDS]
```

For the included sample data:

```sh
/tmp/test-data-generator-xcode/Build/Products/Debug/TestDataGenerator \
  test-data/0022600156/0.mov \
  test-data/0022600156/0.json \
  test-data/0022600156/attempts.csv \
  /tmp/test-data-generator-output
```

The default clip starts 3 seconds before the shot and ends 3 seconds after it. `--window 5` uses 5 seconds on both sides. `--before 5 --after 2` sets the sides separately. Windows are shortened at the beginning or end of the source video.

## Input and output

The mapping JSON comes from `GametimeMapper/`. The attempts CSV comes from `data_fetcher/` and must contain `period` and `clock` columns. The clock uses an ISO 8601 duration such as `PT11M33.00S`.

Each located attempt produces `attempt-0001.mp4` and `attempt-0001.json`, with the number based on its CSV row order. The JSON contains the original CSV values under `attempt`, plus:

| Field | Meaning |
| --- | --- |
| `identifier` | Shared base name of the clip and JSON file |
| `loc_x`, `loc_y` | Shot-chart court coordinates, when present in the CSV; omitted if unavailable |
| `shot_distance` | Shot-chart distance in feet, when present in the CSV; omitted if unavailable |
| `shot_time_seconds` | Shot time relative to the exported clip's start |
| `source_shot_time_seconds` | Shot time in the source video |
| `source_start_seconds` | Clip start in the source video |
| `source_end_seconds` | Clip end in the source video |

The command prints counts of exported and skipped attempts when it finishes. The supplied sample currently exports 25 pairs and skips 152 attempts because its mapping covers only part of the game.
