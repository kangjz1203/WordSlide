#!/bin/zsh
# Compile the production selection gesture tracker and run deterministic regressions.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${WORDSLIDE_BUILD_DIR:-$project_dir/.build}"
if [[ $# -gt 0 ]]; then
    print -u2 'Usage: ./scripts/test-selection.sh'
    exit 2
fi
mkdir -p "$build_dir/StandaloneTests" "$build_dir/ModuleCache"
export CLANG_MODULE_CACHE_PATH="$build_dir/ModuleCache"
test_arch="$(uname -m)"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
swiftc -parse-as-library -target "$test_arch-apple-macosx13.0" \
    -sdk "$sdk_path" -module-cache-path "$build_dir/ModuleCache" \
    "$project_dir/Sources/WordSlide/SelectionGesture.swift" \
    "$project_dir/scripts/SelectionTests.swift" \
    -o "$build_dir/StandaloneTests/WordSlideSelectionTests"
exec "$build_dir/StandaloneTests/WordSlideSelectionTests"
