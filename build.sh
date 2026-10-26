#!/bin/bash
set -euo pipefail

# Build a local, ad-hoc-signed app without changing Accessibility permissions.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${WINDOWGROUP_BUILD_DIR:-${TMPDIR:-/tmp}/WindowGroup-build}"
OUTPUT_DIR="${WINDOWGROUP_OUTPUT_DIR:-$(dirname "$SCRIPT_DIR")}"
FIXTURE_OUTPUT_DIR="${WINDOWGROUP_FIXTURE_OUTPUT_DIR:-$BUILD_DIR/fixtures}"
ARCH="$(uname -m)"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "WindowGroup requires macOS and the Xcode command line tools." >&2
    exit 1
fi

mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"
BUILD_DIR="$(cd "$BUILD_DIR" && pwd)"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_DIR/swift-module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"

BUILD_ARGS=(--package-path "$SCRIPT_DIR" --scratch-path "$BUILD_DIR" --configuration release --arch "$ARCH" --disable-sandbox --build-system native --disable-keychain --disable-netrc --cache-path "$BUILD_DIR/cache" --config-path "$BUILD_DIR/config" --security-path "$BUILD_DIR/security" --manifest-cache local)
xcrun swift build "${BUILD_ARGS[@]}" --product WindowGroup
BIN_DIR="$(xcrun swift build "${BUILD_ARGS[@]}" --show-bin-path)"

make_bundle() {
    local executable="$1"
    local identifier="$2"
    local destination="$3"
    local bundle="$destination/$executable.app"
    mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
    cp "$BIN_DIR/$executable" "$bundle/Contents/MacOS/$executable"
    chmod 755 "$bundle/Contents/MacOS/$executable"
    cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>$executable</string>
    <key>CFBundleIdentifier</key><string>$identifier</string>
    <key>CFBundleName</key><string>$executable</string>
    <key>CFBundleDisplayName</key><string>$executable</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2.0</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
    plutil -lint "$bundle/Contents/Info.plist"
    codesign --force --sign "${WINDOWGROUP_SIGN_IDENTITY:--}" --timestamp=none --identifier "$identifier" "$bundle"
    codesign --verify --strict "$bundle"
    echo "Built $bundle"
}

make_bundle WindowGroup dev.dustin.windowgroup "$OUTPUT_DIR"

if [[ "${WINDOWGROUP_BUILD_FIXTURE:-0}" == "1" ]]; then
    mkdir -p "$FIXTURE_OUTPUT_DIR"
    FIXTURE_OUTPUT_DIR="$(cd "$FIXTURE_OUTPUT_DIR" && pwd)"
    xcrun swift build "${BUILD_ARGS[@]}" --product WindowGroupFixture
    make_bundle WindowGroupFixture dev.dustin.windowgroup.fixture "$FIXTURE_OUTPUT_DIR"
fi
