#!/bin/bash
# Build MacMixer, sign it with the Developer ID, notarize it, and make the
# zip for a GitHub release:
#   .build/MacMixer-<version>.zip  (MacMixer.app at the top level)
# The in-app updater downloads this file. Upload it to a release with the tag
# v<version>, for example:
#   gh release create v2.2.0 .build/MacMixer-2.2.0.zip --title "MacMixer 2.2.0"
set -euo pipefail
cd "$(dirname "$0")"

ruby project.rb
xcodebuild \
    -project MacMixer.xcodeproj \
    -target MacMixer \
    -configuration Release \
    SYMROOT="$(pwd)/.build" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_ALLOWED=YES \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
    build

APP=".build/Release/MacMixer.app"

source ./signing.sh
[ "$DEVELOPER_ID" = 1 ] || { echo "A release needs a Developer ID identity." >&2; exit 1; }
sign_app "$APP"

# Notarize: the keychain profile holds the Apple ID login for notarytool.
NOTARY_PROFILE=${NOTARY_PROFILE:-iodus-notary}
echo "== Notarize (profile $NOTARY_PROFILE)"
NZIP=".build/MacMixer-notarize.zip"
rm -f "$NZIP"
ditto -c -k --keepParent "$APP" "$NZIP"
xcrun notarytool submit "$NZIP" --keychain-profile "$NOTARY_PROFILE" --wait
rm -f "$NZIP"
xcrun stapler staple "$APP"
spctl --assess --type execute -vv "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
ZIP=".build/MacMixer-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Wrote $ZIP (tag: v$VERSION)"
