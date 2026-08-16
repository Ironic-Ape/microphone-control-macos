#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || -z "${NOTARY_PROFILE:-}" ]]; then
  echo "usage: NOTARY_PROFILE=<keychain-profile> $0 <release.dmg>" >&2
  exit 2
fi

ARTIFACT="$1"
xcrun notarytool submit "$ARTIFACT" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$ARTIFACT"
xcrun stapler validate "$ARTIFACT"
