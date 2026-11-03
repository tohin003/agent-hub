#!/bin/bash
# Builds libopus (BSD licence, https://opus-codec.org) as Vendor/Opus/Opus.xcframework: static frameworks for iPhones
# (arm64), the iOS Simulator and Macs (each arm64 + x86_64, since a generic Simulator build and the hub's Release
# build link both), each with libopus's headers, a small header that lets Swift call its variadic ctl functions, and a
# module map, so both apps can `import Opus`. The release is pinned and its SHA-256 checked against the value below
# and against Xiph's published list. libopus's COPYING goes next to the framework.
#
#   scripts/build-libopus.sh [--jobs 2]
#
# Needs only Xcode's command line tools (the release tarball ships a ready configure script). Run it through the
# build lock on a shared Mac: it compiles five times.
set -euo pipefail

VERSION="1.6.1"
SHA256="6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1"
URL="https://downloads.xiph.org/releases/opus/opus-$VERSION.tar.gz"
SUMS_URL="https://downloads.xiph.org/releases/opus/SHA256SUMS.txt"
MIN_OS="26.0"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Vendor/Opus"
jobs=2

say() { printf 'build-libopus.sh: %s\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --jobs) jobs="${2:-2}"; shift ;;
    -h|--help) /usr/bin/awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
    *) say "unknown option: $1"; exit 64 ;;
  esac
  shift
done

export DEVELOPER_DIR="${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p)}"
WORK="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/libopus.XXXXXX")"
trap '/bin/rm -rf "$WORK"' EXIT

# 1. The release, checked.
say "downloading opus-$VERSION"
/usr/bin/curl -fsSL --retry 3 -o "$WORK/opus.tar.gz" "$URL"
actual="$(/usr/bin/shasum -a 256 "$WORK/opus.tar.gz" | /usr/bin/awk '{ print $1 }')"
if [ "$actual" != "$SHA256" ]; then
  say "checksum mismatch: expected $SHA256, got $actual"
  exit 1
fi
published="$(/usr/bin/curl -fsSL --retry 3 "$SUMS_URL" 2>/dev/null \
  | /usr/bin/awk -v file="opus-$VERSION.tar.gz" '$2 == file { print $1 }' || true)"
if [ -n "$published" ]; then
  if [ "$published" != "$SHA256" ]; then
    say "Xiph's published checksum ($published) differs from the pinned one"
    exit 1
  fi
  say "SHA-256 matches the pinned value and Xiph's published SHA256SUMS.txt"
else
  say "couldn't read Xiph's SHA256SUMS.txt; checked against the pinned SHA-256 only"
fi
/bin/mkdir -p "$WORK/src"
/usr/bin/tar -xzf "$WORK/opus.tar.gz" -C "$WORK/src"
SRC="$WORK/src/opus-$VERSION"

# 2. One static library per platform and architecture. --build differs from --host so configure never tries to run
#    what it compiles.
build_slice() {
  local name="$1" sdk="$2" target="$3" host="$4"
  local sysroot cc dir
  sysroot="$(/usr/bin/xcrun --sdk "$sdk" --show-sdk-path)"
  cc="$(/usr/bin/xcrun --sdk "$sdk" -f clang) -target $target -isysroot $sysroot"
  dir="$WORK/build-$name"
  /bin/mkdir -p "$dir"
  say "building $name ($target)"
  (
    cd "$dir"
    "$SRC/configure" --build=arm64-apple-darwin --host="$host" --prefix="$WORK/install-$name" \
      --enable-static --disable-shared --disable-doc --disable-extra-programs \
      CC="$cc" CFLAGS="-O2 -g0" >configure.log 2>&1 || { /usr/bin/tail -40 configure.log; exit 1; }
    /usr/bin/make -j"$jobs" >make.log 2>&1 || { /usr/bin/tail -40 make.log; exit 1; }
    /usr/bin/make install >install.log 2>&1 || { /usr/bin/tail -40 install.log; exit 1; }
  )
}

build_slice ios iphoneos "arm64-apple-ios$MIN_OS" aarch64-apple-darwin
build_slice ios-simulator-arm64 iphonesimulator "arm64-apple-ios$MIN_OS-simulator" aarch64-apple-darwin
build_slice ios-simulator-x86_64 iphonesimulator "x86_64-apple-ios$MIN_OS-simulator" x86_64-apple-darwin
build_slice macos-arm64 macosx "arm64-apple-macos$MIN_OS" aarch64-apple-darwin
build_slice macos-x86_64 macosx "x86_64-apple-macos$MIN_OS" x86_64-apple-darwin
/bin/mkdir -p "$WORK/lib"
/bin/cp "$WORK/install-ios/lib/libopus.a" "$WORK/lib/ios.a"
/usr/bin/xcrun lipo -create "$WORK/install-ios-simulator-arm64/lib/libopus.a" \
  "$WORK/install-ios-simulator-x86_64/lib/libopus.a" -output "$WORK/lib/ios-simulator.a"
