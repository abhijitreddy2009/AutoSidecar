#!/bin/bash
# Builds build/AutoSidecar.app
#   ./bundle.sh            build for this Mac
#   ./bundle.sh --install  build and copy to /Applications
#   ./bundle.sh --release  universal (Apple Silicon + Intel), zipped for GitHub Releases.
#                          With a "Developer ID Application" certificate in the keychain it is signed,
#                          notarized and stapled; otherwise it falls back to an ad-hoc signature.
#
# Notarization reads credentials stored once with:
#   xcrun notarytool store-credentials AutoSidecar --apple-id <apple-id> --team-id <team-id>
# Override with DEVELOPER_ID="Developer ID Application: …" and NOTARY_PROFILE=<name>.
set -euo pipefail
cd "$(dirname "$0")"
MODE="${1:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-AutoSidecar}"

if [[ "$MODE" == "--release" ]]; then
    swift build -c release --arch arm64 --arch x86_64
    BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/AutoSidecar"
    # Only Developer ID or ad-hoc: an "Apple Development" certificate embeds a personal email.
    IDENTITY="${DEVELOPER_ID:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
    IDENTITY="${IDENTITY:--}"
else
    swift build -c release
    BIN=.build/release/AutoSidecar
    # A real identity keeps macOS permissions across rebuilds; falls back to ad-hoc.
    IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')}"
    IDENTITY="${IDENTITY:--}"
fi

APP="build/AutoSidecar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AutoSidecar"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/Info.plist "$APP/Contents/Info.plist"
xattr -cr "$APP" # don't carry this Mac's file metadata into the bundle
if [[ "$IDENTITY" == "-" ]]; then
    codesign --force --options runtime --sign - "$APP"
else
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"

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
    if [[ "$IDENTITY" == "-" ]]; then
        echo "warning: no Developer ID certificate found; $ZIP is ad-hoc signed (users must right-click → Open)" >&2
    else
        echo "Signed with: $IDENTITY"
        xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$APP"
        rm -f "$ZIP"
        ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP" # re-zip with the stapled ticket
        spctl --assess --type execute --verbose=2 "$APP"
    fi
    shasum -a 256 "$ZIP"
    ;;
*)
    echo "Built $APP"
    ;;
esac
