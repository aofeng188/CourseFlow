#!/bin/bash
# Produce a device-architecture IPA for signing with the owner's Apple Account.
# This is NOT an OTA / directly installable, provisioned distribution package.
set -euo pipefail

courseflow_root="$(cd "$(dirname "$0")/.." && pwd)"
courseflow_output="${COURSEFLOW_OUTPUT_DIR:-$courseflow_root/dist}"
courseflow_build="${COURSEFLOW_BUILD_DIR:-/tmp/courseflow-trial-device-build}"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode-beta.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
fi

mkdir -p "$courseflow_output"
if [[ ! -f "$courseflow_root/CourseFlow.xcodeproj/project.pbxproj" ]]; then
    python3 "$courseflow_root/Scripts/generate_project.py"
fi
echo "Building CourseFlowTrial for iPhone / iPad (arm64, iOS 26+)..."
if ! xcodebuild -project "$courseflow_root/CourseFlow.xcodeproj" \
    -scheme CourseFlowTrial -configuration Release -sdk iphoneos \
    -destination 'generic/platform=iOS' -derivedDataPath "$courseflow_build" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM= \
    COURSEFLOW_ICLOUD_ENABLED=NO build > "$courseflow_output/trial-build.log" 2>&1; then
    tail -n 70 "$courseflow_output/trial-build.log"
    exit 1
fi

courseflow_app="$courseflow_build/Build/Products/Release-iphoneos/CourseFlowTrial.app"
courseflow_stage="$(mktemp -d /tmp/courseflow-ipa.XXXXXX)"
trap 'rm -rf "$courseflow_stage"' EXIT
mkdir -p "$courseflow_stage/Payload"
/usr/bin/ditto --norsrc --noextattr "$courseflow_app" "$courseflow_stage/Payload/CourseFlowTrial.app"

# Fail packaging when a configuration change accidentally restores paid-team
# capabilities, an extension or a provisioning profile in the trial product.
python3 - "$courseflow_stage/Payload/CourseFlowTrial.app" <<'PY'
from pathlib import Path
import plistlib, subprocess, sys
app = Path(sys.argv[1])
info = plistlib.loads((app/'Info.plist').read_bytes())
assert info['CFBundleDisplayName'] == 'CourseFlow', 'SideStore requires an ASCII display name'
localized = app/'zh-Hans.lproj/InfoPlist.strings'
assert localized.exists() and plistlib.loads(localized.read_bytes()).get('CFBundleDisplayName') == '课序', 'Missing localized home screen name'
assert info['TrialBuild'] is True, 'Missing TrialBuild flag'
assert info['CloudSyncEnabled'] == 'NO', 'Cloud must be disabled'
assert info.get('NSSupportsLiveActivities') is False, 'Trial has no live-activity extension'
assert 'remote-notification' not in info.get('UIBackgroundModes', []), 'Remote push must be disabled'
assert info['CFBundleSupportedPlatforms'] == ['iPhoneOS'], 'An IPA must contain an iPhoneOS binary'
assert info['MinimumOSVersion'] == '26.0', 'Unexpected minimum iOS version'
assert not (app/'PlugIns').exists(), 'Trial must not embed app extensions'
assert not list(app.rglob('embedded.mobileprovision')), 'This artifact must not claim device provisioning'
assert not list(app.rglob('_CodeSignature')), 'Unexpected signed bundle in an unsigned artifact'
binary = app/info['CFBundleExecutable']
arches = subprocess.check_output(['xcrun', 'lipo', '-archs', str(binary)], text=True).strip()
assert arches == 'arm64', f'Unexpected binary architectures: {arches}'
print(f'Verified {info["CFBundleIdentifier"]}, iOS {info["MinimumOSVersion"]}, {arches}, no extensions or provisioning.')
PY

courseflow_ipa="$courseflow_output/CourseFlow-Trial-SideStore-unsigned.ipa"
/usr/bin/ditto -c -k --norsrc --noextattr "$courseflow_stage" "$courseflow_ipa"
python3 - "$courseflow_ipa" "$courseflow_stage/Payload/CourseFlowTrial.app" <<'PY'
from pathlib import Path
from datetime import datetime, timezone
import hashlib, json, plistlib, subprocess, sys, zipfile
ipa, app = map(Path, sys.argv[1:])
info = plistlib.loads((app/'Info.plist').read_bytes())
with zipfile.ZipFile(ipa) as z:
    assert z.testzip() is None, 'Corrupt IPA archive'
    assert 'Payload/CourseFlowTrial.app/Info.plist' in z.namelist(), 'Incorrect IPA root'
checksum = hashlib.sha256(ipa.read_bytes()).hexdigest()
manifest = {
    'artifact': ipa.name,
    'createdAt': datetime.now(timezone.utc).isoformat(),
    'displayName': info['CFBundleDisplayName'],
    'homeScreenName': plistlib.loads((app/'zh-Hans.lproj/InfoPlist.strings').read_bytes())['CFBundleDisplayName'],
    'bundleIdentifier': info['CFBundleIdentifier'],
    'version': info['CFBundleShortVersionString'],
    'build': info['CFBundleVersion'],
    'minimumOSVersion': info['MinimumOSVersion'],
    'platform': 'iPhoneOS', 'architectures': ['arm64'],
    'signingState': 'unsigned-requires-device-provisioning',
    'directlyInstallable': False,
    'signingInstructions': '../docs/INSTALL-IPA.md',
    'disabledFeatures': ['CloudKit sync', 'App Groups', 'Widgets', 'Live Activities', 'Remote push'],
    'sizeBytes': ipa.stat().st_size, 'sha256': checksum,
    'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip()
}
ipa.with_suffix('.manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2)+'\n')
ipa.with_suffix('.sha256').write_text(f'{checksum}  {ipa.name}\n')
print(f'Created: {ipa}\nSHA-256: {checksum}\nStatus: unsigned; sign for your own device before installing.')
PY
cp "$courseflow_root/docs/INSTALL-IPA.md" "$courseflow_output/INSTALL-IPA.md"
