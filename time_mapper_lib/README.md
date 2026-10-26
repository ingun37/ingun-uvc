# Time mapper library

Requires FFmpeg development libraries (`libavcodec`, `libavformat`,
`libavutil`, and `libswscale`) and a Python environment with PaddleOCR,
PaddlePaddle, and NumPy. The default interpreter is `../ocr/.venv/bin/python`.
Set `TIME_MAPPER_PYTHON` to another interpreter path if needed. The engine's
Python distribution is named `paddlepaddle` (distinct from `paddle`). The
PP-OCRv6 model files are downloaded on first use unless already cached.

`map_gametime_to_videotime(video_path, region, output_json_path)` accepts a
pixel rectangle `{x, y, width, height}`. It samples the video clock every 0.5
seconds, writes JSON to the supplied path, and returns the same chronological
list in memory. Each JSON item is
`{"game_second": 440, "start_seconds": 2.0, "end_seconds": 3.0}`; the video
range has an exclusive end. Contiguous observations of the same second merge.
Missing clocks leave gaps, and a game second may occur in multiple list items,
including across quarters. Fractional clock values such as `:06.1` map to
second `6`. List order follows video time, but a replay or missing clock can
also repeat a second within one quarter, so list position does not prove the
quarter by itself.

For callers that provide their own OCR, the four-argument overload accepts
a callback receiving cropped RGB24 pixels. It also makes video sampling and
range aggregation testable without loading OCR models.

Build and test on macOS:

```shell
cmake -S time_mapper_lib -B build/time_mapper_lib
cmake --build build/time_mapper_lib
ctest --test-dir build/time_mapper_lib --output-on-failure
ocr/.venv/bin/python -m unittest discover -s ocr -p 'test_*.py'
```

To exercise live OCR on both bundled videos, run the test executable with
`TIME_MAPPER_LIVE_OCR=1` after the models are available.
