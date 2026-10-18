This document specifies what's expected from this application.

# Target platform

This app targets latest versions of MacOS. It does not target any mobile devices or other OS. Use the latest standard SDKs. No need for the backward support.

# Development philosophy

Follow RAII principles.

Avoid nullable properties. 


# Scenario

## Scene 1. UVC detection, list up, select

Detect every available capture cards and show the list.

Add a refresh button for re-running the detection and updating the list.

When an item is clicked, establish the session and any required resources and go to the `Scene 2`. I do not li

This step is similar as in OBS, going to `Add Source -> Video Capture Device -> Add a new Video Capture Device` and seeing all the available lists.

## Scene 2. Show the information of the UVC.

Show detailed information of the video source, such as device type, media type, interface class, interface subclas, etc.

Show a thumbnail that shows the streamed frames in real time.

Add a go-back button for deallocating resources and going back to the Scene 1.
