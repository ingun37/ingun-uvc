#!/usr/bin/env zsh

set -e
rm -rf ./ClipEditor/build
mkdir ./ClipEditor/build
xcodebuild archive \
  -project ./ClipEditor/ClipEditor.xcodeproj \
  -scheme ClipEditor \
  -archivePath ./ClipEditor/build/ClipEditor.xcarchive

cp -R ./ClipEditor/build/ClipEditor.xcarchive/Products/Applications/ClipEditor.app ./ClipEditor/build/ClipEditor.app