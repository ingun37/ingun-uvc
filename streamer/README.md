# Video source inspector

Open `Untitled Project.xcodeproj` in Xcode, select the MyApp scheme and run on
My Mac. The project targets macOS 27 with the current SDK. Allow camera access
when prompted; the app does not request microphone access.

The source list includes external capture cards/cameras and built-in cameras.
AVFoundation exposes video sources rather than a separate capture-card category.
Refresh rescans sources. Selecting a source opens a session and a live preview.
Back releases the session owner, stops capture on its serial queue and removes
its inputs. Capture work is not retained by notification observers.

USB details come from IOKit and are shown only when the AVFoundation identifier
matches the registry location, vendor and product IDs. Non-USB devices and
sources whose descriptors are hidden by macOS show an unavailable explanation;
interface classes are never inferred from the camera name.

## Hardware validation

1. Launch and allow camera access; check that an attached UVC card is listed.
2. Disconnect/reconnect the card and Refresh; verify the list updates.
3. Select the card with an active HDMI source; verify moving video and device,
   media, codec, resolution, frame-rate and USB interface information.
4. Go Back; verify the camera-in-use indicator clears. Reopen the same source.
5. Disconnect during preview; verify the list returns with a message.
6. Disable camera access in System Settings, relaunch, and verify the permission
   explanation and settings button. Re-enable access and Refresh (macOS may
   require relaunching after a privacy setting changes).

Build check (without signing):

```sh
xcodebuild -project 'Untitled Project.xcodeproj' -scheme MyApp \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```
