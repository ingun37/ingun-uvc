# ClipEditor

ClipEditor combines missed NBA field goals into a video. Select a source video,
the game time mapping JSON from TheMapper, and the attempts CSV from
data_fetcher. Review the mapped clips, adjust their timing, and choose which
clips to include before exporting.

Optionally choose a final box score CSV on the input screen (or pass
`--boxscore PATH`). When supplied, export fades into a five-second box score card
over the last 0.45 seconds of the final clip and fades out source audio at the
same time. The compilation card has a 1920:1080
design canvas; player cards have a square canvas. The compilation keeps its
source dimensions, so a non-16:9 source letterboxes the card. Edit
`BoxScoreLayout.compilationColumns` and `BoxScoreLayout.playerStats` in
`ClipEditor/BoxScore.swift` to choose the displayed statistics. The same file
has Xcode previews for both SwiftUI templates.

Each clip has one timing slider. The left and right handles set the clip start
and end, and each middle handle marks a missed attempt. A single-attempt clip
has three handles; a merged clip has one middle handle per attempt. The slider
covers 15 seconds before the first attempt through 15 seconds after the last,
limited by the video bounds for precise control in long videos. **Move All** is
checked by default: dragging any handle shifts the whole clip window and all
attempt markers together. Uncheck it to adjust a handle independently while
keeping attempts inside the clip and in order. **Reset timing** restores the
mapped positions. Moving an attempt handle changes when its shot caption and
per-player missed-attempt count animation appear in the exported videos.

The export saves the full compilation to the selected MP4 path. It also saves
one square MP4 per player with included misses in the same folder, named
`<player name> | every brick VS <opposing team long name> | <date>.mp4`.
The opposing team comes from the CSV team codes. If `--date` is absent, enter
the game date on the input screen in `MMM d, yyyy` format (for example,
`Nov 16, 2026`); the date is also used for the shot-effect history lookup.
Merged clips remain whole and appear in each involved player's video, even
when they contain another player's attempt.

The full compilation keeps its shot captions. Each player video places the
player's name at the top center and keeps that player's FGM/FGA count visible
at the bottom center, starting at `0/0`. At the beginning of each clip, the
count quickly catches up through any made or missed attempts in the CSV gap.
It advances again when the player misses in the clip. A bouncing 🏀 accompanies
a make with its CSV game time beside it (for example, `🏀 2nd 11′2″`), and a
bouncing 🧱 accompanies a miss. The count is centered in a fitted white box
with a black shadow, with the emoji and time label above it. These animations are
baked into the exported MP4 and do not appear in clip previews. Player videos
are center-cropped to 1:1; the full compilation retains the source dimensions.

To resize the per-player overlay, edit `addCountAnimation` in
`ClipEditor/VideoCompilation.swift`: `font` controls the FGM/FGA text,
`horizontalPadding` and `verticalPadding` control its box, and `iconSize`,
`emojiFont`, and `timeFont` control the emoji and game-time label. There is no
single scale setting for the whole overlay.

Launch options `--video/-v`, `--json/-j`, `--csv/-c`, and `--boxscore` prefill the inputs.
`--output/-o` exports directly to the given compilation path after clip review.
`--date` supplies the formatted game date for player filenames and shot-effect history.
UnifiedApp passes all four paths.

Build from the repository root:

```sh
xcodebuild -project ClipEditor/ClipEditor.xcodeproj \
  -scheme ClipEditor -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/clip-editor-xcode CODE_SIGNING_ALLOWED=NO build
```
