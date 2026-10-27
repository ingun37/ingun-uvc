# Time mapper C++ library

Follow RAII, avoid nullable stored properties where practical, and prefer
immutability over mutability. Keep the project on C++26.

See [README.md](README.md) for the public API and output format.

## Processing contract

- `map_gametime_to_videotime(video_path, region, output_json_path)` decodes
  with FFmpeg, samples every 0.5 seconds, passes RGB24 clock crops to an in-process Tesseract engine,
  and writes a chronological JSON array. Its return value has the same entries.
- `Region` uses source-frame pixels with a top-left origin. The Swift app
  converts its displayed selection before calling the library.
- Contiguous readings of the same whole game second merge into a video range.
  Missing readings create gaps; the same second can appear again later. The
  result does not identify quarters on its own.
- The current frame path converts each sampled full frame to RGB before
  copying the selected region. Crop-before-conversion was tried and reverted
  after it did not improve the user's 4K processing time. Measure decoding,
  conversion, and OCR separately before changing performance behavior again.
- Initialize Tesseract once per mapping and reuse it for each crop. Parse
  `mm:ss`, `:ss.s`, and `ss.s` as whole game seconds; preserve missing
  readings and valid zero-second readings separately.

## Validation

`tests.cpp` uses both files in `test-data/` with a deterministic OCR callback.
The optional `TIME_MAPPER_LIVE_OCR=1` run exercises the installed Tesseract engine. From the repository root:

```sh
cmake -S time_mapper_lib -B /tmp/time-mapper-build -G 'Unix Makefiles'
cmake --build /tmp/time-mapper-build
ctest --test-dir /tmp/time-mapper-build --output-on-failure
```

The live test needs Tesseract and English trained data.
