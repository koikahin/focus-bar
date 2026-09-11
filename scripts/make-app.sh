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

echo "Created $app_path"
