#!/usr/bin/env zsh

set -e
rm -rf ./GuraStreaming/build
mkdir ./GuraStreaming/build
xcodebuild archive \
  -project ./GuraStreaming/GuraStreaming.xcodeproj \
  -scheme GuraStreaming \
  -archivePath ./GuraStreaming/build/GuraStreaming.xcarchive

cp -R ./GuraStreaming/build/GuraStreaming.xcarchive/Products/Applications/GuraStreaming.app ./GuraStreaming/build/GuraStreaming.app