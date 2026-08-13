#!/bin/sh
set -eu

repo="DailyXplorer/Usage-Bar"
asset="UsageBar.app.zip"
url="https://github.com/${repo}/releases/latest/download/${asset}"
install_path="/Applications/UsageBar.app"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

printf 'Downloading Usage Bar from GitHub…\n'
if ! curl -fL --progress-bar "$url" -o "$tmp/$asset"; then
  printf 'Could not download %s.\nPublish a GitHub release with that asset first.\n' "$url" >&2
  exit 1
fi

ditto -x -k "$tmp/$asset" "$tmp/extracted"
app=$(find "$tmp/extracted" -name '*.app' -maxdepth 3 -print | awk 'NR==1 { print; exit }')
if [ -z "$app" ]; then
  printf 'The release zip did not contain UsageBar.app.\n' >&2
  exit 1
fi

rm -rf "$install_path"
ditto "$app" "$install_path"
xattr -cr "$install_path"

printf 'Installed to %s\n' "$install_path"
open "$install_path"
