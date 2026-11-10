# UnifiedApp

UnifiedApp connects the repository's NBA data, game-clock mapping, clip editing, and thumbnail tools.

1. Enter a positive page number and click **Query** to list games. The list includes each game's date and home and away team codes.
2. Select a game. UnifiedApp runs `data_fetcher/main.py attempts` with the `data_fetcher/.venv` Python environment and saves a temporary CSV. If the fetch fails, retry or return to the game list.
3. Choose the source video in UnifiedApp. It launches `GametimeMapper/build/GametimeMapperUI.app` with `--video` and `--output`, and waits for its temporary mapping JSON.
4. It launches `ClipEditor/build/ClipEditor.app` with `--video`, `--json`, `--csv`, and `--output`. The compilation destination is `<home team name> VS <away team name> | Bricklights | <date>.mp4` beside the source video. The date is formatted like `Nov 8, 2026`. Team names are mapped from three-letter codes in `ContentView.swift`.
5. After ClipEditor closes, play or scrub the source video and draw one rectangle. Click **Generate Thumbnail** to save `<home team name> VS <away team name> | Bricklights | <date>.jpg` beside the video. The thumbnail uses the selected frame region, the game date, and the home and away team codes.

The workflow requires `data_fetcher/.venv/bin/activate` and `data_fetcher/main.py`; it launches them through interactive zsh before running Python. It also expects the two companion app executables at the paths above. Missing files or outputs appear as errors in the app. Temporary CSV and JSON files are created in a `unified-app-*` directory under the system temporary directory. Thumbnail rendering uses `thumbnail-web/dist`, Playwright, and Node loaded through interactive zsh (`~/.zshrc`), so build the web template with `cd thumbnail-web && npm run build` first.

UnifiedApp shows its bundle version in the top-right corner. GametimeMapperUI and ClipEditor show their own versions there too. ClipEditor is built without App Sandbox so it can open the video, mapping, attempts, and output paths passed by UnifiedApp.

Build UnifiedApp from the repository root:

```sh
xcodebuild -project UnifiedApp/UnifiedApp.xcodeproj -scheme UnifiedApp \
  -configuration Release -destination 'platform=macOS' build
```

When archiving, rebuild and include the companion app bundles. UnifiedApp launches them directly from their `build/` paths rather than from its own bundle.
