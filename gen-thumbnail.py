#!/usr/bin/env python3
"""Render a 1280x720 basketball thumbnail with the Playwright template."""

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parent
WEB = ROOT / "thumbnail-web"
PUBLIC = WEB / "public"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("home", help="Home team abbreviation, such as DAL")
    parser.add_argument("away", help="Away team abbreviation, such as CLE")
    parser.add_argument("background", type=Path, help="Path to the background image")
    parser.add_argument("output", type=Path, help="Path for the rendered PNG")
    args = parser.parse_args()

    background = args.background.expanduser().resolve()
    output = args.output.expanduser().resolve()
    if not background.is_file():
        parser.error(f"background file does not exist: {background}")

    # Use a unique name so an existing public asset is never overwritten.
    with tempfile.TemporaryDirectory(prefix="thumbnail-render-") as temporary:
        screenshot = Path(temporary) / "thumbnail.png"
        with tempfile.NamedTemporaryFile(
            prefix="thumbnail-bg-", suffix=background.suffix, dir=PUBLIC, delete=False
        ) as staged_file:
            staged = Path(staged_file.name)
        try:
            shutil.copyfile(background, staged)
            environment = os.environ.copy()
            environment.update(
                HOME_TEAM=args.home,
                AWAY_TEAM=args.away,
                BACKGROUND_IMAGE=staged.name,
                SCREENSHOT_PATH=str(screenshot),
            )
            subprocess.run(
                ["npx", "playwright", "test", "tests/example.spec.ts", "--reporter=line"],
                cwd=WEB,
                env=environment,
                check=True,
            )
            output.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(screenshot, output)
        finally:
            staged.unlink(missing_ok=True)

    print(f"Saved {output}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, subprocess.CalledProcessError) as error:
        print(f"Thumbnail render failed: {error}", file=sys.stderr)
        sys.exit(1)
