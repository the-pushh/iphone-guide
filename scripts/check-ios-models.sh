#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
check_dir=$(mktemp -d)
trap 'rm -rf "$check_dir"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun swiftc ios/Orb/ConversationTranscript.swift ios/Orb/MessageContent.swift \
  ios/Tests/TranscriptTests.swift -o "$check_dir/checks"
"$check_dir/checks"
