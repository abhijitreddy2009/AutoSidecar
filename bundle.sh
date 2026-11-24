#!/bin/bash
# Builds build/Sidecar Auto.app
#   ./bundle.sh            build for this Mac
#   ./bundle.sh --install  build and copy to /Applications
#   ./bundle.sh --release  universal (Apple Silicon + Intel), ad-hoc signed, zipped for GitHub Releases
set -euo pipefail
cd "$(dirname "$0")"
MODE="${1:-}"

if [[ "$MODE" == "--release" ]]; then
    swift build -c release --arch arm64 --arch x86_64
    BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/SidecarAuto"
    IDENTITY="-" # never ship a personal signing identity
else
    swift build -c release
    BIN=.build/release/SidecarAuto
    # A real identity keeps macOS permissions across rebuilds; falls back to ad-hoc.
    IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')}"
    IDENTITY="${IDENTITY:--}"
fi

APP="build/Sidecar Auto.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/SidecarAuto"
cp Resources/Info.plist "$APP/Contents/Info.plist"
xattr -cr "$APP" # don't carry this Mac's file metadata into the bundle
codesign --force --options runtime --sign "$IDENTITY" "$APP"

case "$MODE" in
--install)
    rm -rf "/Applications/Sidecar Auto.app"
    cp -R "$APP" /Applications/
    echo "Installed /Applications/Sidecar Auto.app"
    ;;
--release)
    VERSION=$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)
    ZIP="build/SidecarAuto-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"
    echo "Built $ZIP"
    ;;
*)
    echo "Built $APP"
    ;;
esac
