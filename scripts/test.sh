#!/bin/zsh
# Run deterministic offline fixtures without requiring the XCTest framework.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${WORDSLIDE_BUILD_DIR:-$project_dir/.build}"
mkdir -p "$build_dir/StandaloneTests" "$build_dir/ModuleCache"
export CLANG_MODULE_CACHE_PATH="$build_dir/ModuleCache"
if [[ "${1:-}" == "--xctest" ]]; then
    # Optional full XCTest suite; requires Xcode with XCTest installed.
    cd "$project_dir"
    exec swift test --disable-sandbox --scratch-path "$build_dir" --cache-path "$build_dir/cache" --config-path "$build_dir/config" --security-path "$build_dir/security"
fi
if [[ $# -gt 0 ]]; then
    print -u2 'Usage: ./scripts/test.sh [--xctest]'
    exit 2
fi
test_arch="$(uname -m)"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
swiftc -parse-as-library -target "$test_arch-apple-macosx13.0" \
    -sdk "$sdk_path" -module-cache-path "$build_dir/ModuleCache" \
    "$project_dir/Sources/WordSlide/Models.swift" \
    "$project_dir/Sources/WordSlide/DictionaryService.swift" \
    "$project_dir/scripts/SmokeTests.swift" \
    -o "$build_dir/StandaloneTests/WordSlideFixtures"
exec "$build_dir/StandaloneTests/WordSlideFixtures"
