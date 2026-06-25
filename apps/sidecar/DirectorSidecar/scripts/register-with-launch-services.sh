#!/bin/bash
# Re-register the built .app with Launch Services after each macOS build so the Dock
# and Finder pick up icon / metadata changes without removing and re-adding the app.
set -euo pipefail

if [[ "${PLATFORM_NAME:-}" != "macosx" ]]; then
  exit 0
fi

APP="${TARGET_BUILD_DIR:?}/${WRAPPER_NAME:?}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [[ -d "$APP" ]]; then
  "$LSREGISTER" -f -R -trusted "$APP"
  echo "Registered ${APP} with Launch Services (Dock icon sync)."
fi
