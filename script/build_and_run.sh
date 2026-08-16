#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
PRODUCT_NAME="MicrophoneControl"
DISPLAY_NAME="Microphone Control"
ROOT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIRECTORY/dist/$DISPLAY_NAME.app"
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/$PRODUCT_NAME"

pkill -x "$PRODUCT_NAME" >/dev/null 2>&1 || true
"$ROOT_DIRECTORY/script/build_app.sh" debug dist

open_development_app() {
  /usr/bin/open -n "$APP_BUNDLE" --args --development
}

case "$MODE" in
  run)
    open_development_app
    ;;
  --debug|debug)
    lldb -- "$APP_EXECUTABLE" --development
    ;;
  --logs|logs)
    open_development_app
    /usr/bin/log stream --info --style compact --predicate "process == '$PRODUCT_NAME'"
    ;;
  --telemetry|telemetry)
    open_development_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == 'app.microphonecontrol'"
    ;;
  --verify|verify)
    open_development_app
    sleep 1
    pgrep -x "$PRODUCT_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
