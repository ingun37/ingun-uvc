"""List NBA games and print every field goal attempt in a game."""

import argparse
import csv
from datetime import date
import re
import sys

from nba_api.stats.endpoints import LeagueGameFinder, PlayByPlayV3


def current_season() -> str:
    today = date.today()
    start = today.year if today.month >= 10 else today.year - 1
    return f"{start}-{(start + 1) % 100:02d}"


def season_value(value: str) -> str:
    if not re.fullmatch(r"\d{4}-\d{2}", value) or int(value[-2:]) != (int(value[:4]) + 1) % 100:
        raise argparse.ArgumentTypeError("season must be YYYY-YY, for example 2025-26")
    return value


def game_id_value(value: str) -> str:
    if not re.fullmatch(r"\d{10}", value):
        raise argparse.ArgumentTypeError("game ID must be a 10-digit string")
    return value


def positive_int(value: str) -> int:
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return number


def list_games(args: argparse.Namespace) -> None:
    endpoint = LeagueGameFinder(
        player_or_team_abbreviation="T",
        season_nullable=args.season,
        season_type_nullable=args.season_type,
        get_request=False,
    )
    endpoint.get_request()
    rows = endpoint.league_game_finder_results.get_data_frame()
    games = {}
    for row in rows.itertuples(index=False):
        game_id = str(row.GAME_ID).zfill(10)
        game = games.setdefault(game_id, {"date": str(row.GAME_DATE), "teams": set()})
        game["teams"].add(str(row.TEAM_ABBREVIATION))
    ordered = sorted(games.items(), key=lambda item: (item[1]["date"], item[0]), reverse=True)
    start = (args.page - 1) * args.page_size
    page = ordered[start:start + args.page_size]
    if not page:
        print(f"No games on page {args.page} ({len(ordered)} games in {args.season}, {args.season_type}).")
        return
    print("GAME_ID     DATE        TEAMS")
    for game_id, game in page:
        print(f"{game_id}  {game['date']}  {' vs '.join(sorted(game['teams']))}")
    print(f"Page {args.page} of {(len(ordered) + args.page_size - 1) // args.page_size}; {len(ordered)} games total.")


def field_goal_attempts(args: argparse.Namespace) -> None:
    endpoint = PlayByPlayV3(game_id=args.game_id, get_request=False)
    endpoint.get_request()
    rows = endpoint.play_by_play.get_data_frame()
    if rows.empty:
        print("No play-by-play data found for this game.")
        return
    writer = csv.writer(sys.stdout)
    writer.writerow(("game_id", "period", "clock", "team", "player", "result", "description"))
    for row in rows.itertuples(index=False):
        if row.isFieldGoal not in (1, True, "1", "true", "True"):
            continue
        result = str(row.shotResult).lower()
        if result not in ("made", "missed"):
            result = "made" if str(row.actionType).lower() == "made shot" else "missed"
        writer.writerow((args.game_id, row.period, row.clock, row.teamTricode,
                         row.playerName, result, row.description))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    games = commands.add_parser("games", help="list recent games in a season")
    games.add_argument("--season", type=season_value, default=current_season(), help="YYYY-YY (default: current season)")
    games.add_argument("--season-type", choices=("Regular Season", "Playoffs", "PlayIn", "Pre Season", "All Star"),
                       default="Regular Season")
    games.add_argument("--page", type=positive_int, default=1)
    games.add_argument("--page-size", type=positive_int, default=20)
    games.set_defaults(func=list_games)
    shots = commands.add_parser("attempts", help="print field goal attempts as CSV")
    shots.add_argument("game_id", type=game_id_value, help="10-digit ID from the games command")
    shots.set_defaults(func=field_goal_attempts)
    args = parser.parse_args()
    try:
        args.func(args)
    except Exception as exc:
        print(f"NBA request failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
