# Project handoff

Updated 2026-10-18 (Asia/Seoul).

## Scope and current state

This repository contains a native macOS SwiftUI capture-card inspector in
`streamer/`. Target the latest macOS/SDK; no mobile or backward compatibility is required. Follow RAII
and avoid nullable stored properties where practical.

## Implemented and retained

- Video device discovery through AVFoundation, including external capture
  devices and built-in cameras; Refresh rescans and sorts by name.
- Selecting a device opens a capture session and shows device details plus a
  400 × 225 live preview.
- Camera permission instructions, capture errors/interruption messages, and
  selected-device disconnection handling.
- Back returns to discovery and releases capture resources.
- Record opens a separate view with live preview and a temporary .mov path.
  MovieRecording owns the temporary directory and AVCaptureMovieFileOutput delegate;
  capture output changes and start/stop use CaptureResource's serial queue.
  Done waits for finalization, then offers NSSavePanel with Movies and a timestamp
  filename. Cancel/save failure retains the movie for retry; success returns to preview.
  Recording includes the selected audio input. Preview offers an audio-source picker,
  preferring combined/linked capture-device audio; recording requests microphone
  permission and rejects missing audio connections. Live recording/save still needs
  hardware validation.
- Idle system and display sleep prevention during preview. This does not
  override explicit Sleep commands or laptop lid closure.
- IOKit USB vendor/product/location and interface class/subclass lookup when
  the device identifier can be matched; unavailable descriptors are explained.

## Code map

- `streamer/MyApp/MyApp.swift`: app entry and WindowGroup.
- `streamer/MyApp/CaptureModel.swift`:
  - `CaptureModel` is observable state and actions. `Screen` is an enum with
    devices, opening(name), and detail(device, resource) cases.
  - `CaptureResource` owns AVCaptureSession and device input. Start/stop run on
    a serial dispatch queue; deinit schedules stop and input removal.
  - `PreviewActivity` owns a ProcessInfo activity token with
    idleDisplaySleepDisabled and idleSystemSleepDisabled; deinit ends it.
  - `CaptureFailure` provides a readable unsupported-input error.
- `streamer/MyApp/ContentView.swift`:
  - `ContentView` owns the model in @State, switches screens, and subscribes to
    capture notifications. `deviceList` renders discovery/permission states.
  - `DeviceDetail` builds metadata rows and displays preview and USB details.
  - `CapturePreview` bridges SwiftUI to AppKit using NSViewRepresentable.
  - `PreviewView` hosts AVCaptureVideoPreviewLayer; teardown detaches session.
- `streamer/MyApp/USBDetails.swift`: DetailRow value type and IOKit lookup.
  Registry handles are released with defer. Identifier parsing is a best-effort
  match, not a universal guarantee for all AVFoundation devices.
- `streamer/README.md`: run instructions and manual hardware checks.
- `streamer/Untitled Project.xcodeproj/project.pbxproj`: synchronized source
  folder, MyApp scheme, macOS 27 target, main-actor default isolation. Camera
  sandbox access and camera usage description exist. User-selected file access
  is read-write for saving recordings. Microphone usage description and audio-input sandbox capability are configured.

## Validation and known limits

The preview implementation previously passed a Debug build and
`git diff --check`. Live capture still needs hardware validation.

Build from the repository root:

```sh
xcodebuild -project 'streamer/Untitled Project.xcodeproj' -scheme MyApp \
  -configuration Debug -derivedDataPath /tmp/ingun-uvc-build \
  CODE_SIGNING_ALLOWED=NO build
```

Xcode 27.0 was available. In the Codex sandbox, Swift Observation macro plugin
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
