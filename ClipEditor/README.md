# ClipEditor

ClipEditor combines missed NBA field goals into a video. Select a source video,
the game time mapping JSON from TheMapper, and the attempts CSV from
data_fetcher. Review the mapped clips, adjust their start and end times, and
choose which clips to include before exporting.

The export saves the full compilation to the selected MP4 path. It also saves
one square MP4 per player with included misses in the same folder, named
`<player name> | every brick VS <opposing team long name> | <date>.mp4`.
The opposing team comes from the CSV team codes; the date comes from UnifiedApp's
`--date` argument or the compilation filename when available.
Merged clips remain whole and appear in each involved player's video, even
when they contain another player's attempt.

The full compilation keeps its shot captions. Each player video places the
player's name at the top center and keeps that player's FGM/FGA count visible
at the bottom center, starting at `0/0`. At the beginning of each clip, the
count quickly catches up through any made or missed attempts in the CSV gap.
It advances again when the player misses in the clip. A bouncing 🏀 accompanies
a make and a bouncing 🧱 accompanies a miss. The count is centered in a fitted
white box with a black shadow, with the emoji above it. These animations are
baked into the exported MP4 and do not appear in clip previews. Player videos
are center-cropped to 1:1; the full compilation retains the source dimensions.

Launch options `--video/-v`, `--json/-j`, and `--csv/-c` prefill the inputs.
`--output/-o` exports directly to the given compilation path after clip review.
`--date` supplies the formatted game date for player filenames.
UnifiedApp passes all four paths.

Build from the repository root:

```sh
xcodebuild -project ClipEditor/ClipEditor.xcodeproj \
  -scheme ClipEditor -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/clip-editor-xcode CODE_SIGNING_ALLOWED=NO build
```
