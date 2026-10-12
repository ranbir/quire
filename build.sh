#!/bin/sh
# Builds Quire.app into ./build. Pass --install to copy it to /Applications
# and link the `quire` command into /usr/local/bin (or ~/bin).
set -e
cd "$(dirname "$0")"

swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Quire

APP=build/Quire.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/SharedSupport/bin"
cp "$BIN" "$APP/Contents/MacOS/Quire"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp README.md "$APP/Contents/Resources/README.md"
cp Resources/Quire.sdef "$APP/Contents/Resources/Quire.sdef"
cp bin/quire "$APP/Contents/SharedSupport/bin/quire"
printf 'APPL????' > "$APP/Contents/PkgInfo"

ICONSET=build/Quire.iconset
swift tools/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Quire.icns"
rm -rf "$ICONSET"

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"

if [ "$1" = "--install" ]; then
    rm -rf /Applications/Quire.app
    cp -R "$APP" /Applications/
    if [ -w /usr/local/bin ]; then DEST=/usr/local/bin; else DEST="$HOME/bin"; mkdir -p "$DEST"; fi
    ln -sf /Applications/Quire.app/Contents/SharedSupport/bin/quire "$DEST/quire"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Quire.app
    echo "Installed /Applications/Quire.app and $DEST/quire"
fi
