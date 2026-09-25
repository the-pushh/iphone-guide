#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
check_dir=$(mktemp -d)
trap 'rm -rf "$check_dir"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun swiftc ios/Orb/OrbVideoBuffer.swift ios/Tests/VideoBufferTests.swift -o "$check_dir/check"
"$check_dir/check"
