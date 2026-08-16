#!/usr/bin/env bash
set -euo pipefail

CONFIGURATION="${1:-release}"
OUTPUT_DIRECTORY="${2:-.artifacts/app}"
PRODUCT_NAME="MicrophoneControl"
DISPLAY_NAME="Microphone Control"

case "$CONFIGURATION" in
  debug|release) ;;
  *)
    echo "usage: $0 [debug|release] [output-directory]" >&2
    exit 2
    ;;
esac

ROOT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$OUTPUT_DIRECTORY" != /* ]]; then
  OUTPUT_DIRECTORY="$ROOT_DIRECTORY/$OUTPUT_DIRECTORY"
fi

APP_BUNDLE="$OUTPUT_DIRECTORY/$DISPLAY_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
LAUNCH_AGENTS="$APP_CONTENTS/Library/LaunchAgents"

cd "$ROOT_DIRECTORY"
swift build -c "$CONFIGURATION" --product "$PRODUCT_NAME"
BUILD_DIRECTORY="$(swift build -c "$CONFIGURATION" --show-bin-path)"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$LAUNCH_AGENTS"
cp "$BUILD_DIRECTORY/$PRODUCT_NAME" "$APP_MACOS/$PRODUCT_NAME"
cp "$ROOT_DIRECTORY/Resources/Info.plist" "$APP_CONTENTS/Info.plist"
cp "$ROOT_DIRECTORY/Resources/app.microphonecontrol.agent.plist" "$LAUNCH_AGENTS/app.microphonecontrol.agent.plist"
chmod 755 "$APP_MACOS/$PRODUCT_NAME"

SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:--}"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  codesign --force --options runtime --entitlements "$ROOT_DIRECTORY/Resources/MicrophoneControl.entitlements" --sign - "$APP_BUNDLE"
else
  codesign --force --options runtime --timestamp --entitlements "$ROOT_DIRECTORY/Resources/MicrophoneControl.entitlements" --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
fi

plutil -lint "$APP_CONTENTS/Info.plist" "$LAUNCH_AGENTS/app.microphonecontrol.agent.plist" "$ROOT_DIRECTORY/Resources/MicrophoneControl.entitlements"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
echo "$APP_BUNDLE"
