# ingun-uvc

This repository contains several tools for basketball video workflows:

- `streamer/`: macOS capture-card inspector and recorder with audio-source and
  recording-frame-rate selection.
- `TheMapper/`: active macOS app that maps video time to the basketball game clock.
- `GametimeMapper/`: legacy mapper app and CLI, retained for reference.
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
details. The preview width is adjustable. Before recording, choose an audio
source and a frame rate supported by the active video format. **Record** creates
a temporary `.mov`; **Done** finishes it and saves a timestamped file to Movies.
The recording view also has an optional countdown timer.
Recording is limited to 30 fps or lower; choosing a higher rate shows a warning
and blocks **Record**.

The preview uses `AVCaptureVideoDataOutput` to receive BGRA frames. Core Video
maps each pixel buffer to a Metal texture, which is drawn into a `CAMetalLayer`
with aspect-fit scaling. The same capture session and preview remain active
when recording starts.

Frame-rate selection configures the capture device and checks that the session
retains the requested duration before recording. Actual output frame rate and
playback smoothness still need validation with each capture card; a device may
advertise a mode that does not produce the expected recording timestamps.

Build from the repository root:

```sh
xcodebuild -project streamer/Streamer.xcodeproj -scheme Streamer \
  -configuration Debug -derivedDataPath /tmp/ingun-uvc-streamer-build \
  CODE_SIGNING_ALLOWED=NO build
```

## TheMapper

Open `TheMapper/TheMapper.xcodeproj` and run the `TheMapper` scheme. The app lets you:

1. Choose a game recording, or pass `--video/-v <path>` to load it at launch.
2. Play or scrub the video and draw a rectangle around the scoreboard.
3. Choose a scoreboard text preset or customize the period names and under-minute clock style (`:ss.s`, `ss.s`/`s.s`, or two-digit `ss.s`).
4. Process the video. The live log shows OCR text and parsed clocks. After processing, the graph shows continuous and paused intervals. The final log line reports elapsed time, interval coverage, and OCR frame count.
5. Click **Save JSON**. The save dialog defaults to the video's folder; `--output/-o <path>` saves directly to that path when the button is clicked.

TheMapper uses endpoint OCR and recursively splits intervals that are neither continuous nor paused. It produces a JSON array with `period`, `game_start_seconds`, `game_end_seconds`, `video_start_seconds`, and `video_end_seconds`. There is no manual filtering stage. TheMapper shows its bundle version in the window title bar.

Build and run unit tests from the repository root:

```sh
xcodebuild -project TheMapper/TheMapper.xcodeproj -scheme TheMapper \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/themapper-xcode CODE_SIGNING_ALLOWED=NO build

xcodebuild -project TheMapper/TheMapper.xcodeproj -scheme TheMapper \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/themapper-xcode CODE_SIGNING_ALLOWED=NO \
  -parallel-testing-enabled NO '-only-testing:TheMapperTests' test
```

`GametimeMapper/` remains available as the legacy implementation.
