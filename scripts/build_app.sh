#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

JOBS="${SWIFT_JOBS:-2}"
BUILD_ROOT="$ROOT/build/universal"
X86_SCRATCH="$BUILD_ROOT/x86_64"
ARM_SCRATCH="$BUILD_ROOT/arm64"

build_arch() {
    local arch="$1"
    local scratch="$2"
    local triple="${arch}-apple-macosx12.0"

    swift build \
        -c release \
        --triple "$triple" \
        --scratch-path "$scratch" \
        -j "$JOBS" \
        -Xswiftc -disable-batch-mode

    swift build \
        -c release \
        --triple "$triple" \
        --scratch-path "$scratch" \
        --show-bin-path 2>/dev/null
}

X86_BIN_DIR="$(build_arch x86_64 "$X86_SCRATCH" | tail -n 1)"
ARM_BIN_DIR="$(build_arch arm64 "$ARM_SCRATCH" | tail -n 1)"
X86_BINARY="$X86_BIN_DIR/GmailReaderApp"
ARM_BINARY="$ARM_BIN_DIR/GmailReaderApp"
APP="$ROOT/dist/Gmail Reader.app"

[[ -x "$X86_BINARY" ]] || { echo "Missing x86_64 binary: $X86_BINARY" >&2; exit 1; }
[[ -x "$ARM_BINARY" ]] || { echo "Missing arm64 binary: $ARM_BINARY" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "$X86_BINARY" "$ARM_BINARY" -output "$APP/Contents/MacOS/GmailReaderApp"
lipo "$APP/Contents/MacOS/GmailReaderApp" -verify_arch x86_64 arm64
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/GmailReader.icns" "$APP/Contents/Resources/GmailReader.icns"
chmod 755 "$APP/Contents/MacOS/GmailReaderApp"

xattr -cr "$APP"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "Architectures: $(lipo -archs "$APP/Contents/MacOS/GmailReaderApp")"
echo "Built: $APP"
