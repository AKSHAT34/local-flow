#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/LocalFlow.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/LocalFlowApp "$APP/Contents/MacOS/LocalFlow"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

SIGN_IDENTITY="LocalFlow Local Signing"
if security find-identity -p codesigning -v 2>/dev/null | grep -q "\"$SIGN_IDENTITY\""; then
    codesign --force --timestamp=none --sign "$SIGN_IDENTITY" --identifier com.localflow.app "$APP"
else
    echo "WARNING: signing identity '$SIGN_IDENTITY' not found — falling back to ad-hoc." >&2
    echo "WARNING: TCC permissions (Accessibility/Microphone) will reset on every rebuild." >&2
    echo "WARNING: run scripts/setup-signing.sh once to fix this." >&2
    codesign --force --sign - "$APP" 2>/dev/null || true
fi

echo "Built $APP"
echo "Run with: open \"$APP\""
