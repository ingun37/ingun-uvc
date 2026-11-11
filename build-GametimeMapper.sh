#!/usr/bin/env zsh

set -e
rm -rf ./GametimeMapper/build
mkdir ./GametimeMapper/build
xcodebuild archive \
  -project ./GametimeMapper/GametimeMapper.xcodeproj \
  -scheme GametimeMapperUI \
  -archivePath ./GametimeMapper/build/GametimeMapperUI.xcarchive

cp -R ./GametimeMapper/build/GametimeMapperUI.xcarchive/Products/Applications/GametimeMapperUI.app ./GametimeMapper/build/GametimeMapperUI.app