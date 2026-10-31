#!/bin/bash
# Builds Hush.app without Xcode. Only Command Line Tools are needed: xcode-select --install
#   ./build.sh            build into build/Hush.app
#   ./build.sh install    build, copy to /Applications and launch
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Hush.app"

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "Compiling..."
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13.0" Sources/*.swift -o "$APP/Contents/MacOS/Hush"
codesign --force --sign - "$APP"
echo "Built: $APP"

if [[ "${1:-}" == "install" ]]; then
  pkill -x Hush 2>/dev/null || true
  # Wait for the old instance to exit, otherwise `open` targets the dying process (error -600).
  while pgrep -x Hush >/dev/null; do sleep 0.1; done
  rm -rf /Applications/Hush.app
  cp -R "$APP" /Applications/
  open /Applications/Hush.app
  echo "Installed to /Applications and launched"
fi
