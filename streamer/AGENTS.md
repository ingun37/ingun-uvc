# Project handoff

Original handoff updated 2026-11-11; legacy status updated 2026-11-14
(Asia/Seoul).

`streamer/` is now a legacy reference project. `GuraStreaming/` replaces it as
the active capture app; see [../GuraStreaming/AGENTS.md](../GuraStreaming/AGENTS.md)
for current capture work. The details below document this older implementation
when changes to `streamer/` itself are needed.

## Scope and current state

This project is a native macOS SwiftUI capture-card inspector. Target the latest macOS/SDK; no mobile or backward compatibility is required. Follow RAII
and avoid nullable stored properties where practical. Prefer immutability over mutability.

## Implemented and retained

- Video device discovery through AVFoundation, including external capture
  devices and built-in cameras; Refresh rescans and sorts by name.
- Selecting a device opens a capture session and shows device details plus an
  adjustable-width live preview. AVCaptureVideoDataOutput supplies BGRA frames;
  Core Video maps them to Metal textures for aspect-fit drawing in CAMetalLayer.
  The reason why not using AVCaptureVideoPreviewLayer is that the AVCaptureVideoPreviewLayer works as a direct client of the capture session, minimizing the window forces the preview layer to cease drawing frames, which stalls the shared AVCaptureSession pipeline and freezes your AVCaptureFileOutput recording.
- Camera permission instructions, capture errors/interruption messages, and
  selected-device disconnection handling.
- Back returns to discovery and releases capture resources.
- The detail view offers an audio-source picker and a recording-frame-rate
  picker populated from the active video format's supported ranges. Fixed-rate
  modes use AVFoundation's exact frame durations, including rates displayed as
  30 fps whose actual duration differs slightly from 1/30 second. The picker
  still lists higher supported rates, but recording above a displayed 30 fps
  is blocked with a warning before requesting microphone access.
- Record opens a separate view with live preview and a temporary .mov path.
  MovieRecording owns the temporary directory and AVCaptureMovieFileOutput delegate;
  capture output changes and start/stop use CaptureResource's serial queue.
  The device configuration lock is held through the session commit while setting
  the selected frame duration. Recording fails before starting if the session
  does not retain that duration. The optional timer can finish a recording.
  Done waits for finalization; MovieRecording saves a timestamped .mov in Movies.
  Save failure retains the temporary movie for retry; success returns to preview.
  Recording includes the selected audio input, preferring combined/linked
  capture-device audio; recording requests microphone permission and rejects
  missing audio connections.
- Idle system and display sleep prevention during preview. This does not
  override explicit Sleep commands or laptop lid closure.
- IOKit USB vendor/product/location and interface class/subclass lookup when
  the device identifier can be matched; unavailable descriptors are explained.

## Code map

- `Streamer/MyApp.swift`: app entry and WindowGroup.
- `Streamer/CaptureModel.swift`:
  - `CaptureModel` is observable state and actions. `Screen` covers device
    discovery, opening, detail, and recording.
  - `CaptureResource` owns AVCaptureSession, device input, video data output,
    and Metal preview renderer. Start/stop and recording configuration run on a
    serial dispatch queue; deinit schedules stop and input removal.
  - `PreviewActivity` owns a ProcessInfo activity token with
    idleDisplaySleepDisabled and idleSystemSleepDisabled; deinit ends it.
  - `CaptureFailure` provides a readable unsupported-input error.
- `Streamer/ContentView.swift`:
  - `ContentView` owns the model in @State, switches screens, and subscribes to
    capture notifications. `deviceList` renders discovery/permission states.
  - `DeviceDetail` builds metadata rows and displays preview and USB details.
  - `CapturePreview` bridges SwiftUI to AppKit using NSViewRepresentable.
  - `PreviewView` hosts the renderer's CAMetalLayer and sizes its drawable.
- `Streamer/MetalPreviewRenderer.swift`: maps BGRA capture pixel buffers to
  Metal textures with Core Video and draws an aspect-fit preview on the GPU.
- `Streamer/MovieRecording.swift`: owns the temporary movie, recording phases,
  file-output delegate callbacks, and cleanup. `CaptureResource` retains the
  capture session while recording finalizes.
- `Streamer/USBDetails.swift`: DetailRow value type and IOKit lookup.
  Registry handles are released with defer. Identifier parsing is a best-effort
  match, not a universal guarantee for all AVFoundation devices.
- `Streamer.xcodeproj/project.pbxproj`: synchronized source
  folder, Streamer scheme, macOS 27 target, main-actor default isolation. Camera
  sandbox access and camera usage description exist. User-selected file access
  is read-write for saving recordings. Microphone usage description and audio-input sandbox capability are configured.

## Validation and known limits

The user confirmed the live preview works with their capture setup. One capture
card produced a slow, laggy .mov reported as 120 fps even when 30 fps was chosen;
another card produced smooth output near 29 fps. A subsequent attempt failed
with "The capture session did not retain the selected frame rate." The latest
change holds the device lock through session commit, but the user has not yet
reported a hardware retest. Do not assume the selected frame rate matches the
saved movie's timestamps or that the bitrate difference explains slow playback.
Inspect a new sample's timestamps and actual frame cadence if the issue persists.
The latest change passed a Debug build and `git diff --check`.

Build from the repository root:

```sh
xcodebuild -project streamer/Streamer.xcodeproj -scheme Streamer \
  -configuration Debug -derivedDataPath /tmp/ingun-uvc-build \
  CODE_SIGNING_ALLOWED=NO build
```

Xcode 27 was available. In the Codex sandbox, Swift Observation macro plugin
execution failed with a malformed-response error; the same build succeeded
with approved execution outside the sandbox. This was an environment issue.
The App Intents metadata extraction warning (no AppIntents dependency) was
non-blocking. Builds without signing are compilation checks only.

## Prior console-warning investigation

The user reported linkd.autoShortcut/Intents XPC errors, media plug-in factory
warnings, legacy UUID fallback, disabled sensitive-content analysis, missing
DetachedSignatures database, internal material/script binding diagnostics, and
MLE5Engine disabled. Source inspection found no corresponding app API misuse;
no code changes were made. Treat these as likely framework log noise only when
there is no associated malfunction. Do not assume they prove capture failure.
Apple guidance: https://developer.apple.com/forums/thread/115461
