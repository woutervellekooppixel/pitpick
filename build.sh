#!/bin/zsh
# Builds Pitpick.app (Apple Silicon + Intel) with exiftool bundled, and puts a zip in dist/.
# Quick build for this Mac only: ./build.sh quick
set -e
cd "$(dirname "$0")"
APP=build/Pitpick.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" dist

if [[ "$1" == "quick" ]]; then
  swiftc -O -target arm64-apple-macos14 -o "$APP/Contents/MacOS/Pitpick" src/*.swift
else
  swiftc -O -target arm64-apple-macos14 -o build/Pitpick-arm64 src/*.swift
  swiftc -O -target x86_64-apple-macos14 -o build/Pitpick-x86_64 src/*.swift
  lipo -create build/Pitpick-arm64 build/Pitpick-x86_64 -output "$APP/Contents/MacOS/Pitpick"
  rm build/Pitpick-arm64 build/Pitpick-x86_64
fi
cp app/Info.plist "$APP/Contents/"
cp app/AppIcon.icns "$APP/Contents/Resources/"

# Bundle exiftool (Phil Harvey); it runs on the perl that ships with macOS.
# Set EXIFTOOL_DIR if yours is not the Homebrew one.
ET="${EXIFTOOL_DIR:-$(brew --prefix exiftool 2>/dev/null)/libexec}"
if [[ -f "$ET/bin/exiftool" ]]; then
  mkdir -p "$APP/Contents/Resources/exiftool/lib"
  cp "$ET/bin/exiftool" "$APP/Contents/Resources/exiftool/exiftool"
  cp -R "$ET/lib/perl5/Image" "$ET/lib/perl5/File" "$APP/Contents/Resources/exiftool/lib/"
  find "$APP/Contents/Resources/exiftool/lib" -name "*.pod" -delete
else
  echo "exiftool not found at $ET: the app will fall back to an installed exiftool"
fi

codesign --force --deep --sign - "$APP"
rm -f dist/Pitpick.zip
ditto -c -k --keepParent "$APP" dist/Pitpick.zip
echo "Done: $APP and dist/Pitpick.zip ($(du -h dist/Pitpick.zip | cut -f1))"
