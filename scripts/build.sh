#!/bin/zsh
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
output_dir="$(dirname "$project_dir")"
build_dir="${WORDSLIDE_BUILD_DIR:-$project_dir/.build}"
mkdir -p "$build_dir/ModuleCache"
# Direct swiftc also works with Command Line Tools installations that lack SwiftPM's
# SDK PlatformPath metadata; this app has no third-party packages or resources.
swiftc -O -parse-as-library -module-name WordSlide -target arm64-apple-macos13.0 \
    -module-cache-path "$build_dir/ModuleCache" \
    "$project_dir"/Sources/WordSlide/*.swift -o "$build_dir/WordSlide"
# Sign outside cloud-backed Documents folders, which may immediately attach
# Finder metadata that codesign refuses. The ZIP omits that filesystem metadata.
bundle_stage_dir="$(mktemp -d /private/tmp/wordslide-build.XXXXXX)"
trap 'rm -rf "$bundle_stage_dir"' EXIT
staged_app="$bundle_stage_dir/WordSlide.app"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
cp "$build_dir/WordSlide" "$staged_app/Contents/MacOS/WordSlide"
cp "$project_dir/Info.plist" "$staged_app/Contents/Info.plist"
/usr/bin/xattr -cr "$staged_app"
/usr/bin/codesign --force --sign - --identifier local.wordslide.app "$staged_app"
/usr/bin/codesign --verify --strict "$staged_app"
app_dir="$output_dir/WordSlide.app"
/usr/bin/ditto --norsrc --noextattr --noacl "$staged_app" "$app_dir"
/usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$staged_app" "$output_dir/WordSlide-macOS-arm64.zip"
echo "Built: $app_dir"
echo "Packaged: $output_dir/WordSlide-macOS-arm64.zip"
