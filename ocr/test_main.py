import unittest

from main import parse_game_time


class GameTimeParsingTests(unittest.TestCase):
    def test_minutes_seconds(self):
        self.assertEqual(parse_game_time("2ND 7:20 21"), 440)
        self.assertEqual(parse_game_time("1:04"), 64)

    def test_fractional_seconds(self):
        self.assertEqual(parse_game_time("3RD :22.2 12"), 22)
        self.assertEqual(parse_game_time(":06.1"), 6)

    def test_missing_or_invalid(self):
        self.assertIsNone(parse_game_time("REPLAY"))
        self.assertIsNone(parse_game_time("2:78"))
        self.assertIsNone(parse_game_time(":61.3"))


if __name__ == "__main__":
    unittest.main()
