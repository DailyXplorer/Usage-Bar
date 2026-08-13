#!/bin/sh
set -eu

PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

repo="DailyXplorer/Usage-Bar"
asset="UsageBar.app.zip"
checksum_asset="${asset}.sha256"
base_url="https://github.com/${repo}/releases/latest/download"
install_path="/Applications/UsageBar.app"
expected_bundle_id="com.usagebar.app"
expected_executable="UsageBar"

tmp=$(mktemp -d)
stage_root=""
keep_stage=0

cleanup() {
  rm -rf "$tmp"
  if [ -n "$stage_root" ] && [ "$keep_stage" -eq 0 ]; then
    rm -rf "$stage_root"
  fi
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

printf 'Downloading Usage Bar from GitHub…\n'
if ! curl \
  --proto '=https' \
  --proto-redir '=https' \
  -fL \
  --progress-bar \
  "$base_url/$asset" \
  -o "$tmp/$asset"; then
  printf 'Could not download %s/%s.\nPublish a GitHub release with that asset first.\n' "$base_url" "$asset" >&2
  exit 1
fi
if ! curl \
  --proto '=https' \
  --proto-redir '=https' \
  -fsSL \
  "$base_url/$checksum_asset" \
  -o "$tmp/$checksum_asset"; then
  printf 'Could not download the release checksum %s.\n' "$checksum_asset" >&2
  exit 1
fi

expected_hash=$(awk 'NR == 1 { print $1 }' "$tmp/$checksum_asset")
case "$expected_hash" in
  *[!0-9a-fA-F]*|'')
    printf 'The release checksum is invalid.\n' >&2
    exit 1
    ;;
esac
if [ "${#expected_hash}" -ne 64 ]; then
  printf 'The release checksum is invalid.\n' >&2
  exit 1
fi
actual_hash=$(/usr/bin/shasum -a 256 "$tmp/$asset" | awk 'NR == 1 { print $1 }')
if [ "$actual_hash" != "$expected_hash" ]; then
  printf 'The downloaded archive did not match its release checksum.\n' >&2
  exit 1
fi

ditto -x -k "$tmp/$asset" "$tmp/extracted"
app="$tmp/extracted/UsageBar.app"
if [ ! -d "$app" ] || [ -L "$app" ]; then
  printf 'The release zip did not contain UsageBar.app at its root.\n' >&2
  exit 1
fi

info_plist="$app/Contents/Info.plist"
bundle_id=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$info_plist" 2>/dev/null || true)
executable=$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$info_plist" 2>/dev/null || true)
if [ "$bundle_id" != "$expected_bundle_id" ] || [ "$executable" != "$expected_executable" ]; then
  printf 'The release zip did not contain a valid Usage Bar bundle.\n' >&2
  exit 1
fi
if ! /usr/bin/codesign --verify --deep --strict "$app" >/dev/null 2>&1; then
  printf 'The Usage Bar code signature is invalid.\n' >&2
  exit 1
fi

stage_root=$(mktemp -d "/Applications/.UsageBar-install.XXXXXX")
staged_app="$stage_root/UsageBar.app"
ditto "$app" "$staged_app"
if ! /usr/bin/codesign --verify --deep --strict "$staged_app" >/dev/null 2>&1; then
  printf 'The staged Usage Bar code signature is invalid.\n' >&2
  exit 1
fi

if /usr/bin/pgrep -x UsageBar >/dev/null 2>&1; then
  /usr/bin/osascript -e 'tell application id "com.usagebar.app" to quit' >/dev/null 2>&1 || true
fi
attempt=0
while /usr/bin/pgrep -x UsageBar >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 50 ]; then
    printf 'Usage Bar is still running. Quit it, then run the installer again.\n' >&2
    exit 1
  fi
  /bin/sleep 0.1
done

backup_app="$stage_root/Previous.app"
if [ -e "$install_path" ] || [ -L "$install_path" ]; then
  mv "$install_path" "$backup_app"
fi
if ! mv "$staged_app" "$install_path"; then
  restored=0
  if [ -e "$backup_app" ] || [ -L "$backup_app" ]; then
    if ! mv "$backup_app" "$install_path"; then
      keep_stage=1
      printf 'Installation failed and the previous app is preserved at %s.\n' "$backup_app" >&2
      exit 1
    fi
    restored=1
  fi
  if [ "$restored" -eq 1 ]; then
    printf 'Installation failed; the previous app was restored.\n' >&2
  else
    printf 'Installation failed before Usage Bar was installed.\n' >&2
  fi
  exit 1
fi
rm -rf "$backup_app"

printf 'Installed to %s\n' "$install_path"
open "$install_path"
