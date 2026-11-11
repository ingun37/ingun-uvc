# UnifiedApp

This macOS SwiftUI app orchestrates `data_fetcher/main.py` through interactive zsh with `data_fetcher/.venv` activated, `TheMapper/build/TheMapper.app`, `ClipEditor/build/ClipEditor.app`, and `thumbnail-web/render-thumbnail.mjs`. Read the affected projects' AGENTS.md files before changing an integration.

Keep the game ID as a 10-digit string. Parse `games` output as game ID, date, home team, and away team. Fetch attempts to a staging CSV before the video is chosen, preserving retry behavior. After the user chooses the video, write `<video name>-<game id>.csv` beside it. Pass the same video path to both child apps. Pass `<video name>-map.json`, also beside the video, as the output path to TheMapper and wait for it to exit and produce the file. Pass the video, JSON, CSV, compilation output paths, and formatted game date (`--date`) to ClipEditor and wait for it to exit. ClipEditor also saves square player videos beside the compilation.

Show the running UnifiedApp bundle version in the top-right corner. ClipEditor
runs without App Sandbox so the paths passed on the command line remain
accessible; do not use the old `video-path.txt` handoff.

The thumbnail scene appears after ClipEditor closes. It allows one normalized video rectangle and uses the current frame, game date, and home and away codes. Render through thumbnail-web and save `<video name>-thumbnail.jpg` beside the source video. The renderer runs via interactive zsh to load NVM from `~/.zshrc`.

The app runs companion executables from repository-relative paths. Handle absent executables and missing output files with visible errors. Preserve retry behavior for failed fetches. Build the Release scheme after changes.
