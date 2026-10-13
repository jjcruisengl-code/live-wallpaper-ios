#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'HELP'
Usage: ./scripts/build-ios.sh [--test]

Build the iPhone app for iOS Simulator on macOS with Xcode.
Simulator builds use Xcode local ad hoc signing; no developer account is required.
--test also builds and runs the hosted WallpaperSettings XCTest suite.

Optional environment variables:
  IOS_DERIVED_DATA      Build artifacts directory (default: build/DerivedData).
  IOS_TEST_DESTINATION  xcodebuild destination for tests, e.g.
                        'platform=iOS Simulator,name=iPhone 17 Pro'.
                        By default, selects an iPhone on the latest installed iOS.
  IOS_RESULT_BUNDLE     XCTest result bundle output ending in .xcresult.
                        Default: a new bundle under build/TestResults/.

The script does not install Xcode, simulator runtimes, or signing certificates.
HELP
}

run_tests=false
case "${1:-}" in
    '') ;;
    --test) run_tests=true ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac
if [[ $# -gt 1 ]]; then
    usage >&2
    exit 2
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Xcode builds require macOS. On this system, run python3 scripts/verify_project.py for static checks." >&2
    exit 1
fi
if ! xcodebuild -version >/dev/null 2>&1; then
    echo "A selected full Xcode installation is required. Select it in Xcode > Settings > Locations > Command Line Tools." >&2
    exit 1
fi

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
derived_data="${IOS_DERIVED_DATA:-${project_root}/build/DerivedData}"
python3 "${project_root}/scripts/verify_project.py"
arguments=(
    -project "${project_root}/LiveWallpaper.xcodeproj"
    -scheme LiveWallpaper
    -configuration Debug
    -derivedDataPath "$derived_data"
)

if [[ "$run_tests" == true ]]; then
    test_destination="${IOS_TEST_DESTINATION:-}"
    if [[ -z "$test_destination" ]]; then
        simulator_id="$(xcrun simctl list devices available --json | python3 -c '
import json, re, sys
data = json.load(sys.stdin)
devices = []
for runtime, group in data.get("devices", {}).items():
    match = re.search(r"\.iOS-(\d+(?:-\d+)*)$", runtime)
    if not match:
        continue
    version = tuple(int(part) for part in match.group(1).split("-"))
    for device in group:
        if device.get("isAvailable") and device.get("name", "").startswith("iPhone"):
            score = (version, device.get("state") == "Booted", device["name"] == "iPhone 17 Pro", device["name"])
            devices.append((score, device["udid"]))
if not devices:
    sys.exit("No available iPhone simulator. Add an iOS runtime in Xcode Settings > Components, or set IOS_TEST_DESTINATION.")
print(max(devices)[1])
')"
        test_destination="platform=iOS Simulator,id=${simulator_id}"
    fi
    result_bundle="${IOS_RESULT_BUNDLE:-${project_root}/build/TestResults/LiveWallpaper-$(date +%Y%m%d-%H%M%S)-$$.xcresult}"
    mkdir -p "$(dirname "$result_bundle")"
    echo "Testing on: ${test_destination}"
    echo "XCTest results: ${result_bundle}"
    xcodebuild "${arguments[@]}" -destination "$test_destination" -resultBundlePath "$result_bundle" test
else
    xcodebuild "${arguments[@]}" -destination 'generic/platform=iOS Simulator' build
fi
