# Project handoff

Updated 2026-10-18 (Asia/Seoul).

## Scope and current state

This repository contains a native macOS SwiftUI capture-card inspector in
`streamer/`. Read `streamer/SPEC.md` for the original requirements. Target the
latest macOS/SDK; no mobile or backward compatibility is required. Follow RAII
and avoid nullable stored properties where practical.

The user intentionally reverted the recording implementation so it can be
implemented in a new session. The working tree was clean before this handoff
was added. Recording and audio capture are NOT currently implemented. Do not
mistake the earlier recording work described below for code that still exists.

## Implemented and retained

- Video device discovery through AVFoundation, including external capture
  devices and built-in cameras; Refresh rescans and sorts by name.
- Selecting a device opens a capture session and shows device details plus a
  400 × 225 live preview.
- Camera permission instructions, capture errors/interruption messages, and
  selected-device disconnection handling.
- Back returns to discovery and releases capture resources.
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
  is currently read-only. No microphone permission/capability is configured.

## Next feature requested by the user

Use AVCaptureMovieFileOutput to record video into a file:

1. Start recording immediately when opening the selected source.
2. Use a temporary directory and a unique temporary filename.
3. Capture audio too.
4. On Back, finish recording and show a native save dialog (NSSavePanel).
5. Default save directory: the actual user's ~/Movies.
6. Default filename: current local date/time, with a movie extension. The
   reverted attempt used `yyyy-MM-dd HH-mm-ss.mov`; the user did not mandate
   that exact formatting.

The user's latest request was only to write this handoff, not to restore the
recording implementation in the current session.

## Recording design considerations from the reverted attempt

These are implementation notes, not additional user requirements:

- Add AVCaptureMovieFileOutput to the same session used by the preview.
- Add/request microphone permission (NSMicrophoneUsageDescription and audio
  input sandbox capability), and change user-selected file access to readwrite.
- Prefer audio from the selected device or its `linkedDevices`. A fallback to
  the system default audio input was used previously; display the selected audio
  source so the user can tell whether HDMI/card audio or a microphone is used.
  The exact fallback policy was not explicitly chosen by the user.
- Wait for AVCaptureFileOutputRecordingDelegate.didFinishRecordingTo before
  saving or releasing recording resources. stopRecording() is asynchronous.
  Retain session/delegate ownership until finalization, including on disconnect
  or window closure. Handle immediate Back before recording has fully started.
- Check AVErrorRecordingSuccessfullyFinishedKey: an error callback may still
  describe a usable finalized recording.
- Prevent duplicate Back operations while finalizing/saving. Preserve the
  finalized temporary file if the save panel is canceled or saving fails, and
  permit retry. Do not overwrite/delete an existing destination before a
  successful copy. These behaviors were chosen in the reverted implementation.
- Large file copying should happen off the main actor.
- Resolve the real user's Movies directory: a sandboxed app's home-directory
  APIs may point to the app container. The previous attempt used getpwuid/getuid
  to obtain the actual user home for the panel's default directory.
- A save-panel grant does not necessarily permit arbitrary sibling files.
  For staged replacement, use FileManager's itemReplacementDirectory appropriate
  for the destination, rather than inventing a sibling staging filename.
- The previous attempt left abandoned recordings in the system temporary
  directory for eventual system cleanup. Reconsider cleanup/recovery deliberately.
- Avoid globally suppressing console logging or disabling sandboxing.

## Validation and known limits

The retained preview implementation previously passed a Debug build and
`git diff --check`. The reverted recording implementation also compiled; its
file-save helper passed synthetic checks for a new destination, replacement,
temporary cleanup, and preserving the destination when source copying fails.
Those recording checks do NOT validate the current source or hardware capture.
Live video/audio recording, synchronization, save-panel sandbox behavior, and
recording lifecycle edge cases still need hardware/UI validation.

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
