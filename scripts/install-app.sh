#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h}
install_dir="${HOME}/Applications"
installed_app="$install_dir/FocusBar.app"

zsh "$project_root/scripts/make-app.sh"
"$project_root/.build/release/FocusBar" --quit-running
mkdir -p "$install_dir"
ditto "$project_root/FocusBar.app" "$installed_app"
open -n "$installed_app"

echo "Installed and launched $installed_app"
