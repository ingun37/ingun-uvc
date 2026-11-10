# ingun-uvc

This repository contains several tools for basketball video workflows:

- `streamer/`: macOS capture-card inspector.
- `GametimeMapper/`: macOS app and CLI that map a video's time to the basketball game clock.
- `data_fetcher/`: Python CLI that fetches field-goal attempts for an NBA game.
- `ClipEditor/`: macOS app for missed-shot compilations, including one video per player. See [its README](ClipEditor/README.md).
- `TestDataGenerator/`: macOS CLI that generates per-attempt clips and metadata.
- `thumbnail-web/`: React template and screenshot renderer for video thumbnails.
- `UnifiedApp/`: macOS app that runs the complete games → attempts → mapper → editor → thumbnail workflow. See [its README](UnifiedApp/README.md).

When UnifiedApp runs the workflow, it writes `<video name>-<game id>.csv` and
`<video name>-map.json` beside the source video. ClipEditor saves the full
compilation plus a square `<player name>'s every bricks VS <opposing team long name> | <date>.mp4` for each player
with included missed attempts.

## Streamer

Open `streamer/Streamer.xcodeproj` and run the `Streamer` scheme. Choose a capture
card or camera to inspect its live video, source format, and available USB
details. The preview width is adjustable, and an audio source can be selected
before recording. **Record** creates a temporary `.mov`; **Done** finishes it
and opens a save dialog.

The preview uses `AVCaptureVideoDataOutput` to receive BGRA frames. Core Video
maps each pixel buffer to a Metal texture, which is drawn into a `CAMetalLayer`
with aspect-fit scaling. The same capture session and preview remain active
when recording starts.

Build from the repository root:

```sh
xcodebuild -project streamer/Streamer.xcodeproj -scheme Streamer \
  -configuration Debug -derivedDataPath /tmp/ingun-uvc-streamer-build \
  CODE_SIGNING_ALLOWED=NO build
```

## GametimeMapper

Open `GametimeMapper/GametimeMapper.xcodeproj` and run the `GametimeMapperUI` scheme. The app lets you:

1. Choose a game recording.
2. Play or scrub the video and drag a rectangle around the scoreboard. Drawing again replaces the selection.
3. Choose a scoreboard text preset (A: short periods and `:ss.s`; B: long periods and `ss.s`/`s.s`; C: short periods and `ss.s`/`s.s`), or customize each period and the under-minute clock format. Over-minute clocks use `mm:ss` or `m:ss`.
4. Process the video. The OCR log updates as samples arrive; the game-clock graph appears when processing finishes. Hover a point to see its game time, or click it to inspect the OCR texts and its change from the previous clock reading. Remove incorrect points before continuing.
5. Click **Next** to merge the retained readings, then choose where to save the JSON. The save dialog starts in the video's folder with `<video name>.json` as the suggested name.

Launch `GametimeMapperUI` with optional `--video/-v <path>` to load a video directly and skip its picker, and `--output/-o <path>` to save JSON directly after review. Both options can be combined.

The CLI runs sampling and merging in one command:

```sh
GametimeMapper <video-path> <output-json-path> [--bottom-divisor N] [--left-divisor N | --center-divisor N | --right-divisor N]
```

The optional divisors restrict OCR to a fraction of the frame. The UI uses the drawn rectangle instead. Both produce a chronological JSON array with `period`, `game_start_seconds`, `game_end_seconds`, `video_start_seconds`, and `video_end_seconds`. Video end times are exclusive.

The UI displays its bundle version in the top-right corner. OCR is configured for English, and parsing also accepts known Cyrillic lookalikes in short period labels and `Б` as a final clock digit `6`. When multiple clocks are recognized, an over-minute clock takes priority; otherwise the largest under-minute reading is used.

To build the app or run the mapper tests from the repository root:

```sh
xcodebuild -project GametimeMapper/GametimeMapper.xcodeproj \
  -scheme GametimeMapperUI -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/gametime-mapper-ui-xcode CODE_SIGNING_ALLOWED=NO build

xcodebuild -project GametimeMapper/GametimeMapper.xcodeproj \
  -scheme GametimeMapper -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/gametime-mapper-xcode CODE_SIGNING_ALLOWED=NO \
  -parallel-testing-enabled NO test
```
