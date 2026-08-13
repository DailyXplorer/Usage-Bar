#!/bin/sh
set -eu

no_install=0
make_zip=0
for arg in "$@"; do
  case "$arg" in
    --no-install) no_install=1 ;;
    --zip) make_zip=1 ;;
    *)
      printf 'unknown argument: %s\n' "$arg" >&2
      exit 2
      ;;
  esac
done

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app_path="$project_dir/.build/UsageBar.app"
contents_path="$app_path/Contents"
macos_path="$contents_path/MacOS"
resources_path="$contents_path/Resources"
install_stage_root=""
keep_install_stage=0

cleanup() {
  if [ -n "$install_stage_root" ] && [ "$keep_install_stage" -eq 0 ]; then
    rm -rf "$install_stage_root"
  fi
}

clear_signing_xattrs() {
  xattr -cr "$1"
  xattr -dr com.apple.FinderInfo "$1" 2>/dev/null || true
  xattr -dr com.apple.ResourceFork "$1" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

if [ "$no_install" -eq 0 ]; then
  if ! install_stage_root=$(mktemp -d "/Applications/.UsageBar-build.XXXXXX" 2>/dev/null); then
    printf 'Usage Bar needs permission to install in /Applications. Run this script from an administrator account.\n' >&2
    exit 1
  fi
fi

cd "$project_dir"
rm -rf "$(swift build -c release --show-bin-path)/UsageBar_UsageBar.bundle"
swift build -c release
release_path=$(swift build -c release --show-bin-path)

rm -rf "$app_path"
mkdir -p "$macos_path" "$resources_path"
ditto "$release_path/UsageBar" "$macos_path/UsageBar"
ditto "$project_dir/Support/Info.plist" "$contents_path/Info.plist"
ditto "$release_path/UsageBar_UsageBar.bundle" "$resources_path/UsageBar_UsageBar.bundle"

version="${USAGEBAR_VERSION:-}"
version="${version#v}"
if [ -z "$version" ]; then
  if tag=$(git -C "$project_dir" describe --tags --exact-match 2>/dev/null); then
    version=${tag#v}
  fi
fi
if [ -n "$version" ]; then
  plutil -replace CFBundleShortVersionString -string "$version" "$contents_path/Info.plist"
  plutil -replace CFBundleVersion -string "$version" "$contents_path/Info.plist"
fi

clear_signing_xattrs "$app_path"
codesign --force --sign - "$app_path"
codesign --verify --deep --strict "$app_path"

if [ "$no_install" -eq 0 ]; then
  install_path="/Applications/UsageBar.app"
  staged_app="$install_stage_root/UsageBar.app"
  backup_app="$install_stage_root/Previous.app"
  ditto --norsrc --noextattr "$app_path" "$staged_app"
  clear_signing_xattrs "$staged_app"
  if ! codesign --verify --deep --strict "$staged_app" >/dev/null 2>&1; then
    printf 'The staged Usage Bar code signature is invalid.\n' >&2
    exit 1
  fi

  if pgrep -x UsageBar >/dev/null 2>&1; then
    osascript -e 'tell application id "com.usagebar.app" to quit' >/dev/null 2>&1 || true
  fi
  attempt=0
  while pgrep -x UsageBar >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 50 ]; then
      printf 'Usage Bar is still running. Quit it, then run the build again.\n' >&2
      exit 1
    fi
    sleep 0.1
  done

  if [ -e "$install_path" ] || [ -L "$install_path" ]; then
    mv "$install_path" "$backup_app"
  fi
  if ! mv "$staged_app" "$install_path"; then
    restored=0
    if [ -e "$backup_app" ] || [ -L "$backup_app" ]; then
      if ! mv "$backup_app" "$install_path"; then
        keep_install_stage=1
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
  printf '%s\n' "$install_path"
else
  printf '%s\n' "$app_path"
fi

if [ "$make_zip" -eq 1 ]; then
  zip_path="$project_dir/.build/UsageBar.app.zip"
  checksum_path="$project_dir/.build/UsageBar.app.zip.sha256"
  rm -f "$zip_path" "$checksum_path"
  clear_signing_xattrs "$app_path"
  codesign --verify --deep --strict "$app_path"
  ditto -c -k --keepParent --norsrc --noextattr "$app_path" "$zip_path"
  (
    cd "$(dirname -- "$zip_path")"
    /usr/bin/shasum -a 256 "$(basename -- "$zip_path")" > "$(basename -- "$checksum_path")"
  )
  clear_signing_xattrs "$app_path"
  codesign --verify --deep --strict "$app_path"
  printf '%s\n' "$zip_path"
  printf '%s\n' "$checksum_path"
fi
