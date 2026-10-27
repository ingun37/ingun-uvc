# OCR process

`main.py` is the persistent Python process used by `time_mapper_lib/`; read
that project's [AGENTS.md](../time_mapper_lib/AGENTS.md) when changing the
wire protocol or game-time semantics.

- Use the local PaddleOCR PP-OCRv6 pipeline with a compatible PaddlePaddle CPU
  engine. The distribution is named `paddlepaddle`; the unrelated distribution
  named `paddle` is not the engine. Preserve dependency pins unless the change
  explicitly requires updating them.
- The process receives width and height as arguments, then consecutive RGB24
  frames of exactly `width * height * 3` bytes on stdin. Send `READY` after
  model initialization; for each frame, write one line containing a whole game
  second or `-` when no valid clock is found. Keep diagnostics on stderr.
- Recognize `mm:ss` and `:ss.s`; fractional readings map to their whole
  second. Preserve the distinction between no recognized clock and a valid
  zero-second clock. Do not silently infer missing readings.
- Model files may download on first use. Do not switch inference to a cloud
  provider without an explicit request.

Run parser tests from the repository root:

```sh
PYTHONDONTWRITEBYTECODE=1 ocr/.venv/bin/python -m unittest discover \
  -s ocr -p 'test_*.py'
```
