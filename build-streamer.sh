#!/usr/bin/env zsh

set -e
rm -rf streamer/build
mkdir streamer/build
xcodebuild archive \
  -project streamer/Streamer.xcodeproj \
  -scheme Streamer \
  -archivePath ./streamer/build/Streamer.xcarchive

cp -R ./streamer/build/Streamer.xcarchive/Products/Applications/Streamer.app ./streamer/build/Streamer.app