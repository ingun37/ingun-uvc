CLI program that fetches field goal attempts data using [nba_api](https://github.com/swar/nba_api) library.

Consult $nba-api skill.

Read [README](README.md)
`games` prints game ID, date, home code, and away code for UnifiedApp. Preserve the 10-digit ID and column order. `attempts GAME_ID --output FILE` writes the temporary CSV. Play-by-play is required; empty or invalid optional shot-chart and roster responses leave those enrichment columns blank. Rebuild `data_fetcher/dist/main` with PyInstaller after changing the CLI used by UnifiedApp.
