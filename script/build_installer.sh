#!/usr/bin/env bash
set -euo pipefail

CONFIGURATION="${1:-release}"
OUTPUT_DIRECTORY="${2:-.artifacts/installer}"
HELPER_APP="${3:-.artifacts/app/Microphone Control.app}"
PRODUCT_NAME="MicrophoneControlInstaller"
DISPLAY_NAME="Install Microphone Control"

case "$CONFIGURATION" in
  debug|release) ;;
  *)
    echo "usage: $0 [debug|release] [output-directory] [helper-app]" >&2
    exit 2
    ;;
esac

ROOT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$OUTPUT_DIRECTORY" != /* ]]; then
  OUTPUT_DIRECTORY="$ROOT_DIRECTORY/$OUTPUT_DIRECTORY"
fi
if [[ "$HELPER_APP" != /* ]]; then
  HELPER_APP="$ROOT_DIRECTORY/$HELPER_APP"
fi

if [[ ! -d "$HELPER_APP" ]]; then
  echo "helper app not found: $HELPER_APP" >&2
  exit 1
fi

INSTALLER_BUNDLE="$OUTPUT_DIRECTORY/$DISPLAY_NAME.app"
INSTALLER_CONTENTS="$INSTALLER_BUNDLE/Contents"
INSTALLER_MACOS="$INSTALLER_CONTENTS/MacOS"
PAYLOAD_DIRECTORY="$INSTALLER_CONTENTS/Resources/Payload"

cd "$ROOT_DIRECTORY"
swift build -c "$CONFIGURATION" --product "$PRODUCT_NAME"
BUILD_DIRECTORY="$(swift build -c "$CONFIGURATION" --show-bin-path)"

rm -rf "$INSTALLER_BUNDLE"
mkdir -p "$INSTALLER_MACOS" "$PAYLOAD_DIRECTORY"
cp "$BUILD_DIRECTORY/$PRODUCT_NAME" "$INSTALLER_MACOS/$PRODUCT_NAME"
cp "$ROOT_DIRECTORY/Resources/InstallerInfo.plist" "$INSTALLER_CONTENTS/Info.plist"
COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc --noextattr "$HELPER_APP" "$PAYLOAD_DIRECTORY/Microphone Control.app"
chmod 755 "$INSTALLER_MACOS/$PRODUCT_NAME"

SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:--}"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  codesign --force --options runtime --sign - "$INSTALLER_BUNDLE"
else
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$INSTALLER_BUNDLE"
fi

plutil -lint "$INSTALLER_CONTENTS/Info.plist"
codesign --verify --deep --strict --verbose=2 "$INSTALLER_BUNDLE"
echo "$INSTALLER_BUNDLE"
