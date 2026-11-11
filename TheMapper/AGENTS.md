# TheMapper

TheMapper is the active macOS SwiftUI game-time mapper. UnifiedApp launches
`TheMapper/build/TheMapper.app` with `--video PATH` and `--output PATH` and waits
for the JSON file. The output is a chronological array with `period`,
`game_start_seconds`, `game_end_seconds`, `video_start_seconds`, and
`video_end_seconds`. Video ends are exclusive; equal game endpoints mean a
paused clock.

`GameTimeReader.swift` uses Vision OCR on `CVPixelBuffer` frames and parses
period and clock text. `VideoTimeMapper.swift` reads interval endpoints,
classifies continuous or paused ranges, recursively splits unresolved ranges,
and merges compatible intervals. Keep OCR frame reads cached by time. The
mapper reports frame OCR results and a final elapsed-time and coverage summary
through its log callback. `ContentView.swift` provides video selection,
scoreboard-region selection, format choices, processing log, graph, and JSON
saving. The app accepts `--video/-v` and `--output/-o` launch options.

`TheMapperTests/scoreboard-images/` contains OCR fixtures;
`TheMapperTests/scoreboard-videos/` contains interval-mapping fixtures. Keep
regression tests for merge behavior and run the unit target after parser or
mapping changes:

```sh
xcodebuild -project TheMapper/TheMapper.xcodeproj -scheme TheMapper \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/themapper-xcode CODE_SIGNING_ALLOWED=NO \
  -parallel-testing-enabled NO '-only-testing:TheMapperTests' test
```
