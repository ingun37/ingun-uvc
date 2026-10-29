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

Here's a sample csv snippet

```csv
game_id,period,clock,team,player,result,description
0012600061,1,PT11M33.00S,SAS,Vassell,missed,MISS Vassell 27' 3PT Jump Shot
0012600061,1,PT11M14.00S,SAC,LaVine,made,LaVine 20' Jump Shot (2 PTS)
0012600061,1,PT11M07.00S,SAS,Harper,made,Harper 4' Driving Finger Roll Layup (3 PTS)
0012600061,1,PT10M53.00S,SAC,Sabonis,missed,MISS Sabonis 3' Driving Layup
0012600061,1,PT10M46.00S,SAS,Wembanyama,made,Wembanyama 1' Running Dunk (2 PTS)
0012600061,1,PT10M27.00S,SAC,Murray,missed,MISS Murray 25' 3PT Jump Shot
0012600061,1,PT10M18.00S,SAS,Wembanyama,missed,MISS Wembanyama 27' 3PT Pullup Jump Shot
```