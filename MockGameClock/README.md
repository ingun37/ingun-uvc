# MockGameClock

MockGameClock generates a basketball game clock video from a text script. The Xcode project has two targets:

- **MockGameClock**: a macOS app with a script editor. It saves videos in `~/Movies`.
- **mock-game-clock**: a command-line tool. It reads a script file and writes to the output path you provide.

Both targets use `MockGameClock/ClockVideo.swift` for clock behavior and rendering.

## Build and run the CLI

Requires macOS, Xcode, and `ffmpeg` on `PATH`. If needed, install FFmpeg with `brew install ffmpeg`. The CLI uses FFmpeg to encode H.264 video.

Open `MockGameClock.xcodeproj` in Xcode and select the **mock-game-clock** scheme to build it. To run from Xcode, open **Product → Scheme → Edit Scheme → Run → Arguments** and add the four option/value pairs shown below.

Or, from this directory, build and run it in Terminal:

```sh
xcodebuild -project MockGameClock.xcodeproj \
  -scheme mock-game-clock \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/mock-game-clock-build \
  CODE_SIGNING_ALLOWED=NO build

/tmp/mock-game-clock-build/Build/Products/Release/mock-game-clock \
  --width 1280 \
  --height 720 \
  --code clock.txt \
  --output "$HOME/Movies/game-clock.mov"
```

All four arguments are required. Width and height must be even integers from 160 to 4096 pixels. The CLI produces a 30 fps H.264 MOV, does not overwrite an existing file, and expects the output directory to exist. Run `mock-game-clock --help` for a usage summary.

## Write a script

Create a UTF-8 text file such as `clock.txt`:

```text
start at 1ST 11:59.00
pause at 1ST 10:30.00 for 3.5 seconds
hide at 1ST 09:45.00 for 2.0 seconds
end at 1ST 09:30.00
```

Use one statement per line. The first must be `start at` and the last must be `end at`. Between them, `pause at` holds the visible clock for the given number of real-time seconds; `hide at` makes it disappear for that duration. Events must follow game-clock order. Blank lines and lines starting with `#` are ignored.

Times use `PERIOD mm:ss.ff`, with two digits in each numeric part. Periods are `1ST`, `2ND`, `3RD`, `4TH`, `OT`, `2OT`, and `3OT`. Quarters start at `11:59.00`; overtime periods start at `04:59.00`. At one minute or more, the video displays `mm:ss`. Below one minute, it displays `:ss.s`. The next period begins after `:00.0`; a script may end at `3OT 00:00.00`.

The clock scales uniformly to fit the requested video dimensions and is centered on a black background.
