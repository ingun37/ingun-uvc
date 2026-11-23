# ClipEditor

ClipEditor combines missed NBA field goals into a video. Select a source video,
the game time mapping JSON from TheMapper, and the attempts CSV from
data_fetcher. Review the mapped clips, adjust their timing, and choose which
clips to include before exporting.

The input screen also accepts **Ellipse size** (a multiplier of the selected
player's bounding-box width) and **Shot effect duration** (the pause length in
seconds). They start at `4.0×` and `2.0` seconds. The accepted ranges are
`0.1–10×` and `0.3–30` seconds. Ellipse size appears in the shot-effect
preview and both exports; duration controls the exported pause.

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

## Shot effects

Each attempt has a **Shot effect** button. Its window lets you choose a release
frame with a slider from the clip start to the attempt time, initially set
about 0.7 seconds before the attempt. Frame previews use exact-timestamp
`AVAssetImageGenerator` extraction. Click the shooter in the preview to run
Vision's person-instance mask request on a half-width, half-height crop around
the click. The selected mask, its bounding box, and a yellow ellipse at the
bottom of that box appear in the preview. Adjust the box width and height, then
click **Apply**. The chosen frame time, mask, and box are kept for that attempt
while editing.

At export, ClipEditor uses `player_id` from the game's attempts CSV to fetch
that player's field-goal attempts from the previous year through the day before
the game. It writes a copy beside the input video as
`player-shots-<shortname>-<player id>.csv`, using the CSV's `player` short name.
The fetcher's temporary CSV is deleted after it is read. A failed fetch skips
the effect and appears as an export warning. The game's `loc_x` and `loc_y`
values are tenths of a foot. ClipEditor maps each shot to its nearest spot in
`court_spot_loc_mapper/mapping.json` and uses only past attempts mapped to that
same spot. Fewer than 10 samples skips the effect, with a log and warning.

For an eligible effect, the video pauses at the chosen frame and darkens outside
the player mask to 50% darkness over 0.2 seconds. The ellipse appears during
the darkening animation, followed by this caption:

```text
{last name}'s
recent
{shot description}
at the
{spot label}
{percentage} ({FGM}/{FGA})
```

The last name comes from the game's `player` column; the shot description
removes the leading `MISS <player>` and shot-distance prefix from the CSV
description. The base caption color matches the compilation captions and box
score; the spot label and ellipse are yellow. The percentage alone is red at
20% or below, green at 50% or above, and interpolated between those thresholds.
The effect appears in the compilation and in that player's square video. A
per-player effect is skipped when its entire bounding box does not fit strictly
inside the centered 1:1 crop; the export reports a warning. The player mask
and ellipse are repositioned into crop coordinates, and later count animations
account for the inserted pause.

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

## ShotEffectPlayground

Run the `ShotEffectPlayground` scheme to try the same shot editor and rendering
without an attempts CSV. Choose a video and set the ellipse size and pause
duration, open the shot-effect window to select a frame and player mask, then
enter `loc_x`, `loc_y` (tenths of a foot), the player's last name, a shot
description, FGM, and FGA. The final scene generates the video and provides
play, pause, and replay controls. It displays the path to the temporary MP4.

Launch options `--video/-v`, `--json/-j`, `--csv/-c`, and `--boxscore` prefill the inputs.
`--output/-o` exports directly to the given compilation path after clip review.
`--date` supplies the formatted game date for player filenames and shot-effect history.
UnifiedApp passes all four paths.

Build from the repository root:

```sh
xcodebuild -project ClipEditor/ClipEditor.xcodeproj \
  -scheme ClipEditor -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/clip-editor-xcode CODE_SIGNING_ALLOWED=NO build

xcodebuild -project ClipEditor/ClipEditor.xcodeproj \
  -scheme ShotEffectPlayground -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/shot-effect-playground-xcode CODE_SIGNING_ALLOWED=NO build
```
