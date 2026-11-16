# MockGameClock

Generate a basketball game clock video from a text script. The macOS app provides an editor; `mock-game-clock` runs the same script from the command line.

## Command line

Requires macOS, Xcode command line tools, and `ffmpeg` on `PATH`. Install FFmpeg with `brew install ffmpeg` if needed.

From this directory, build and run:

```sh
swift build -c release
.build/release/mock-game-clock \
  --width 1280 \
  --height 720 \
  --code clock.txt \
  --output "$HOME/Movies/game-clock.mov"
```

You can also use `swift run mock-game-clock --width 1280 --height 720 --code clock.txt --output "$HOME/Movies/game-clock.mov"` without a separate build step.

All four arguments are required. Width and height must be even integers from 160 to 4096 pixels. The output is a 30 fps H.264 MOV. The output directory must already exist, and the CLI will not overwrite an existing file. Use `--help` for a usage summary.

## Script format

Put one statement on each line of the UTF-8 text file passed to `--code`:

```text
start at 1ST 11:59.00
pause at 1ST 10:30.00 for 3.5 seconds
hide at 1ST 09:45.00 for 2.0 seconds
end at 1ST 09:30.00
```

Blank lines and lines beginning with `#` are ignored. The first statement must be `start at`; the last must be `end at`. Between them, use `pause at` to hold a visible clock or `hide at` to show a black frame for the specified positive number of real-time seconds. Events must follow game-clock order.

Clock times use `PERIOD mm:ss.ff`, with two digits in each numeric part. Periods are `1ST`, `2ND`, `3RD`, `4TH`, `OT`, `2OT`, and `3OT`. Quarters count down from `11:59.00`; overtime periods count down from `04:59.00`. The rendered clock displays `mm:ss` above one minute and `:ss.s` below one minute. After `:00.0`, it advances to the next period. A script may end at `3OT 00:00.00`.

The chosen video size scales the clock uniformly and centers it on a black background. The macOS app exports to `~/Movies`; the CLI uses the path supplied by `--output`.
