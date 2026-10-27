# Time mapper app

Target the latest macOS/SDK; no mobile or backward compatibility is required.
Follow RAII, avoid nullable stored properties where practical, and prefer
immutability over mutability.

## Workflow and code map

- `time_mapper/ContentView.swift` moves through video selection, playback and
  rectangle selection, then processing. Keep long-running mapping off the main
  actor and show progress, success, and errors in the Process view.
- `time_mapper/VideoSession.swift` owns AVPlayer, the chosen URL, and the
  security-scoped access lifetime. `decoderRegion()` transforms a rectangle
  drawn on the displayed video back into source-video pixel coordinates.
- `time_mapper/VideoCanvas.swift` draws the selection in top-left video pixel
  coordinates. Preserve that coordinate contract when changing the canvas.
- `time_mapper/TimeMapperBridge.h/.mm` connects Swift to the C++ function in
  `../time_mapper_lib/library.cpp`. Read the library and OCR project guides when
  changing this processing path.
- Processing writes `<video-name>.gametime.json` beside the selected video;
  existing files are preserved by adding a numeric suffix.

## Build and local dependencies

The Xcode project compiles the C++ library source and links Homebrew FFmpeg.
It links Homebrew Tesseract and uses its English trained data in process.
The app sandbox is disabled so this local development build can create a JSON
sibling of the selected video. Packaging a standalone app requires bundling
these dependencies and revisiting file access.

Build from the repository root:

```sh
xcodebuild -project time_mapper/time_mapper.xcodeproj -scheme time_mapper \
  -configuration Debug -destination 'generic/platform=macOS' \
  -derivedDataPath /tmp/time-mapper-xcode CODE_SIGNING_ALLOWED=NO build
```

If Swift macro helpers fail inside the command sandbox, retry the same build
with approved execution outside it. A successful build checks compilation;
use the `time_mapper_lib` tests for video mapping behavior.
