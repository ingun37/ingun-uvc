# NBA field goal attempts CLI

Run from the repository root using the project's virtual environment:

```sh
data_fetcher/.venv/bin/python data_fetcher/main.py games
```

`games` lists finished games in the current regular season, newest first. Each row shows the game ID, date, and teams. Browse earlier pages or seasons:

```sh
data_fetcher/.venv/bin/python data_fetcher/main.py games --page 2 --page-size 20
data_fetcher/.venv/bin/python data_fetcher/main.py games --season 2025-26 --season-type Playoffs
```

Use a game ID from the list to print its field goal attempts as CSV:

```sh
data_fetcher/.venv/bin/python data_fetcher/main.py attempts 0022400061
data_fetcher/.venv/bin/python data_fetcher/main.py attempts 0022400061 --output attempts.csv
```

The `period` and `clock` columns give the time of each attempt. `clock` is the game clock remaining in that period, in the NBA feed's ISO 8601 duration format (for example, `PT05M32.00S`). `result` is `made` or `missed`. A game that has no play-by-play data yet produces a message instead of attempt rows.

The CLI sends one NBA Stats request per command. NBA Stats can time out or block some networks; run locally or configure your proxy if that happens.
