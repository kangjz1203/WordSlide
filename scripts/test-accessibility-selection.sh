#!/bin/zsh
# Offline tests of selection extraction; does not inspect any other App or need AX permission.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${WORDSLIDE_BUILD_DIR:-$project_dir/.build}"
mkdir -p "$build_dir/AccessibilitySelectionTests" "$build_dir/ModuleCache"
export CLANG_MODULE_CACHE_PATH="$build_dir/ModuleCache"
test_arch="$(uname -m)"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
swiftc -parse-as-library -target "$test_arch-apple-macosx13.0" \
    -sdk "$sdk_path" -module-cache-path "$build_dir/ModuleCache" \
    "$project_dir/Sources/WordSlide/AccessibilitySelectedText.swift" \
    "$project_dir/scripts/AccessibilitySelectionTests.swift" \
    -o "$build_dir/AccessibilitySelectionTests/WordSlideAccessibilitySelectionTests"
exec "$build_dir/AccessibilitySelectionTests/WordSlideAccessibilitySelectionTests"
