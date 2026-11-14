# GuraStreaming project guidance

Updated 2026-11-14 (Asia/Seoul).

## Scope

GuraStreaming is the active native macOS SwiftUI capture-card inspector and
recorder. It replaces `streamer/`, which remains in this repository for
historical reference. Target the current macOS SDK; no mobile compatibility is
required. Prefer clear resource ownership and keep capture callbacks short.

## Current workflow

1. Discover external video devices and built-in cameras. Refresh rescans the
   sorted source list. Camera access is requested before discovery.
2. Selecting a source opens a frame-rate selection scene. The picker lists
   supported boundaries and common rates from the active format, preferring
   29.97 fps, then 30 fps, then the closest rate to the device's current rate.
3. Opening the source configures `activeVideoMinFrameDuration` and
   `activeVideoMaxFrameDuration` while holding the device lock through the
   capture-session commit. The app checks that the selected duration remains.
4. The detail scene shows device and USB metadata, available color-profile
   fields, an aspect-fit Metal video preview, and an audio-level meter when a
   linked or same-name audio source is available and authorized. It does not
   play audio. Back releases the capture resource and returns to rate selection.
5. Record adds an `AVCaptureMovieFileOutput` to the existing session on its
   serial queue. Stop finalizes a timestamped `.mov` directly in `~/Movies`.
   The saved-path message appears only after the file-output delegate reports
   successful completion. Record is disabled while starting, recording, or
   stopping; Back is disabled during those phases.

## Code map

- `GuraStreaming/GuraStreamingApp.swift`: app entry and window.
- `GuraStreaming/ContentView.swift`: source list, frequency and detail scenes,
  preview view bridge, audio meter, and recording controls.
- `GuraStreaming/CaptureModel.swift`: discovery, permissions, screen state,
  session ownership, frame-rate configuration, and movie-output attachment.
- `GuraStreaming/MetalPreviewRenderer.swift`: one latest-frame slot protected by
  a short lock. A serial render queue maps YUV planes (or BGRA) from the retained
  `CVPixelBuffer` to Metal textures and draws into `CAMetalLayer`. It allows one
  GPU render and one waiting frame. The completion handler retains the buffer
  and texture wrappers until the GPU finishes.
- `GuraStreaming/AudioLevelMeter.swift`: audio callback retains only the latest
  waiting sample. A utility queue computes a bounded RMS level and publishes
  UI updates at most 20 times per second.
- `GuraStreaming/MovieRecording.swift`: movie-output delegate, recording phases,
  unique timestamped Movies path, and finalization result.
- `GuraStreaming/USBDetails.swift`: best-effort IOKit USB descriptor lookup.

## Validation and limits

Build from the repository root:

```sh
xcodebuild -project GuraStreaming/GuraStreaming.xcodeproj -scheme GuraStreaming \
  -configuration Debug -derivedDataPath /tmp/gurastreaming-build \
  CODE_SIGNING_ALLOWED=NO build
```

Debug builds have passed. This is a compilation check only; capture-card frame
cadence, preview, audio metering, movie finalization, and saved-file timestamps
still require hardware validation. Some devices advertise frame rates that do
not match delivered or recorded cadence. Inspect sample timestamps and the
saved movie if a rate looks wrong.

The project enables camera, audio-input, and Movies-folder sandbox access and
has camera and microphone usage descriptions. Some video sources do not expose
color metadata or a corresponding audio source. The current preview handles
8-bit bi-planar 4:2:0 YUV and BGRA; its YUV conversion uses a resolution-based
601/709 choice, so color accuracy needs further validation.

In the Codex sandbox, the Swift Observation macro plugin has produced a
malformed-response build error. An approved build outside the sandbox succeeds.
Builds without code signing do not verify runtime entitlements.
