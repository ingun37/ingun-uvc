#!/usr/bin/env zsh

set -e
rm -rf ./TheMapper/build
mkdir ./TheMapper/build
xcodebuild archive \
  -project ./TheMapper/TheMapper.xcodeproj \
  -scheme TheMapper \
  -archivePath ./TheMapper/build/TheMapper.xcarchive

cp -R ./TheMapper/build/TheMapper.xcarchive/Products/Applications/TheMapper.app ./TheMapper/build/TheMapper.app