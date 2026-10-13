#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'HELP'
Usage: ./scripts/build-unsigned-ipa.sh

On macOS with Xcode, build a Release iPhone app and package an UNSIGNED IPA.
No developer certificate or provisioning profile is used by this script.
The output cannot be installed directly: it must be signed and provisioned
for the intended device before installation.

Optional environment variables:
  IOS_DEVICE_DERIVED_DATA  Build directory (default: build/DerivedData-device).
  IOS_UNSIGNED_IPA         Output (default: build/artifacts/LiveWallpaper-unsigned.ipa).
HELP
}

case "${1:-}" in
    '') ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac
if [[ $# -gt 1 ]]; then
    usage >&2
    exit 2
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Building an iPhone IPA requires macOS and Xcode. Use the included GitHub Actions workflow when no Mac is available." >&2
    exit 1
fi
if ! xcodebuild -version >/dev/null 2>&1; then
    echo "A selected full Xcode installation is required." >&2
    exit 1
fi

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
derived_data="${IOS_DEVICE_DERIVED_DATA:-${project_root}/build/DerivedData-device}"
unsigned_ipa="${IOS_UNSIGNED_IPA:-${project_root}/build/artifacts/LiveWallpaper-unsigned.ipa}"
python3 "${project_root}/scripts/verify_project.py"
xcodebuild \
    -project "${project_root}/LiveWallpaper.xcodeproj" \
    -scheme LiveWallpaper \
    -configuration Release \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY= \
    build

app_bundle="${derived_data}/Build/Products/Release-iphoneos/LiveWallpaper.app"
if [[ ! -d "$app_bundle" ]]; then
    echo "Expected device app bundle was not produced: ${app_bundle}" >&2
    exit 1
fi
staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/livewallpaper-ipa.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
mkdir -p "${staging_dir}/Payload" "$(dirname "$unsigned_ipa")"
ditto "$app_bundle" "${staging_dir}/Payload/LiveWallpaper.app"
ditto -c -k --keepParent "${staging_dir}/Payload" "$unsigned_ipa"
echo "Unsigned device IPA: ${unsigned_ipa}"
echo "This IPA requires signing and provisioning before it can be installed on an iPhone."
