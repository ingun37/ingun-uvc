# ClipEditor

ClipEditor combines missed NBA field goals into a video. Select a source video,
the game time mapping JSON from GametimeMapper, and the attempts CSV from
data_fetcher. Review the mapped clips, adjust their start and end times, and
choose which clips to include before exporting.

The export saves the full compilation to the selected MP4 path. It also saves
one square MP4 per player with included misses in the same folder, named
`<player name>'s every bricks VS <opposing team long name> | <date>.mp4`.
The opposing team comes from the CSV team codes; the date comes from UnifiedApp's
`--date` argument or the compilation filename when available.
Merged clips remain whole and appear in each involved player's video, even
when they contain another player's attempt.

The full compilation keeps its shot captions. Each player video places the
player's name at the top center and shows only that player's FGM/FGA count at
the bottom center when a shot caption appears. The count omits the player's
name and jersey number. Player videos are center-cropped to 1:1; the full
compilation retains the source dimensions.

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