/usr/bin/xcrun lipo -create "$WORK/install-macos-arm64/lib/libopus.a" "$WORK/install-macos-x86_64/lib/libopus.a" \
  -output "$WORK/lib/macos.a"

# 3. Each library as a static framework with its headers and module map.
write_headers() {
  local headers="$1"
  /bin/cp "$WORK/install-ios"/include/opus/*.h "$headers/"
  /bin/cat >"$headers/opus_swift.h" <<'EOF'
// Swift can't call C's variadic functions, so libopus's opus_encoder_ctl and opus_decoder_ctl get one wrapper per
// argument shape. Written for Agent Hub (Apache License 2.0); not part of libopus.
#ifndef OPUS_SWIFT_H
#define OPUS_SWIFT_H
#include "opus.h"

static inline int opus_swift_encoder_set(OpusEncoder *encoder, int request, opus_int32 value) {
    return opus_encoder_ctl(encoder, request, value);
}

static inline int opus_swift_encoder_get(OpusEncoder *encoder, int request, opus_int32 *value) {
    return opus_encoder_ctl(encoder, request, value);
}

static inline int opus_swift_encoder_reset(OpusEncoder *encoder) {
    return opus_encoder_ctl(encoder, OPUS_RESET_STATE);
}

static inline int opus_swift_decoder_set(OpusDecoder *decoder, int request, opus_int32 value) {
    return opus_decoder_ctl(decoder, request, value);
}

static inline int opus_swift_decoder_get(OpusDecoder *decoder, int request, opus_int32 *value) {
    return opus_decoder_ctl(decoder, request, value);
}

static inline int opus_swift_decoder_reset(OpusDecoder *decoder) {
    return opus_decoder_ctl(decoder, OPUS_RESET_STATE);
}
#endif
EOF
  # Not "Opus.h": on a case-insensitive disk that would be opus.h itself.
  local umbrella
  umbrella="$(
    echo '// Umbrella header for the Opus module.'
    for header in "$headers"/opus*.h; do echo "#include \"$(/usr/bin/basename "$header")\""; done
  )"
  printf '%s\n' "$umbrella" >"$headers/OpusModule.h"
}

write_plist() {
  local path="$1" platform="$2"
  local minimum=""
  if [ "$platform" = ios ]; then minimum="
  <key>MinimumOSVersion</key><string>$MIN_OS</string>"; fi
  /bin/cat >"$path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>Opus</string>
  <key>CFBundleIdentifier</key><string>org.opus-codec.Opus</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Opus</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>$minimum
</dict>
</plist>
EOF
}

module_map() {
  /bin/cat >"$1" <<'EOF'
framework module Opus {
    umbrella header "OpusModule.h"
    export *
    module * { export * }
}
EOF
}

make_framework() {
  local name="$1" platform="$2"
  local framework="$WORK/frameworks/$name/Opus.framework"
  if [ "$platform" = macos ]; then
    # Mac frameworks use the versioned layout.
    local version="$framework/Versions/A"
    /bin/mkdir -p "$version/Headers" "$version/Modules" "$version/Resources"
    /bin/cp "$WORK/lib/$name.a" "$version/Opus"
    write_headers "$version/Headers"
    module_map "$version/Modules/module.modulemap"
    write_plist "$version/Resources/Info.plist" macos
    /bin/ln -s A "$framework/Versions/Current"
    for item in Opus Headers Modules Resources; do /bin/ln -s "Versions/Current/$item" "$framework/$item"; done
  else
    /bin/mkdir -p "$framework/Headers" "$framework/Modules"
    /bin/cp "$WORK/lib/$name.a" "$framework/Opus"
    write_headers "$framework/Headers"
    module_map "$framework/Modules/module.modulemap"
    write_plist "$framework/Info.plist" ios
  fi
}

make_framework ios ios
make_framework ios-simulator ios
make_framework macos macos

# 4. The XCFramework, replacing the old one, and libopus's licence.
/usr/bin/xcrun xcodebuild -create-xcframework \
  -framework "$WORK/frameworks/ios/Opus.framework" \
  -framework "$WORK/frameworks/ios-simulator/Opus.framework" \
  -framework "$WORK/frameworks/macos/Opus.framework" \
  -output "$WORK/Opus.xcframework" >/dev/null
/bin/mkdir -p "$OUT"
/bin/rm -rf "$OUT/Opus.xcframework"
/bin/mv "$WORK/Opus.xcframework" "$OUT/Opus.xcframework"
/bin/cp "$SRC/COPYING" "$OUT/COPYING"
printf 'libopus %s\nsha256 %s\nsource %s\n' "$VERSION" "$SHA256" "$URL" >"$OUT/VERSION"
say "wrote $OUT/Opus.xcframework ($(/usr/bin/du -sh "$OUT/Opus.xcframework" | /usr/bin/awk '{ print $1 }'))"
