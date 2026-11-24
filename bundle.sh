#!/bin/bash
# Builds build/AutoSidecar.app (ad-hoc signed).
#   ./bundle.sh            build for this Mac
#   ./bundle.sh --install  build and copy to /Applications
#   ./bundle.sh --release  universal (Apple Silicon + Intel), zipped for GitHub Releases
set -euo pipefail
cd "$(dirname "$0")"
MODE="${1:-}"

if [[ "$MODE" == "--release" ]]; then
    swift build -c release --arch arm64 --arch x86_64
    BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/AutoSidecar"
else
    swift build -c release
    BIN=.build/release/AutoSidecar
fi

APP="build/AutoSidecar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AutoSidecar"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/Info.plist "$APP/Contents/Info.plist"
xattr -cr "$APP" # don't carry this Mac's file metadata into the bundle
codesign --force --options runtime --sign - "$APP"

case "$MODE" in
--install)
    rm -rf "/Applications/AutoSidecar.app"
    cp -R "$APP" /Applications/
    echo "Installed /Applications/AutoSidecar.app"
    ;;
--release)
    VERSION=$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)
    ZIP="build/AutoSidecar-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"
    shasum -a 256 "$ZIP"
    ;;
*)
    echo "Built $APP"
    ;;
esac
