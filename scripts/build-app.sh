#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
app_dir="$project_dir/dist/TokenMeter.app"

cd "$project_dir"
# Keep compiler modules inside the project so the build does not depend on a
# user-level cache that may be unavailable in a restricted shell.
export CLANG_MODULE_CACHE_PATH="$project_dir/.build/clang-module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
swift build --disable-sandbox -c release

mkdir -p "$app_dir/Contents/MacOS"
cp "App/Info.plist" "$app_dir/Contents/Info.plist"
cp ".build/release/TokenMeter" "$app_dir/Contents/MacOS/TokenMeter"
# `swift build` ad-hoc-signs the executable. Once it is copied into the app
# bundle, sign the final bundle again so macOS can launch it as an application.
codesign --force --sign - "$app_dir"

echo "Created: $app_dir"
