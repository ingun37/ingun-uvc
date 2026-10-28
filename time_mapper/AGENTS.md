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
- `time_mapper/GameTimeMapper.swift` decodes video with AVFoundation and recognizes the selected clock region with Vision. Keep sampling, parsing, and JSON range behavior aligned with the existing mapping format.
- Processing writes `<video-name>.gametime.json` beside the selected video;
  existing files are preserved by adding a numeric suffix.

## Build and local dependencies

The Xcode app uses system AVFoundation and Vision frameworks. It has no FFmpeg, C++, Python, or PaddleOCR build dependency. The app sandbox remains disabled for writing a JSON sibling of the selected video.

Build from the repository root:

```sh
xcodebuild -project time_mapper/time_mapper.xcodeproj -scheme time_mapper \
  -configuration Debug -destination 'generic/platform=macOS' \
  -derivedDataPath /tmp/time-mapper-xcode CODE_SIGNING_ALLOWED=NO build
```

If Swift macro helpers fail inside the command sandbox, retry the same build
with approved execution outside it. A successful build checks compilation;
run the app tests for clock parsing and range behavior.
