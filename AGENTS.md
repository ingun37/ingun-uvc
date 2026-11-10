# Repository guidance

This repository contains multiple projects:

- `streamer/`: native macOS SwiftUI capture-card inspector and recorder with a
  Metal live preview, audio-source selection, and recording-frame-rate selection.
  Capture-card frame-rate behavior requires hardware validation. Before working
  on this project, read and follow
  [streamer/AGENTS.md](streamer/AGENTS.md).
- `GametimeMapper/`: native macOS SwiftUI app and Swift CLI for mapping video time
  to the basketball game clock. The app supports scoreboard selection and manual
  filtering of OCR samples before merging.
  Before working on this project, read and follow
  [GametimeMapper/AGENTS.md](GametimeMapper/AGENTS.md).
- `data_fetcher/`: Python CLI program that fetches field goal attempts of a NBA game.
  Before working on this project, read and follow [data_fetcher/AGENTS.md](data_fetcher/AGENTS.md).
- `ClipEditor/`: native macOS SwiftUI app for missed-shot compilations and
  per-player videos with separate caption placement.
  Before working on this project, read and follow [ClipEditor/AGENTS.md](ClipEditor/AGENTS.md).
- `TestDataGenerator/`: native macOS Swift CLI for per-attempt clips and metadata.
  Before working on this project, read and follow
  [TestDataGenerator/AGENTS.md](TestDataGenerator/AGENTS.md).
- `thumbnail-web/`: HTML template and renderer for creating video thumbnails.
  Before working on this project, read and follow
  [thumbnail-web/AGENTS.md](thumbnail-web/AGENTS.md).
- `UnifiedApp/`: macOS SwiftUI orchestrator for the full workflow; it saves
  the attempts CSV and game time map beside the source video. Before working
  on this project, read and follow [UnifiedApp/AGENTS.md](UnifiedApp/AGENTS.md).
Project-specific instructions apply only to their respective project directories.
For changes that cross project boundaries, follow each affected project's guide.
