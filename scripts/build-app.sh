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

xattr -cr "$app_path"
codesign --force --sign - "$app_path"

if [ "$no_install" -eq 0 ]; then
  install_path="/Applications/UsageBar.app"
  rm -rf "$install_path"
  ditto "$app_path" "$install_path"
  xattr -cr "$install_path"
  codesign --force --sign - "$install_path"
  printf '%s\n' "$install_path"
else
  printf '%s\n' "$app_path"
fi

if [ "$make_zip" -eq 1 ]; then
  zip_path="$project_dir/.build/UsageBar.app.zip"
  checksum_path="$project_dir/.build/UsageBar.app.zip.sha256"
  rm -f "$zip_path" "$checksum_path"
  ditto -c -k --keepParent "$app_path" "$zip_path"
  (
    cd "$(dirname -- "$zip_path")"
    /usr/bin/shasum -a 256 "$(basename -- "$zip_path")" > "$(basename -- "$checksum_path")"
  )
  printf '%s\n' "$zip_path"
  printf '%s\n' "$checksum_path"
fi
