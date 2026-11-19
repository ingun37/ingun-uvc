# ingun-uvc

This repository contains several tools for basketball video workflows:

- `GuraStreaming/`: active macOS capture-card inspector and MOV recorder with
  frame-rate selection, a Metal preview, an audio-level meter, and automatic stop
  on frozen video or prolonged silence.
- `streamer/`: legacy capture app, retained for reference.
- `TheMapper/`: active macOS app that maps video time to the basketball game clock.
- `MockGameClock/`: app and CLI that render scripted game-clock videos for mapper tests.
- `GametimeMapper/`: legacy mapper app and CLI, retained for reference.
- `data_fetcher/`: Python CLI that fetches field-goal attempts for an NBA game.
- `ClipEditor/`: macOS app for missed-shot compilations, including one video per player. See [its README](ClipEditor/README.md).
- `TestDataGenerator/`: macOS CLI that generates per-attempt clips and metadata.
- `thumbnail-web/`: React template and screenshot renderer for video thumbnails.
- `UnifiedApp/`: macOS app that runs the complete games → attempts → mapper → editor → thumbnail workflow. See [its README](UnifiedApp/README.md).

When UnifiedApp runs the workflow, it writes `<video name>-<game id>.csv` and
`<video name>-map.json` beside the source video. ClipEditor saves the full
compilation plus a square `<player name> | every brick VS <opposing team long name> | <date>.mp4` for each player
with included missed attempts. Player videos keep an animated FGM/FGA count visible throughout.

## GuraStreaming

After cloning, set up the thumbnail classifier from the repository root before
opening or building the Xcode project:

```sh
GuraStreaming/Tools/download-clip-image-model
cp GuraStreaming/Tools/clip-labels.example.json GuraStreaming/Tools/clip-labels.json
GuraStreaming/Tools/regenerate-clip-prompts
```

The first command downloads the pinned 8-bit CLIP image encoder (about 83 MB), checks
its SHA-256, and installs it at
`GuraStreaming/GuraStreaming/Models/clip-image.mlpackage`. The model package is
git-ignored; rerunning the command verifies an existing copy. Edit the ignored
`GuraStreaming/Tools/clip-labels.json` to change the positive and negative
descriptions, then rerun `regenerate-clip-prompts`. That command generates the
ignored `GuraStreaming/GuraStreaming/clip-prompts.json` required by the app and
downloads the matching text encoder on its first run. See
[GuraStreaming/CLIP-MODEL.md](GuraStreaming/CLIP-MODEL.md) for details.

Open `GuraStreaming/GuraStreaming.xcodeproj` and run the `GuraStreaming` scheme.
Choose a capture card or camera, then select a supported video frame rate. The
picker defaults to 29.97 fps when available, then 30 fps. The detail view shows
source and USB specifications, available color-profile information, a live
Metal preview, and an audio-level meter when the source has accessible audio.

**Record** adds a movie output to the active capture session. **Stop** finalizes
the recording and saves a timestamped `.mov` directly in `~/Movies`; the app
shows why recording stopped and the saved path when finalization succeeds.
**Open directory** opens the containing Movies folder; **Open file** opens the
saved movie. If recording fails, the app shows the error instead.

The frozen-video and no-sound timeouts each default to 60 seconds and can be
changed in the detail view before recording. Each setting shows its status on
the same row. Repeated frames start the video countdown. Silence starts a
separate countdown when recording begins, including when the source delivers
no audio buffers; detected sound resets it. Recording stops when either timeout
expires. Audio analysis and the silence timer run off the capture delegate
callback. A Metal compute shader compares a fixed 256 × 144 grid of pixels
between frames, allowing small codec differences. The preview and detector each
retain only their newest waiting frame, so either can skip frames when GPU work
falls behind. Both share the Metal device, command queue, and texture cache.
The movie output runs through the capture session separately.

Frame-rate configuration is checked when the session starts and when recording
begins. Actual delivered and saved frame cadence still needs hardware
validation for each capture card. The frozen-video test uses
`GuraStreaming/GuraStreamingTests/frozen-audible-small.mp4` with a two-second
timeout. The silence test uses the three-second, audio-free
`GuraStreaming/GuraStreamingTests/no_audio.mp4` with a two-second timeout.

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

TheMapper uses endpoint OCR and recursively splits intervals that are neither continuous nor paused. After merging, it checks each continuous interval's final clock-second transition with up to four additional OCR samples over the preceding second. When the readings agree, it refines `video_end_seconds` to within 1/16 second of that transition and shifts `video_start_seconds` by the same amount. An interval stays unchanged if a reading fails or disagrees. It produces a JSON array with `period`, `game_start_seconds`, `game_end_seconds`, `video_start_seconds`, and `video_end_seconds`. There is no manual filtering stage. TheMapper shows its bundle version in the window title bar.

`TheMapper/TheMapperTests/scoreboard-videos/` contains MockGameClock videos and their source `.txt` scripts. Two videos include three pauses each at different clock times and lengths. The mapping tests check seven continuous-interval end transitions against known 30 fps frame positions with a 0.1-second tolerance. See [MockGameClock's README](MockGameClock/README.md) to regenerate the videos.

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
