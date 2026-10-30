# GametimeMapper CLI

Target the current macOS SDK. Use AVFoundation to decode video and Vision for
OCR; the project has no UI or selected subregion. Follow RAII, avoid nullable
stored properties where practical, and prefer immutable values.

## Code and behavior

- `GametimeMapper/Command.swift` accepts input video path and output JSON path,
  plus optional `--bottom-divisor N` to OCR the bottom `1/N` of each frame
  (default `N=1`, the whole frame). It prints per-sampled-frame OCR text,
  recognized game time, and OCR duration in milliseconds.
- `GametimeMapper/GameTimeMapper.swift` samples every 0.5 seconds. Parse a
  clock only when a recognized period (`1ST`, `2ND`, `3RD`,
  `4TH`, or `OT`) is present. Supported clocks include `mm:ss` and `:ss.s`.
  Additional overtime labels are not defined yet.
- Output is a chronological JSON array with `period`, `game_second`,
  `start_seconds`, and `end_seconds`. Video range ends are exclusive.
  Samples with the same period merge while the game clock advances continuously
  at video speed, allowing for OCR clock rounding, the transition to tenths
  below one minute, and up to one second of missing readings when the next
  clock confirms continuity. The duration of a
  merged entry is `end_seconds - start_seconds`, and `game_second` is its
  starting clock. Longer gaps and clock jumps split entries.
- Keep the `recognize` callback injectable so decoding and range behavior can
  be tested with deterministic OCR readings.

## Build and test

From the repository root:

```sh
xcodebuild -project GametimeMapper/GametimeMapper.xcodeproj \
  -scheme GametimeMapper -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/gametime-mapper-xcode CODE_SIGNING_ALLOWED=NO test
```

`GametimeMapperTests/` covers parsing, deterministic decoding with the small
MP4 fixtures, and live Vision OCR on the full-frame MOV clips in `test-data/`.
When changing sampling or parsing, run the full suite. Xcode's macOS test
runner may need execution outside the command sandbox.
