#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/../.."
xcodegen generate
xcodebuild \
  -scheme BetterStreaming \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath DerivedData \
  build
