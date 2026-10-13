#!/usr/bin/env python3
"""Validate Xcode project wiring using only Python's standard library.

This is a static consistency check. It cannot compile Swift, validate Apple API
availability, run XCTest, or establish lock-screen Live Photo compatibility.
"""

import json
from pathlib import Path
import plistlib
import re
import sys
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parent.parent
TOKEN = re.compile(
    r'\s+|//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|[{}()=;,]|[^\s{}()=;,]+',
    re.DOTALL,
)
OBJECT_ID = re.compile(r"[0-9A-F]{24}\Z")


def require(condition, message):
    if not condition:
        raise ValueError(message)


class OpenStepParser:
    """Small parser for the dictionaries, arrays and strings in project.pbxproj."""

    def __init__(self, text):
        self.tokens = []
        end = 0
        for match in TOKEN.finditer(text):
            require(match.start() == end, "Unrecognized project.pbxproj token")
            end = match.end()
            token = match.group()
            if not token.isspace() and not token.startswith(("//", "/*")):
                self.tokens.append(token)
        require(end == len(text), "Incomplete project.pbxproj tokenization")
        self.position = 0

    def take(self, expected=None):
        require(self.position < len(self.tokens), "Unexpected end of project.pbxproj")
        result = self.tokens[self.position]
        self.position += 1
        if expected is not None:
            require(result == expected, f"Expected {expected!r}, found {result!r}")
        return result

    def peek(self):
        require(self.position < len(self.tokens), "Unexpected end of project.pbxproj")
        return self.tokens[self.position]

    def parse_value(self):
        token = self.take()
        if token == "{":
            result = {}
            while self.peek() != "}":
                key = self.parse_value()
                require(isinstance(key, str), "Dictionary key must be a string")
                require(key not in result, f"Duplicate project key: {key}")
                self.take("=")
                result[key] = self.parse_value()
                self.take(";")
            self.take("}")
            return result
        if token == "(":
            result = []
            while self.peek() != ")":
                result.append(self.parse_value())
                if self.peek() != ")":
                    self.take(",")
            self.take(")")
            return result
        require(token not in "})=;,", f"Unexpected project token: {token}")
        return json.loads(token) if token.startswith('"') else token

    def parse(self):
        result = self.parse_value()
        require(self.position == len(self.tokens), "Trailing project.pbxproj content")
        return result


def validate_references(value, objects):
    if isinstance(value, dict):
        for child in value.values():
            validate_references(child, objects)
    elif isinstance(value, list):
        for child in value:
            validate_references(child, objects)
    elif isinstance(value, str) and OBJECT_ID.fullmatch(value):
        require(value in objects, f"Dangling Xcode object reference: {value}")


def collect_file_paths(objects, group_id, parent, result, ancestors=()):
    require(group_id not in ancestors, "Cycle in Xcode project groups")
    group = objects[group_id]
    require(group["isa"] == "PBXGroup", f"Expected group: {group_id}")
    folder = parent / group.get("path", "")
    for child_id in group.get("children", []):
        child = objects[child_id]
        if child["isa"] == "PBXGroup":
            collect_file_paths(objects, child_id, folder, result, ancestors + (group_id,))
        elif child["isa"] == "PBXFileReference":
            if child.get("sourceTree") == "BUILT_PRODUCTS_DIR":
                continue
            base = ROOT if child.get("sourceTree") == "SOURCE_ROOT" else folder
            path = base / child["path"]
            require(path.exists(), f"Missing project file: {path.relative_to(ROOT)}")
            result[child_id] = path.resolve()


def configurations(objects, owner):
    config_list = objects[owner["buildConfigurationList"]]
    return {
        objects[key]["name"]: objects[key]["buildSettings"]
        for key in config_list["buildConfigurations"]
    }


def build_paths(objects, target, paths, phase_type):
    result = []
    for phase_id in target["buildPhases"]:
        phase = objects[phase_id]
        if phase["isa"] == phase_type:
            for build_id in phase["files"]:
                build = objects[build_id]
                require(build["isa"] == "PBXBuildFile", "Invalid build phase entry")
                result.append(paths[build["fileRef"]])
    require(len(result) == len(set(result)), f"Duplicate files in {phase_type}")
    return set(result)


