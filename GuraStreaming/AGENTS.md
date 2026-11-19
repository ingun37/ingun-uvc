# GuraStreaming project guidance

Updated 2026-11-19 (Asia/Seoul).

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
   successful completion. The message reports whether Stop was clicked, frozen
   video was detected, or sound was absent; failures show their error. Saved
   recordings offer Open directory and Open file buttons. Record is disabled
   while starting, recording, or stopping; Back is disabled during those phases.
   Frozen-video and no-sound timeouts are adjustable before recording and each
   defaults to 60 seconds. Each setting and its status share one row. Repeated
   frames start the video countdown. A wall-clock silence countdown starts when
   movie recording begins, even if no audio buffers arrive; detected sound
   resets it. Either timeout stops recording.

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
- `GuraStreaming/MetalFreezeDetector.swift`: Metal compute comparison of a fixed
  256 × 144 pixel grid. It shares the preview device, command queue, and texture
  cache, holds one latest waiting frame, and uses sample timestamps for the
  countdown. Small codec differences are tolerated.
- `GuraStreaming/ThumbnailCandidateDetector.swift`: recording-only CLIP
  image/text scoring on the Neural Engine. A background queue analyzes at most
  one frame every five seconds using one latest-frame slot, writes candidate
  JPEGs to a recording-specific folder, and writes `log.csv` after queued work
  finishes. The CSV includes the top positive and negative descriptions, their
  cosine scores, the score margin, and five highest and lowest ranked prompts.
  An MIT-licensed CLIP image encoder and generated text embeddings are bundled
  with the app; the model license is in the project root. The image model and
  generated `clip-prompts.json` are git-ignored. Before building, run
  `GuraStreaming/Tools/download-clip-image-model`, copy
  `GuraStreaming/Tools/clip-labels.example.json` to the ignored
  `GuraStreaming/Tools/clip-labels.json`, and run
  `GuraStreaming/Tools/regenerate-clip-prompts`. Edit the labels file and rerun
  the generator to refresh the embeddings.
- `GuraStreaming/AudioLevelMeter.swift`: audio callback retains only the latest
  waiting sample. A utility queue computes RMS, reports sound to the silence
  detector, and publishes UI updates at most 20 times per second.
- `GuraStreaming/AudioSilenceDetector.swift`: independent serial-queue timer
  for the no-sound countdown and stop event. Audio capture callbacks never
  wait for it.
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

The frozen-video unit test reads `GuraStreamingTests/frozen-audible-small.mp4`
with a two-second timeout. The silence unit test reads the three-second,
audio-free `GuraStreamingTests/no_audio.mp4` at its recorded pace and checks a
two-second timeout and countdown. Builds and all three unit tests have passed;
capture-card frame cadence, preview, audio metering, recording stop and movie
finalization, and saved-file timestamps still require hardware validation.
Thumbnail classification quality and timestamp alignment with the recorded
movie also require capture-card validation. Some devices advertise frame rates
that do not match delivered or recorded cadence. Inspect sample timestamps
and the saved movie if a rate looks wrong.

The project enables camera, audio-input, and Movies-folder sandbox access and
has camera and microphone usage descriptions. Some video sources do not expose
color metadata or a corresponding audio source. The current preview handles
8-bit bi-planar 4:2:0 YUV and BGRA; its YUV conversion uses a resolution-based
601/709 choice, so color accuracy needs further validation.

In the Codex sandbox, the Swift Observation macro plugin has produced a
malformed-response build error. An approved build outside the sandbox succeeds.
Builds without code signing do not verify runtime entitlements.
