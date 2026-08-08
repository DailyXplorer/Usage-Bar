#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app_path="$project_dir/.build/UsageBar.app"
contents_path="$app_path/Contents"
macos_path="$contents_path/MacOS"
resources_path="$contents_path/Resources"

cd "$project_dir"
# Le bundle de ressources généré garde les fichiers supprimés d'une build à
# l'autre, et `ditto` fusionne au lieu de remplacer : sans ce nettoyage, une
# ressource retirée des sources reste embarquée dans le .app.
rm -rf "$(swift build -c release --show-bin-path)/UsageBar_UsageBar.bundle"
swift build -c release
release_path=$(swift build -c release --show-bin-path)

rm -rf "$app_path"
mkdir -p "$macos_path" "$resources_path"
ditto "$release_path/UsageBar" "$macos_path/UsageBar"
ditto "$project_dir/Support/Info.plist" "$contents_path/Info.plist"
ditto "$release_path/UsageBar_UsageBar.bundle" "$resources_path/UsageBar_UsageBar.bundle"
xattr -cr "$app_path"
codesign --force --sign - "$app_path"

printf '%s\n' "$app_path"
