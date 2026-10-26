---
name: paddleocr
description: Extract text from images, screenshots, and scanned PDFs using this repository's local PaddleOCR MCP server. Use for OCR requests, including capture-card screenshots.
---

Use the `ocr` tool exposed by the `paddleocr` MCP server. Inspect its current
input schema before calling it; supply absolute paths for local files.
Use file paths for PDFs: local inference does not support Base64 PDF inputs.

The project configuration is `.codex/config.toml`. It runs `ocr/.venv` using
PP-OCRv5 on CPU with local inference and no API credentials. Preserve the pins
in `ocr/requirements.txt`: `paddleocr_mcp==0.8.5` and `paddleocr==3.7.0`.

Keep recognized text in reading order, preserving meaningful line breaks.
Distinguish recognition from interpretation and flag uncertain characters,
especially in numbers, identifiers, and code. Use returned confidence and
location data when available. Save output to a file when requested.

If the tool is unavailable, check that the project configuration was loaded
(restart the Codex session after adding it) and that `ocr/.venv` exists.
Local inference also requires a compatible PaddlePaddle CPU engine, absent
from the current requirements. The existing environment uses Python 3.14;
verify engine wheel support before installing it or choosing a compatible
Python environment. Report dependency failures rather than silently switching
to a cloud provider. First inference may download models.

Reference: https://github.com/PaddlePaddle/PaddleOCR/blob/main/docs/version3.x/integrations/mcp_server.en.md
