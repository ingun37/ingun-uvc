"""Persistent PP-OCRv6 worker for the C++ video mapper.

Protocol: width and height are argv values; stdin carries consecutive RGB24
frames of that size. One JSON line on stdout follows each frame with the
recognized text and parsed whole game seconds (null if none). Diagnostics go
to stderr.
"""

from __future__ import annotations

import json
import re
import sys
from importlib.util import find_spec

import numpy as np


CLOCK = re.compile(r"(?<!\d)(?:(\d{1,2}):(\d{2})|:(\d{2})\.(\d))(?!\d)")


def parse_game_time(text: str) -> int | None:
    # OCR often inserts spaces around the colon or decimal point.
    normalized = re.sub(r"\s*([:.])\s*", r"\1", text)
    match = CLOCK.search(normalized)
    if match is None:
        return None
    if match.group(1) is not None:
        minutes, seconds = int(match.group(1)), int(match.group(2))
    else:
        minutes, seconds = 0, int(match.group(3))
    if seconds >= 60:
        return None
    return minutes * 60 + seconds


def read_exactly(stream, size: int) -> bytes:
    chunks = bytearray()
    while len(chunks) < size:
        part = stream.read(size - len(chunks))
        if not part:
            if chunks:
                raise EOFError("Incomplete RGB frame from C++")
            return b""
        chunks.extend(part)
    return bytes(chunks)


def parse_candidates(candidates: list[str]) -> int | None:
    for text in candidates:
        if (seconds := parse_game_time(text)) is not None:
            return seconds
    return parse_game_time(" ".join(candidates))


def recognize_clock(ocr, rgb: np.ndarray) -> tuple[list[str], int | None]:
    # PaddleOCR expects OpenCV-style BGR input.
    results = ocr.predict(rgb[:, :, ::-1].copy())
    candidates = []
    for result in results:
        data = result.json.get("res", result.json)
        for text, score in zip(data.get("rec_texts", []), data.get("rec_scores", [])):
            if float(score) >= 0.5:
                candidates.append(text)
    return candidates, parse_candidates(candidates)


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("Usage: main.py WIDTH HEIGHT")
    width, height = map(int, sys.argv[1:])
    if width <= 0 or height <= 0:
        raise ValueError("Invalid image dimensions")
    if find_spec("paddle") is None:
        raise RuntimeError("Install the PaddlePaddle CPU engine (package: paddlepaddle)")
    import paddle

    if not hasattr(paddle, "device"):
        raise RuntimeError(
            "This 'paddle' module is not the PaddlePaddle engine; install "
            "the 'paddlepaddle' package, not the unrelated 'paddle' package"
        )

    from paddleocr import PaddleOCR

    ocr = PaddleOCR(
        ocr_version="PP-OCRv6",
        use_doc_orientation_classify=False,
        use_doc_unwarping=False,
        use_textline_orientation=False,
    )
    output = sys.stdout.buffer
    output.write(b"READY\n")
    output.flush()
    while frame := read_exactly(sys.stdin.buffer, width * height * 3):
        rgb = np.frombuffer(frame, dtype=np.uint8).reshape(height, width, 3)
        texts, seconds = recognize_clock(ocr, rgb)
        output.write((json.dumps({"texts": texts, "seconds": seconds}) + "\n").encode())
        output.flush()


if __name__ == "__main__":
    main()
