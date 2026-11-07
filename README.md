# ingun-uvc

This repository contains several tools for basketball video workflows:

- `streamer/`: macOS capture-card inspector.
- `GametimeMapper/`: macOS app and CLI that map a video's time to the basketball game clock.
- `data_fetcher/`: Python CLI that fetches field-goal attempts for an NBA game.
- `ClipEditor/`: macOS app for missed-shot video compilations.
- `TestDataGenerator/`: macOS CLI that generates per-attempt clips and metadata.

## GametimeMapper

Open `GametimeMapper/GametimeMapper.xcodeproj` and run the `GametimeMapperUI` scheme. The app lets you:

1. Choose a game recording.
2. Play or scrub the video and drag a rectangle around the scoreboard. Drawing again replaces the selection.
3. Process the video. The OCR log updates as samples arrive; the game-clock graph appears when processing finishes. Hover a point to see its game time, or click it to inspect the OCR texts and its change from the previous clock reading. Remove incorrect points before continuing.
4. Click **Next** to merge the retained readings, then choose where to save the JSON. The save dialog starts in the video's folder with `<video name>.json` as the suggested name.

The CLI runs sampling and merging in one command:

```sh
GametimeMapper <video-path> <output-json-path> [--bottom-divisor N] [--left-divisor N | --center-divisor N | --right-divisor N]
```

The optional divisors restrict OCR to a fraction of the frame. The UI uses the drawn rectangle instead. Both produce a chronological JSON array with `period`, `game_start_seconds`, `game_end_seconds`, `video_start_seconds`, and `video_end_seconds`. Video end times are exclusive.

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

## Streamer TODO

- [x] Bigger video in preview view
- [x] Terminate when last window close
- [x] Stop recording when frozen
- [x] Timeout for recording
- [ ] Thumbnail generation
- [ ] Read teams from the scoreboard?
- [ ] Boxscore in the end
