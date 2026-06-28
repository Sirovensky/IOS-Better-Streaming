#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/../.."
if command -v swiftformat >/dev/null 2>&1; then
  swiftformat App Packages
else
  echo "swiftformat not installed; skipping"
fi
