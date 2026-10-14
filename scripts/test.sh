#!/bin/bash
# Builds and runs the swift-testing suite (see Package.swift for why it is an executable).
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/toolchain.sh
swift build --product RFBTests
# newer Command Line Tools link Testing against lib_TestingInterop, which an older macOS does not carry
interop=$(find /Library/Developer/CommandLineTools /Applications/Xcode*.app/Contents/Developer/Toolchains -name lib_TestingInterop.dylib -path '*macosx*' -print -quit 2>/dev/null || true)
DYLD_FRAMEWORK_PATH=/Library/Developer/CommandLineTools/Library/Developer/Frameworks DYLD_LIBRARY_PATH="${interop:+$(dirname "$interop")}" .build/debug/RFBTests "$@"
