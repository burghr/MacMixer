#!/bin/bash
# Build MacMixer v2 and install it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

if true; then  # always regenerate: new .swift files must join the project
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

source ./signing.sh
sign_app "$APP"

echo "Installing to /Applications…"
killall MacMixer 2>/dev/null || true
sleep 1
rm -rf /Applications/MacMixer.app
cp -R "$APP" /Applications/MacMixer.app

echo "Done. Launch with: open -a MacMixer"
