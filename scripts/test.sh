#!/bin/bash
# Builds and runs the swift-testing suite (see Package.swift for why it is an executable).
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/toolchain.sh
swift build --product RFBTests
DYLD_FRAMEWORK_PATH=/Library/Developer/CommandLineTools/Library/Developer/Frameworks .build/debug/RFBTests "$@"