def main():
    project_path = ROOT / "LiveWallpaper.xcodeproj/project.pbxproj"
    project = OpenStepParser(project_path.read_text()).parse()
    objects = project["objects"]
    require(all(OBJECT_ID.fullmatch(key) for key in objects), "Invalid Xcode object ID")
    validate_references(project, objects)
    project_object = objects[project["rootObject"]]
    require(project_object["isa"] == "PBXProject", "Invalid root project")

    paths = {}
    collect_file_paths(objects, project_object["mainGroup"], ROOT, paths)
    targets = {objects[key]["name"]: (key, objects[key]) for key in project_object["targets"]}
    require(set(targets) == {"LiveWallpaper", "LiveWallpaperTests"}, "Unexpected project targets")
    app_id, app = targets["LiveWallpaper"]
    test_id, tests = targets["LiveWallpaperTests"]
    require(app["productType"] == "com.apple.product-type.application", "Invalid app target")
    require(tests["productType"] == "com.apple.product-type.bundle.unit-test", "Invalid test target")
    app_sources = build_paths(objects, app, paths, "PBXSourcesBuildPhase")
    test_sources = build_paths(objects, tests, paths, "PBXSourcesBuildPhase")
    require(app_sources == {p.resolve() for p in (ROOT / "LiveWallpaper").rglob("*.swift")}, "App Swift files and Sources phase differ")
    require(test_sources == {p.resolve() for p in (ROOT / "Tests").rglob("*.swift")}, "Test Swift files and Sources phase differ")
    require(len(app_sources) >= 9 and test_sources, "Expected app and test source files")
    app_resources = build_paths(objects, app, paths, "PBXResourcesBuildPhase")
    require(app_resources == {
        (ROOT / "LiveWallpaper/Resources/Assets.xcassets").resolve(),
        (ROOT / "LiveWallpaper/Resources/PrivacyInfo.xcprivacy").resolve(),
    }, "Unexpected app resource build phase")
    require(any(objects[key].get("target") == app_id for key in tests["dependencies"]), "Tests must depend on the app target")

    for settings in configurations(objects, project_object).values():
        require(settings.get("IPHONEOS_DEPLOYMENT_TARGET") == "17.0", "Minimum deployment target must be iOS 17")
        require(settings.get("SWIFT_VERSION") == "5.0", "Expected Swift 5 language mode")
    for settings in configurations(objects, app).values():
        require(settings.get("PRODUCT_BUNDLE_IDENTIFIER") == "com.example.LiveWallpaper", "Unexpected application bundle ID")
        require(settings.get("TARGETED_DEVICE_FAMILY") == "1", "App must target iPhone")
        require(settings.get("CODE_SIGN_STYLE") == "Automatic", "Expected automatic signing")
        require(not settings.get("DEVELOPMENT_TEAM"), "Do not hard-code a signing team")
        require(settings.get("INFOPLIST_FILE") == "LiveWallpaper/Resources/Info.plist", "Incorrect Info.plist path")
        require(settings.get("MARKETING_VERSION") == "0.1.0", "Unexpected app version")

    with (ROOT / "LiveWallpaper/Resources/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    require(info.get("CFBundleDisplayName") == "流光壁纸", "Unexpected display name")
    require(info.get("NSPhotoLibraryAddUsageDescription"), "Photos add-only permission explanation is missing")
    require("NSPhotoLibraryUsageDescription" not in info, "PHPicker import does not require full Photos access")
    require(info.get("UISupportedInterfaceOrientations") == ["UIInterfaceOrientationPortrait"], "App must support portrait only")
    with (ROOT / "LiveWallpaper/Resources/PrivacyInfo.xcprivacy").open("rb") as stream:
        privacy = plistlib.load(stream)
    require(privacy.get("NSPrivacyTracking") is False, "Tracking must be disabled")
    require(privacy.get("NSPrivacyCollectedDataTypes") == [], "Unexpected privacy data collection declaration")
    require(privacy.get("NSPrivacyAccessedAPITypes") == [{
        "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryUserDefaults",
        "NSPrivacyAccessedAPITypeReasons": ["CA92.1"],
    }], "UserDefaults privacy reason must be CA92.1")

    asset_catalog = ROOT / "LiveWallpaper/Resources/Assets.xcassets"
    for contents in asset_catalog.rglob("Contents.json"):
        data = json.loads(contents.read_text())
        require(data.get("info", {}).get("version") == 1, f"Invalid asset catalog: {contents}")

    scheme = ET.parse(ROOT / "LiveWallpaper.xcodeproj/xcshareddata/xcschemes/LiveWallpaper.xcscheme").getroot()
    require(scheme.tag == "Scheme", "Invalid shared Xcode scheme")
    scheme_target_ids = set()
    for reference in scheme.iter("BuildableReference"):
        identifier = reference.attrib["BlueprintIdentifier"]
        require(identifier in (app_id, test_id), "Scheme references an unknown target")
        target = objects[identifier]
        product = objects[target["productReference"]]
        require(reference.attrib["BlueprintName"] == target["name"], "Scheme target name mismatch")
        require(reference.attrib["BuildableName"] == product["path"], "Scheme product name mismatch")
        scheme_target_ids.add(identifier)
    require(scheme_target_ids == {app_id, test_id}, "Shared scheme must include app and tests")
    require(scheme.find("TestAction/Testables/TestableReference") is not None, "Shared scheme lacks a test action")
    for script in ("build-ios.sh", "verify_project.py"):
        require((ROOT / "scripts" / script).is_file(), f"Missing script: {script}")

    print(f"PASS: {len(app_sources)} app sources, {len(test_sources)} test sources, {len(objects)} Xcode objects.")
    print("PASS: shared scheme, build phases, Info.plist, assets and privacy manifest.")
    print("Static project checks passed. This does not compile Swift or run XCTest.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError, ET.ParseError, plistlib.InvalidFileException) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
