# UnifiedApp

This macOS SwiftUI app orchestrates `data_fetcher/dist/main`, `GametimeMapper/build/GametimeMapperUI.app`, `ClipEditor/build/ClipEditor.app`, and `thumbnail-web/render-thumbnail.mjs`. Read the affected projects' AGENTS.md files before changing an integration.

Keep the game ID as a 10-digit string. Parse `games` output as game ID, date, home team, and away team. Fetch attempts to a temporary CSV. Choose the video in UnifiedApp, then pass the same path to both child apps. Pass a temporary JSON output path to GametimeMapperUI and wait for it to exit and produce the file. Pass the video, JSON, CSV, and compilation output paths to ClipEditor and wait for it to exit.

Show the running UnifiedApp bundle version in the top-right corner. ClipEditor
runs without App Sandbox so the paths passed on the command line remain
accessible; do not use the old `video-path.txt` handoff.

The thumbnail scene appears after ClipEditor closes. It allows one normalized video rectangle and uses the current frame, game date, and home and away codes. Render through thumbnail-web and save `<video name>-thumbnail.jpg` beside the source video. The renderer runs via interactive zsh to load NVM from `~/.zshrc`.

The app runs companion executables from repository-relative paths. Handle absent executables and missing output files with visible errors. Preserve retry behavior for failed fetches. Build the Release scheme after changes.
