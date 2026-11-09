#!/usr/bin/env zsh

set -e
rm -rf ./UnifiedApp/build
mkdir ./UnifiedApp/build
xcodebuild archive \
  -project ./UnifiedApp/UnifiedApp.xcodeproj \
  -scheme UnifiedApp \
  -archivePath ./UnifiedApp/build/UnifiedApp.xcarchive

cp -R ./UnifiedApp/build/UnifiedApp.xcarchive/Products/Applications/UnifiedApp.app ./UnifiedApp/build/UnifiedApp.app