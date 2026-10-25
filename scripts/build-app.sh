#!/bin/bash
# Builds Mela Importer.app from the Swift package and signs it.
#
#   scripts/build-app.sh                 # ad-hoc signature, app in ./build
#   SIGN_ID="Developer ID Application: …" scripts/build-app.sh
#   INSTALL=1 scripts/build-app.sh       # also copies it to ~/Applications
#
# Runs on macOS 26 with Xcode 26 (or its command-line tools).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product MelaImporter
BIN="$(swift build -c release --product MelaImporter --show-bin-path)/MelaImporter"

APP="build/Mela Importer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MelaImporter"
cp App/Support/Info.plist "$APP/Contents/Info.plist"

# App Sandbox stays off: the app launches the claude and codex CLIs with your login.
codesign --force --options runtime --timestamp=none --sign "${SIGN_ID:--}" "$APP"
echo "Built $APP"

if [[ "${INSTALL:-0}" == "1" ]]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Mela Importer.app"
  cp -R "$APP" "$HOME/Applications/"
  echo "Installed to ~/Applications/Mela Importer.app"
fi
