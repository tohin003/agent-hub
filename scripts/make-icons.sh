#!/bin/bash
# Renders the app icons (iPhone light/dark/tinted and the Mac sizes) and docs/images/hubble.png from the shared
# Hubble drawing code in Shared/Mascot, so the icon always matches the in-app mascot.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
/bin/mkdir -p "$ROOT/build"
/usr/bin/nice -n 10 /usr/bin/xcrun swiftc -parse-as-library -O "$ROOT"/Shared/Mascot/*.swift "$ROOT"/Shared/Terminal/*.swift "$ROOT"/Shared/Protocol/*.swift "$ROOT/Tools/IconGen/main.swift" \
  -o "$ROOT/build/icongen"
"$ROOT/build/icongen" "$ROOT"
