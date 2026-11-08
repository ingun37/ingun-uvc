"""List NBA games and print field goal attempts with NBA shot-chart locations."""

import argparse
from contextlib import nullcontext
import csv
from datetime import date
import re
import sys
import time
from pathlib import Path

from nba_api.stats.endpoints import CommonTeamRoster, LeagueGameFinder, PlayByPlayV3, ShotChartDetail


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


def season_for_game(game_id: str) -> str:
    start = 2000 + int(game_id[3:5])
    return f"{start}-{(start + 1) % 100:02d}"


def clock_seconds(clock: str) -> float:
    match = re.fullmatch(r"PT(?:(\d+)M)?([\d.]+)S", clock)
    if not match:
        raise ValueError(f"Invalid play-by-play clock: {clock}")
    return 60 * int(match.group(1) or 0) + float(match.group(2))


def valid_id(value) -> int | None:
    try:
        number = int(value)
        return number if number > 0 else None
    except (TypeError, ValueError, OverflowError):
        return None


def match_shot(shot_rows, used: set[int], action, result: str) -> int | None:
    """Match within a second; leave uncertain or unavailable locations blank."""
    second = clock_seconds(str(action.clock))
    made = result == "made"
    candidates = []
    for index, shot in enumerate(shot_rows):
        if index in used or int(shot.PERIOD) != int(action.period) or int(shot.PLAYER_ID) != int(action.personId):
            continue
        if bool(shot.SHOT_MADE_FLAG) != made:
            continue
        distance = abs(second - (60 * int(shot.MINUTES_REMAINING) + int(shot.SECONDS_REMAINING)))
        if distance <= 1.01:
            candidates.append((distance, index))
    candidates.sort()
    if not candidates or (len(candidates) > 1 and candidates[0][0] == candidates[1][0]):
        return None
    return candidates[0][1]


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
    try:
        endpoint.get_request()
    except ValueError as exc:
        raise RuntimeError(f"NBA play-by-play data is unavailable for game {args.game_id}: {exc}") from exc
    rows = endpoint.play_by_play.get_data_frame()
    if rows.empty:
        print("No play-by-play data found for this game.")
        return
    season = args.season or season_for_game(args.game_id)
    season_type = args.season_type or ("Playoffs" if args.game_id.startswith("004") else "Regular Season")
    time.sleep(1)
    chart = ShotChartDetail(team_id=0, player_id=0, game_id_nullable=args.game_id,
                           season_nullable=season, season_type_all_star=season_type,
                           context_measure_simple="FGA", get_request=False)
    try:
        chart.get_request()
        shot_rows = list(chart.shot_chart_detail.get_data_frame().itertuples(index=False))
    except ValueError:
        shot_rows = []
    used: set[int] = set()
    jersey_numbers: dict[int, str] = {}
    player_names: dict[int, str] = {}
    team_ids = sorted({team_id for row in rows.itertuples(index=False)
                       if (team_id := valid_id(row.teamId)) is not None})
    for team_id in team_ids:
        time.sleep(1)
        roster = CommonTeamRoster(team_id=team_id, season=season, get_request=False)
        try:
            roster.get_request()
            players = roster.common_team_roster.get_data_frame().itertuples(index=False)
        except ValueError:
            continue
        for player in players:
            number = str(player.NUM).strip()
            if number and number.lower() != "nan":
                jersey_numbers[int(player.PLAYER_ID)] = number
            player_names[int(player.PLAYER_ID)] = str(player.PLAYER)
    if args.output:
        Path(args.output).parent.mkdir(parents=True, exist_ok=True)
    destination = open(args.output, "w", newline="", encoding="utf-8") if args.output else nullcontext(sys.stdout)
    with destination as stream:
        writer = csv.writer(stream)
        writer.writerow(("game_id", "period", "clock", "team", "player", "result", "description",
                         "loc_x", "loc_y", "shot_distance", "jersey_number", "player_full_name"))
        for row in rows.itertuples(index=False):
            if row.isFieldGoal not in (1, True, "1", "true", "True"):
                continue
            result = str(row.shotResult).lower()
            if result not in ("made", "missed"):
                result = "made" if str(row.actionType).lower() == "made shot" else "missed"
            shot_index = match_shot(shot_rows, used, row, result)
            shot = shot_rows[shot_index] if shot_index is not None else None
            if shot_index is not None:
                used.add(shot_index)
            writer.writerow((args.game_id, row.period, row.clock, row.teamTricode,
                             row.playerName, result, row.description,
                             shot.LOC_X if shot else "", shot.LOC_Y if shot else "",
                             shot.SHOT_DISTANCE if shot else "", jersey_numbers.get(valid_id(row.personId), ""),
                             player_names.get(valid_id(row.personId), "")))


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
    shots.add_argument("--season", type=season_value, help="YYYY-YY (inferred from game ID by default)")
    shots.add_argument("--season-type", choices=("Regular Season", "Playoffs", "PlayIn", "Pre Season", "All Star"),
                       help="default: Playoffs for 004 games, otherwise Regular Season")
    shots.add_argument("--output", "-o", metavar="FILE", help="write CSV to FILE instead of standard output")
    shots.set_defaults(func=field_goal_attempts)
    args = parser.parse_args()
    try:
        args.func(args)
    except Exception as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
