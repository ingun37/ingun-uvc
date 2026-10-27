import unittest

from main import parse_candidates, parse_game_time


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

    def test_candidates_preserve_raw_text_and_parsed_zero(self):
        texts = ["1ST", ":00.4", "24"]
        self.assertEqual(parse_candidates(texts), 0)
        self.assertIsNone(parse_candidates(["REPLAY", "2:78"]))


if __name__ == "__main__":
    unittest.main()
