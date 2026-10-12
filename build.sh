#!/bin/sh
# Builds Quire.app into ./build.
#
#   ./build.sh            app for local use (signed with your Developer ID or
#                         Apple Development identity if present, else ad-hoc)
#   ./build.sh --install  also copy to /Applications and link the `quire` command
#   ./build.sh --release  Developer ID signed, notarized and stapled app + .dmg
#
# --release needs a "Developer ID Application" identity in the keychain and a
# notarytool keychain profile (default name: quire-notary), created with:
#   xcrun notarytool store-credentials quire-notary --apple-id … --team-id …
set -e
cd "$(dirname "$0")"

SIGN_ID="${SIGN_ID:-Developer ID Application: Ranbir Mazumdar (VYG245YAH5)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-quire-notary}"

swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Quire

APP=build/Quire.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/SharedSupport/bin"
cp "$BIN" "$APP/Contents/MacOS/Quire"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp README.md "$APP/Contents/Resources/README.md"
cp Resources/Quire.sdef "$APP/Contents/Resources/Quire.sdef"
cp -R Resources/preview "$APP/Contents/Resources/preview"
cp -R Resources/Licenses "$APP/Contents/Resources/Licenses"
cp bin/quire "$APP/Contents/SharedSupport/bin/quire"
printf 'APPL????' > "$APP/Contents/PkgInfo"

ICONSET=build/Quire.iconset
rm -rf "$ICONSET"
swift tools/make-icon.swift iconset "$ICONSET" serif
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Quire.icns"
rm -rf "$ICONSET"

if [ "$1" = "--release" ]; then
    VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
    echo "Signing with: $SIGN_ID"
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP/Contents/SharedSupport/bin/quire"
    codesign --force --options runtime --timestamp --entitlements Resources/Quire.entitlements --sign "$SIGN_ID" "$APP"
    codesign --verify --strict --verbose=2 "$APP"

    # Disk image with a drag-to-Applications layout
    DMG=build/Quire-$VERSION.dmg
    STAGE=build/dmg
    rm -rf "$STAGE" "$DMG"
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "Quire $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
    rm -rf "$STAGE"
    codesign --force --timestamp --sign "$SIGN_ID" "$DMG"

    echo "Submitting to Apple for notarization (usually a few minutes)…"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler staple "$APP"
    spctl --assess --type open --context context:primary-signature --verbose "$DMG"
    spctl --assess --type execute --verbose "$APP"
    echo "Built $DMG (signed, notarized, stapled)"
    exit 0
fi

# Local builds: sign with a stable identity when one is available so macOS
# remembers Keychain and microphone permissions across rebuilds (ad-hoc
# signatures change every build). LOCAL_SIGN_ID=- forces ad-hoc.
if [ -z "$LOCAL_SIGN_ID" ]; then
    IDS=$(security find-identity -v -p codesigning 2>/dev/null)
    LOCAL_SIGN_ID=$(printf '%s\n' "$IDS" | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)
    [ -n "$LOCAL_SIGN_ID" ] || LOCAL_SIGN_ID=$(printf '%s\n' "$IDS" | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)
fi
if [ -n "$LOCAL_SIGN_ID" ] && [ "$LOCAL_SIGN_ID" != "-" ]; then
    codesign --force --sign "$LOCAL_SIGN_ID" "$APP/Contents/SharedSupport/bin/quire"
    codesign --force --sign "$LOCAL_SIGN_ID" "$APP"
    echo "Signed with: $LOCAL_SIGN_ID"
else
    codesign --force --sign - "$APP" >/dev/null
fi
echo "Built $APP"

if [ "$1" = "--install" ]; then
    rm -rf /Applications/Quire.app
    cp -R "$APP" /Applications/
    if [ -w /usr/local/bin ]; then DEST=/usr/local/bin; else DEST="$HOME/bin"; mkdir -p "$DEST"; fi
    ln -sf /Applications/Quire.app/Contents/SharedSupport/bin/quire "$DEST/quire"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Quire.app
    echo "Installed /Applications/Quire.app and $DEST/quire"
fi
