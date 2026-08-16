#!/usr/bin/env bash
set -euo pipefail

ROOT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIRECTORY="${ARTIFACT_DIRECTORY:-$ROOT_DIRECTORY/.artifacts/release}"
APP_BUILD_DIRECTORY="$ROOT_DIRECTORY/.artifacts/app"
INSTALLER_BUILD_DIRECTORY="$ROOT_DIRECTORY/.artifacts/installer"
DISPLAY_NAME="Install Microphone Control"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIRECTORY/Resources/Info.plist")"
ARCHIVE_BASENAME="Microphone-Control-$VERSION"
HELPER_APP="$APP_BUILD_DIRECTORY/Microphone Control.app"
INSTALLER_BUNDLE="$INSTALLER_BUILD_DIRECTORY/$DISPLAY_NAME.app"
DMG_ROOT="$ROOT_DIRECTORY/.artifacts/dmg-root"
DMG_PATH="$ARTIFACT_DIRECTORY/$ARCHIVE_BASENAME.dmg"
ZIP_PATH="$ARTIFACT_DIRECTORY/$ARCHIVE_BASENAME.zip"
CHECKSUM_PATH="$ARTIFACT_DIRECTORY/$ARCHIVE_BASENAME-SHA256.txt"

rm -rf "$APP_BUILD_DIRECTORY" "$INSTALLER_BUILD_DIRECTORY" "$DMG_ROOT"
mkdir -p "$ARTIFACT_DIRECTORY" "$DMG_ROOT"
"$ROOT_DIRECTORY/script/build_app.sh" release "$APP_BUILD_DIRECTORY"
"$ROOT_DIRECTORY/script/build_installer.sh" release "$INSTALLER_BUILD_DIRECTORY" "$HELPER_APP"

COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc --noextattr "$INSTALLER_BUNDLE" "$DMG_ROOT/$DISPLAY_NAME.app"
/usr/bin/hdiutil create -quiet -ov -format UDZO -volname "$DISPLAY_NAME" -srcfolder "$DMG_ROOT" "$DMG_PATH"
COPYFILE_DISABLE=1 /usr/bin/ditto -c -k --keepParent --norsrc --noextattr "$INSTALLER_BUNDLE" "$ZIP_PATH"

if [[ "${CODE_SIGN_IDENTITY:--}" != "-" ]]; then
  codesign --force --timestamp --sign "$CODE_SIGN_IDENTITY" "$DMG_PATH"
  codesign --verify --verbose=2 "$DMG_PATH"
fi

(
  cd "$ARTIFACT_DIRECTORY"
  shasum -a 256 "$(basename "$DMG_PATH")" "$(basename "$ZIP_PATH")" >"$(basename "$CHECKSUM_PATH")"
)

codesign --verify --deep --strict --verbose=2 "$INSTALLER_BUNDLE"
hdiutil verify "$DMG_PATH"
echo "$DMG_PATH"
echo "$ZIP_PATH"
echo "$CHECKSUM_PATH"
