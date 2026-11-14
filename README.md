# ingun-uvc

This repository contains several tools for basketball video workflows:

- `GuraStreaming/`: active macOS capture-card inspector and MOV recorder with
  frame-rate selection, a Metal preview, and an audio-level meter.
- `streamer/`: legacy capture app, retained for reference.
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

## GuraStreaming

Open `GuraStreaming/GuraStreaming.xcodeproj` and run the `GuraStreaming` scheme.
Choose a capture card or camera, then select a supported video frame rate. The
picker defaults to 29.97 fps when available, then 30 fps. The detail view shows
source and USB specifications, available color-profile information, a live
Metal preview, and an audio-level meter when the source has accessible audio.

**Record** adds a movie output to the active capture session. **Stop** finalizes
the recording and saves a timestamped `.mov` directly in `~/Movies`; the app
shows the saved path when finalization succeeds. The preview retains only the
newest waiting video frame, so it can drop frames when rendering falls behind.

Frame-rate configuration is checked when the session starts and when recording
begins. Actual delivered and saved frame cadence still needs hardware
validation for each capture card.

Build from the repository root:

```sh
xcodebuild -project GuraStreaming/GuraStreaming.xcodeproj -scheme GuraStreaming \
  -configuration Debug -derivedDataPath /tmp/gurastreaming-build \
  CODE_SIGNING_ALLOWED=NO build
```

`streamer/` remains available as the previous implementation. Its historical
behavior and build instructions are in [streamer/AGENTS.md](streamer/AGENTS.md).

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
