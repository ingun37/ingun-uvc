# GametimeMapper

This project has a macOS Swift CLI (`GametimeMapper`) and SwiftUI app
(`GametimeMapperUI`) that share `GametimeMapper/GameTimeMapper.swift`. Target the
current macOS SDK. Use AVFoundation for video decoding, Vision for OCR, and Swift
Charts for the app's graph. Follow RAII, avoid nullable stored properties where
practical, and prefer immutable values.

## Code and behavior

- `GametimeMapper/Command.swift` accepts input video and output JSON paths.
  `--bottom-divisor N` selects the bottom `1/N` of the frame;
  `--left-divisor N`, `--center-divisor N`, or `--right-divisor N` selects a
  horizontal `1/N` region. At most one horizontal option may be used. The CLI
  logs each sampled frame and saves the merged output in one run.
- `GametimeMapper/GameTimeMapper.swift` samples every 0.5 seconds. `sample(...)`
  returns `RawReadings`, retaining each sampled frame's video time, OCR texts,
  optional parsed period and clock, and log line. There is no repeated-frame
  comparison. Keep the `recognize` callback injectable for deterministic tests.
- Parse a clock only when a period selected by `ScoreboardFormat` is present.
  The UI offers presets A (short/digital), B (long/natural), and C
  (short/natural), plus per-period choices. The CLI retains the legacy parser
  default. Normalize known Cyrillic lookalikes for `4TH`, `OT`, and the final
  clock digit `Б` to `6`; keep the original OCR text in samples and logs.
  Vision requests English recognition without automatic language detection.
  Prefer any valid over-minute clock to under-minute clocks; if only
  under-minute clocks occur, choose the greatest value. Overtime labels still
  map to `OT` in output without overtime numbering.
- `RawReadings.removingSample(id:)` removes an individual reading before
  `merge(...)`. `merge(...)` first builds intervals from readings that advance
  continuously at video speed (with OCR rounding tolerance and stopped clocks),
  then merges intervals whose video and game-clock gaps match or whose paused
  clock values match. Preserve this order so UI filtering affects the raw data.
- The output is a chronological JSON array with `period`,
  `game_start_seconds`, `game_end_seconds`, `video_start_seconds`, and
  `video_end_seconds`. Video range ends are exclusive; equal game endpoints
  represent a stopped clock.
- `GametimeMapperUI/ContentView.swift` implements video selection, scoreboard
  rectangle selection, text-format selection, processing and review, and JSON
  saving. It shows the bundle version in the top-right corner. The process log
  updates for each sample. Build the Swift Charts graph once processing finishes;
  do not redraw it for every sample. Hovering shows game time; clicking shows
  the prior clock change and all OCR texts, with a button to remove that raw
  sample. The UI calls `merge(...)` only when the user clicks **Next** after
  review. The save dialog defaults to the video directory and `<video name>.json`.
- `GametimeMapperUIApp.swift` accepts optional `--video/-v PATH` and `--output/-o PATH`. A video path skips the initial picker; an output path saves JSON directly after review and skips the save-location stage. UnifiedApp passes both paths. The app no longer writes a video-path handoff file.
- `GametimeMapperUI/VideoRegionView.swift` handles the one-at-a-time rectangle
  and converts displayed video coordinates to Vision's region of interest,
  including video rotation.

## Build and test

From the repository root:

```sh
xcodebuild -project GametimeMapper/GametimeMapper.xcodeproj \
  -scheme GametimeMapper -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/gametime-mapper-xcode CODE_SIGNING_ALLOWED=NO \
  -parallel-testing-enabled NO test

xcodebuild -project GametimeMapper/GametimeMapper.xcodeproj \
  -scheme GametimeMapperUI -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/gametime-mapper-ui-xcode CODE_SIGNING_ALLOWED=NO build
```

`GametimeMapperTests/` covers parsing, deterministic decoding, raw sample
filtering and merging, and Vision OCR on fixtures in `test-data/`.
`GametimeMapperUITests/` covers video coordinate conversion. When changing
sampling, parsing, or merging, run the full mapper suite. Xcode's macOS test
runner may need execution outside the command sandbox.
