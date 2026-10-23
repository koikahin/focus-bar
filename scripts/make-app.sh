#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h}
app_path="$project_root/FocusBar.app"

cd "$project_root"
swift build -c release

rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS"
cp "App/Info.plist" "$app_path/Contents/Info.plist"
cp ".build/release/FocusBar" "$app_path/Contents/MacOS/FocusBar"

# Sign the whole bundle: the linker's binary-only signature does not bind
# Info.plist and macOS rejects notification authorization for that build.
codesign --force --sign - --identifier com.local.focusbar \
    --requirements '=designated => identifier "com.local.focusbar"' "$app_path"
codesign --verify --strict "$app_path"

echo "Created $app_path"
