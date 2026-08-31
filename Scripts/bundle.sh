#!/bin/bash
# Build WorktreesUI and assemble it into a double-clickable .app bundle.
#
# Usage: Scripts/bundle.sh [--version 1.2.3] [--universal] [--output dist]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="0.0.0-dev"
OUTPUT="dist"
UNIVERSAL=0
APP_NAME="Worktrees"
# The SwiftPM product is WorktreesUI; the shipped executable is not.
EXECUTABLE_NAME="Worktrees"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --output)  OUTPUT="$2";  shift 2 ;;
    --universal) UNIVERSAL=1; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# A leading "v" is fine in a git tag but not in CFBundleVersion.
VERSION="${VERSION#v}"

echo "==> Building WorktreesUI ${VERSION}"
if [[ "$UNIVERSAL" == "1" ]]; then
  # Built one slice per arch and lipo'd together rather than
  # `swift build --arch arm64 --arch x86_64`, which routes through xcbuild and
  # needs a full Xcode install rather than just the command line tools.
  for arch in arm64 x86_64; do
    swift build -c release --product WorktreesUI --triple "${arch}-apple-macosx14.0"
    swift build -c release --product worktrees-cleanup --triple "${arch}-apple-macosx14.0"
  done
  mkdir -p "$OUTPUT"
  BINARY="$OUTPUT/WorktreesUI-universal"
  TOOL="$OUTPUT/worktrees-cleanup-universal"
  lipo -create -output "$BINARY" \
    ".build/arm64-apple-macosx/release/WorktreesUI" \
    ".build/x86_64-apple-macosx/release/WorktreesUI"
  lipo -create -output "$TOOL" \
    ".build/arm64-apple-macosx/release/worktrees-cleanup" \
    ".build/x86_64-apple-macosx/release/worktrees-cleanup"
else
  swift build -c release --product WorktreesUI
  swift build -c release --product worktrees-cleanup
  BIN_PATH="$(swift build -c release --product WorktreesUI --show-bin-path)"
  BINARY="$BIN_PATH/WorktreesUI"
  TOOL="$BIN_PATH/worktrees-cleanup"
fi
[[ -f "$BINARY" ]] || { echo "No binary at $BINARY" >&2; exit 1; }
[[ -f "$TOOL" ]] || { echo "No cleanup tool at $TOOL" >&2; exit 1; }

APP="$OUTPUT/$APP_NAME.app"
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BINARY" "$APP/Contents/MacOS/$EXECUTABLE_NAME"
# Beside the app's own executable, because the LaunchAgent the app installs points
# straight at this path: moving or deleting the app then leaves a job that visibly
# does nothing rather than one quietly running a stale build.
cp "$TOOL" "$APP/Contents/MacOS/worktrees-cleanup"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__EXECUTABLE__/$EXECUTABLE_NAME/g" \
  Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
printf 'APPL????' > "$APP/Contents/PkgInfo"

if "$ROOT/Scripts/make-icon.sh" "$APP/Contents/Resources/AppIcon.icns"; then
  echo "==> Icon generated"
else
  echo "==> Skipping icon (generation failed)" >&2
fi

# Ad-hoc signature. Without it macOS refuses to launch an arm64 binary that has
# been moved or unzipped, which is exactly what a release download is.
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "==> codesign unavailable, continuing" >&2

echo "==> Built $APP"
