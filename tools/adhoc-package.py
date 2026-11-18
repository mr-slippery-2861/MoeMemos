"""Prepare an isolated personal signing configuration and verify every IPA target."""
import datetime
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys


def plist(path):
    return plistlib.loads(Path(path).read_bytes())


def cms(path):
    return plistlib.loads(subprocess.check_output(["security", "cms", "-D", "-i", str(path)]))


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def check_profile(profile, identifier, team, certificate, devices, group):
    entitlements = profile["Entitlements"]
    require(
        profile["TeamIdentifier"] == [team]
        and entitlements.get("application-identifier") == f"{team}.{identifier}"
        and entitlements.get("get-task-allow") is False
        and devices.issubset({value.upper() for value in profile.get("ProvisionedDevices", [])})
        and certificate in profile["DeveloperCertificates"]
        and group in entitlements.get("com.apple.security.application-groups", [])
        and profile["ExpirationDate"].replace(tzinfo=datetime.timezone.utc)
        > datetime.datetime.now(datetime.timezone.utc),
        f"Profile for {identifier} does not match the team, certificate, shared container or requested devices. "
        "Attach the App Group in Apple Developer, then regenerate the profile.",
    )


mode, stage, team, prefix, certificate_path, build = sys.argv[1:]
stage = Path(stage)
group = f"group.{prefix}"
certificate = Path(certificate_path).read_bytes()
devices = set((stage / "requested-udids.txt").read_text().splitlines())
identifiers = [prefix, f"{prefix}.share", f"{prefix}.widgets"]
profiles = {}
for identifier in identifiers:
    path = stage / f"{identifier}.mobileprovision"
    profile = cms(path)
    check_profile(profile, identifier, team, certificate, devices, group)
    profiles[identifier] = profile["UUID"]
require(
    "suggestions" in cms(stage / f"{prefix}.mobileprovision")["Entitlements"].get("com.apple.developer.journal.allow", []),
    "Enable Journaling Suggestions for the main App ID in Apple Developer, then regenerate the profile.",
)

if mode == "prepare":
    source = stage / "source"
    project = source / "MoeMemos.xcodeproj/project.pbxproj"
    content = project.read_text()
    original = "me.mudkip.MoeMemos"
    mapping = {original: prefix, f"{original}.MoeMemosShareExtension": f"{prefix}.share",
               f"{original}.MoeMemosWidgets": f"{prefix}.widgets"}
    for old, new in mapping.items():
        expression = rf"PRODUCT_BUNDLE_IDENTIFIER = {re.escape(old)};"
        content, count = re.subn(expression, f'PRODUCT_BUNDLE_IDENTIFIER = {new};\n\t\t\t\tPROVISIONING_PROFILE_SPECIFIER = "{profiles[new]}";', content)
        require(count == 2, f"Expected two build configurations for {old}, found {count}.")
    project.write_text(content)
    for path in source.rglob("*.entitlements"):
        content = path.read_text().replace(f"group.{original}", group).replace(f"$(AppIdentifierPrefix){original}", f"$(AppIdentifierPrefix){prefix}")
        path.write_text(content)
    path = source / "Packages/Models/Sources/Models/SharedStorageConfiguration.swift"
    path.write_text(path.read_text().replace(f"group.{original}", group).replace(f"AHAQ4D2466.{original}", f"{team}.{prefix}"))
    target = Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"
    target.mkdir(parents=True, exist_ok=True)
    for identifier, uuid in profiles.items():
        shutil.copyfile(stage / f"{identifier}.mobileprovision", target / f"{uuid}.mobileprovision")
    with (stage / "ExportOptions.plist").open("wb") as output:
        plistlib.dump({"destination": "export", "method": "release-testing", "manageAppVersionAndBuildNumber": False,
                      "signingStyle": "manual", "signingCertificate": subprocess.check_output(["shasum", "-a", "1", certificate_path], text=True).split()[0].upper(),
                      "provisioningProfiles": profiles, "teamID": team, "thinning": "<none>"}, output)
elif mode == "verify":
    apps = list((stage / "verify/Payload").glob("*.app"))
    require(len(apps) == 1, "Expected one exported app.")
    app = apps[0]
    targets = [app, *sorted((app / "PlugIns").glob("*.appex"))]
    require(len(targets) == 3, "Expected the app, share extension and widgets.")
    found = set()
    for target in targets:
        subprocess.run(["codesign", "--verify", "--strict", str(target)], check=True)
        info = plist(target / "Info.plist")
        identifier = info["CFBundleIdentifier"]
        require(identifier in identifiers and identifier not in found, "Unexpected or duplicate exported bundle identifier.")
        found.add(identifier)
        require(info["CFBundleVersion"] == build, f"Incorrect build number for {identifier}.")
        profile = cms(target / "embedded.mobileprovision")
        check_profile(profile, identifier, team, certificate, devices, group)
        require(profile["UUID"] == profiles[identifier], f"Unexpected signing profile for {identifier}.")
        entitlements = plistlib.loads(subprocess.check_output(["codesign", "-d", "--xml", "--entitlements", "-", str(target)], stderr=subprocess.DEVNULL))
        require(entitlements.get("application-identifier") == f"{team}.{identifier}"
                and not entitlements.get("get-task-allow", False)
                and group in entitlements.get("com.apple.security.application-groups", [])
                and f"{team}.{prefix}" in entitlements.get("keychain-access-groups", []),
                f"Incorrect signed entitlements for {identifier}.")
        if identifier == prefix:
            require("suggestions" in entitlements.get("com.apple.developer.journal.allow", []), "Journaling Suggestions missing from signed app.")
    version = plist(app / "Info.plist")["CFBundleShortVersionString"]
    require(re.fullmatch(r"\d+(?:\.\d+){0,2}", version), "Unsupported app version.")
    print(version)
else:
    raise SystemExit("Expected prepare or verify.")
