import argparse
import csv
from datetime import date
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

import pandas as pd

import main


def shot(game_date, event_id, made=0):
    return {
        "GAME_DATE": game_date, "GAME_ID": "0022600001", "GAME_EVENT_ID": event_id,
        "PLAYER_ID": 1630170, "PLAYER_NAME": "Devin Vassell", "TEAM_ID": 1610612759,
        "TEAM_NAME": "San Antonio Spurs", "PERIOD": 1, "MINUTES_REMAINING": 8,
        "SECONDS_REMAINING": 25, "SHOT_ATTEMPTED_FLAG": 1, "SHOT_MADE_FLAG": made,
        "EVENT_TYPE": "Made Shot" if made else "Missed Shot", "ACTION_TYPE": "Jump Shot",
        "SHOT_TYPE": "3PT Field Goal", "SHOT_ZONE_BASIC": "Above the Break 3",
        "SHOT_ZONE_AREA": "Center(C)", "SHOT_ZONE_RANGE": "24+ ft.",
        "SHOT_DISTANCE": 27, "LOC_X": 12, "LOC_Y": 255, "HTM": "SAS", "VTM": "DAL",
    }


class PlayerAttemptsTests(unittest.TestCase):
    def test_all_season_types_dates_and_locations(self):
        calls = []

        class FakeChart:
            def __init__(self, **kwargs):
                calls.append(kwargs)
                season_type = kwargs["season_type_all_star"]
                rows = {
                    "Regular Season": [shot("2026-11-01", 7), shot("2026-10-31", 8)],
                    "Playoffs": [shot("2026-11-02", 9, made=1)],
                    "PlayIn": [shot("2026-11-01", 7)],
                }.get(season_type, [])
                self.shot_chart_detail = type("DataSet", (), {"get_data_frame": lambda _: pd.DataFrame(rows)})()

            def get_request(self):
                pass

        with TemporaryDirectory() as directory, patch.object(main, "ShotChartDetail", FakeChart), patch.object(main.time, "sleep"):
            output = Path(directory) / "shots.csv"
            args = argparse.Namespace(player_id=1630170, start_date=date(2026, 11, 1),
                                      end_date=date(2026, 11, 2), output=str(output))
            main.player_attempts(args)
            with output.open(newline="") as stream:
                rows = list(csv.DictReader(stream))

        self.assertEqual(len(calls), 3)
        self.assertEqual({call["season_type_all_star"] for call in calls},
                         {"Regular Season", "Playoffs", "PlayIn"})
        self.assertTrue(all(call["season_nullable"] == "2026-27" and
                            call["date_from_nullable"] == "11/01/2026" and
                            call["date_to_nullable"] == "11/02/2026" and
                            call["context_measure_simple"] == "FGA" for call in calls))
        self.assertEqual([row["game_event_id"] for row in rows], ["7", "9"])
        self.assertEqual([row["result"] for row in rows], ["missed", "made"])
        self.assertEqual(rows[0]["loc_x"], "12")
        self.assertEqual(rows[0]["loc_y"], "255")

    def test_failed_request_does_not_write_csv(self):
        class BrokenChart:
            def __init__(self, **kwargs):
                pass

            def get_request(self):
                raise ValueError("unavailable")

        with TemporaryDirectory() as directory, patch.object(main, "ShotChartDetail", BrokenChart):
            output = Path(directory) / "shots.csv"
            args = argparse.Namespace(player_id=1630170, start_date=date(2026, 11, 1),
                                      end_date=date(2026, 11, 2), output=str(output))
            with self.assertRaisesRegex(RuntimeError, "Could not fetch 2026-27 Regular Season"):
                main.player_attempts(args)
            self.assertFalse(output.exists())

    def test_cross_season_dates(self):
        self.assertEqual(list(main.seasons_between(date(2026, 5, 1), date(2026, 11, 1))),
                         ["2025-26", "2026-27"])


if __name__ == "__main__":
    unittest.main()
