# Sourced by build.sh and release-zip.sh. Selects the signing identity:
#   IDENTITY      the "Developer ID Application" identity, else "-" (ad-hoc)
#   DEVELOPER_ID  1 for a Developer ID identity
#   SIGN_FLAGS    hardened runtime + secure timestamp for a Developer ID
# Set MACMIXER_ADHOC=1 to force an ad-hoc signature (for contributors).
IDENTITY="-"
DEVELOPER_ID=0
SIGN_FLAGS=""
if [ "${MACMIXER_ADHOC:-0}" != 1 ]; then
  FOUND=$(security find-identity -v -p codesigning 2>/dev/null |
    sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
  if [ -n "$FOUND" ]; then
    IDENTITY="$FOUND"
    DEVELOPER_ID=1
    SIGN_FLAGS="--options runtime --timestamp"
  fi
fi

# sign_app <path to MacMixer.app>
sign_app() {
  echo "== Sign with: $IDENTITY"
  # shellcheck disable=SC2086
  codesign --force $SIGN_FLAGS --entitlements MacMixer/MacMixer.entitlements \
    -s "$IDENTITY" "$1"
  codesign --verify --deep --strict "$1" && echo "Signature OK"
}
