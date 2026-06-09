#!/bin/bash
# Build MacMixer v2 and install it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -d MacMixer.xcodeproj ]; then
    echo "Generating Xcode project…"
    ruby project.rb
fi

echo "Building…"
xcodebuild \
    -project MacMixer.xcodeproj \
    -target MacMixer \
    -configuration Release \
    SYMROOT="$(pwd)/.build" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_ALLOWED=YES \
    build

APP=".build/Release/MacMixer.app"
if [ ! -d "$APP" ]; then
    echo "Build did not produce $APP" >&2
    exit 1
fi

echo "Installing to /Applications…"
killall MacMixer 2>/dev/null || true
sleep 1
rm -rf /Applications/MacMixer.app
cp -R "$APP" /Applications/MacMixer.app

echo "Done. Launch with: open -a MacMixer"
