# NBA field goal attempts CLI

Run from the repository root using the project's virtual environment:

```sh
data_fetcher/.venv/bin/python data_fetcher/main.py games
```

`games` lists finished games in the current regular season, newest first. Each row shows the 10-digit game ID, date, home team code, and away team code. UnifiedApp parses these columns for game selection and thumbnail labels. Browse earlier pages or seasons:

```sh
data_fetcher/.venv/bin/python data_fetcher/main.py games --page 2 --page-size 20
data_fetcher/.venv/bin/python data_fetcher/main.py games --season 2025-26 --season-type Playoffs
```

Use a game ID from the list to print its field goal attempts as CSV:

```sh
data_fetcher/.venv/bin/python data_fetcher/main.py attempts 0022400061
data_fetcher/.venv/bin/python data_fetcher/main.py attempts 0022400061 --output attempts.csv
data_fetcher/.venv/bin/python data_fetcher/main.py attempts 0022400061 --output attempts.csv --boxscore boxscore.csv
```

The `attempts` command requires play-by-play and fetches `ShotChartDetail`
with all field goal attempts (`FGA`) and each team's roster for jersey numbers.
If optional shot-chart or roster responses cannot be decoded, it still writes
the attempts CSV with blank enrichment fields. It infers the season from the
game ID. For unusual games, pass `--season 2024-25` and
`--season-type Playoffs` (or the appropriate season type).

With `--boxscore FILE`, the command also fetches `BoxScoreTraditionalV3` and
writes one row per player, including players who did not play. The CSV contains
team, player, minutes, comment, and traditional final game statistics. ClipEditor
filters out players without minutes when it renders the end cards.

The `period` and `clock` columns give the time of each attempt. `clock` is the game clock remaining in that period, in the NBA feed's ISO 8601 duration format (for example, `PT05M32.00S`). `player_id` is the NBA player identifier from play-by-play; it stays with the player across team changes and is blank when the feed has no valid identifier. `result` is `made` or `missed`. `loc_x` and `loc_y` are shot-chart court coordinates, not video pixels; `shot_distance` is the chart's distance in feet. These three fields are blank when no unique shot-chart match is found. `jersey_number` and `player_full_name` come from the team's roster and may be blank. A game that has no play-by-play data yet produces a message instead of attempt rows.

The `games` command sends one NBA Stats request; `attempts` sends sequential play-by-play, shot-chart, and roster requests. NBA Stats can time out or block some networks; run locally or configure your proxy if that happens.

Export every field goal attempt for one player between two game dates (inclusive):

```sh
data_fetcher/.venv/bin/python data_fetcher/main.py player-attempts 1630170 2026-10-01 2026-11-30 --output player-shots.csv
```

`player-attempts` queries `ShotChartDetail` for the regular season, playoffs, and play-in in every season touched by the range. It includes makes and misses, game and player IDs, shot time, shot type, court location (`loc_x`, `loc_y`), and shot distance. The output comes from the shot chart, so it does not include play-by-play descriptions or roster jersey numbers. Dates use `YYYY-MM-DD`; output defaults to standard output. Requests run one at a time with a one-second pause, and any failed request stops the command without writing a partial CSV.

Here's a sample csv snippet

```csv
game_id,period,clock,team,player,player_id,result,description,loc_x,loc_y,shot_distance,jersey_number,player_full_name
0012600061,1,PT11M33.00S,SAS,Vassell,1630170,missed,MISS Vassell 27' 3PT Jump Shot,,,,,
0012600061,1,PT11M14.00S,SAC,LaVine,203897,made,LaVine 20' Jump Shot (2 PTS),,,,,
```

# Build

```shell
.venv/bin/activate
pyinstaller --onefile --distpath dist main.py
```
