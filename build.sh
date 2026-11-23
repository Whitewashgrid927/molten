#!/bin/bash
set -euo pipefail
MOLTEN_ROOT="$(cd "$(dirname "$0")" && pwd)"
MOLTEN_BUILD="${MOLTEN_BUILD_DIR:-$MOLTEN_ROOT/.build}"
MOLTEN_OUTPUT="$MOLTEN_BUILD/output.noindex"
MOLTEN_APP="$MOLTEN_OUTPUT/Molten.app"
MOLTEN_SIGNING="${MOLTEN_SIGNING_IDENTITY:--}"
mkdir -p "$MOLTEN_APP/Contents/MacOS" "$MOLTEN_APP/Contents/Resources"
xcrun swiftc -D APP_STORE -swift-version 5 -O -target arm64-apple-macosx26.0 \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -framework AppKit -framework SwiftUI -framework Metal -framework MetalKit -framework QuartzCore -framework MetalFX -framework AVFoundation -framework UniformTypeIdentifiers \
  "$MOLTEN_ROOT"/Sources/*.swift -o "$MOLTEN_APP/Contents/MacOS/Molten"
cp "$MOLTEN_ROOT/Resources/Info.plist" "$MOLTEN_APP/Contents/Info.plist"
cp "$MOLTEN_ROOT"/Resources/*.metal "$MOLTEN_APP/Contents/Resources/"
ditto "$MOLTEN_ROOT/Resources/RiverMaterials" "$MOLTEN_APP/Contents/Resources/RiverMaterials"
ditto "$MOLTEN_ROOT/Resources/GlassEffect" "$MOLTEN_APP/Contents/Resources/GlassEffect"
ditto "$MOLTEN_ROOT/Resources/NativeGlassLandscapes" "$MOLTEN_APP/Contents/Resources/NativeGlassLandscapes"
if [ -f "$MOLTEN_ROOT/Resources/Molten.icns" ]; then
  cp "$MOLTEN_ROOT/Resources/Molten.icns" "$MOLTEN_APP/Contents/Resources/"
fi
cp "$MOLTEN_ROOT/Distribution/PrivacyInfo.xcprivacy" "$MOLTEN_APP/Contents/Resources/PrivacyInfo.xcprivacy"
codesign --force --sign "$MOLTEN_SIGNING" --options runtime --timestamp=none "$MOLTEN_APP"
codesign --verify --deep --strict --verbose=2 "$MOLTEN_APP"
printf 'Built %s\n' "$MOLTEN_APP"
