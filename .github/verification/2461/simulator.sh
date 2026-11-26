#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
xcrun simctl list -j devices available > "$out/devices.json"
xcrun simctl list -j runtimes > "$out/runtimes.json"
udid="$(python3 - "$out/devices.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))['devices']
for runtime, devices in d.items():
    if runtime.endswith('tvOS-27-0'):
        choices=[x for x in devices if x.get('isAvailable') and 'Apple TV' in x['name']]
        if choices:
            print(choices[0]['udid']);break
PY
)"
if [ -z "$udid" ]; then echo 'BLOCKED: compatible tvOS 27.0 simulator unavailable' | tee "$out/runtime-status.txt"; exit 0; fi
echo "$udid" > "$out/simulator-udid.txt"
trap 'xcrun simctl shutdown "$udid" || true' EXIT
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b
packages="$RUNNER_TEMP/SourcePackages"
derived="$RUNNER_TEMP/DerivedData"
set +e
xcodebuild -project Swiftfin.xcodeproj -scheme 'Swiftfin tvOS' -configuration Debug \
  -sdk appletvsimulator -destination "platform=tvOS Simulator,id=$udid" \
  -clonedSourcePackagesDirPath "$packages" -derivedDataPath "$derived" \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build > "$out/simulator-build.log" 2>&1
rc=$?
set -e
echo "$rc" > "$out/simulator-build.exit"
if [ "$rc" != 0 ]; then echo 'BLOCKED: simulator build failed' | tee "$out/runtime-status.txt"; exit "$rc"; fi
app="$derived/Build/Products/Debug-appletvsimulator/Swiftfin.app"
test -d "$app"
bundle="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Info.plist")"
xcrun vtool -show-build "$app/Swiftfin" > "$out/simulator-macho.txt"
xcrun simctl install "$udid" "$app"
xcrun simctl launch "$udid" "$bundle" | tee "$out/launch.txt"
sleep 10
xcrun simctl io "$udid" screenshot "$out/launch.png"
xcrun simctl spawn "$udid" launchctl list > "$out/launchctl-list.txt"
grep -F "$bundle" "$out/launchctl-list.txt"
echo 'PASS: installed, launched and app service observed after 10 seconds (simulator only)' | tee "$out/runtime-status.txt"
xcrun simctl terminate "$udid" "$bundle"
# Existing upstream screenshot test uses public Jellyfin demo, not private server credentials.
# It exercises navigation, focus, playback and seeking, but is not a full issue-specific assertion suite.
set +e
xcodebuild -project Swiftfin.xcodeproj -scheme 'Swiftfin tvOS' -configuration Debug \
  -sdk appletvsimulator -destination "platform=tvOS Simulator,id=$udid" \
  -clonedSourcePackagesDirPath "$packages" -derivedDataPath "$derived" \
  -resultBundlePath "$RUNNER_TEMP/simulator-tests.xcresult" \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipMacroValidation \
  -parallel-testing-enabled NO -only-testing:'Swiftfin tvOS Screenshots/ScreenshotTests/testScreenshots' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test > "$out/simulator-tests.log" 2>&1
rc=$?
set -e
echo "$rc" > "$out/simulator-tests.exit"
if [ -d "$RUNNER_TEMP/simulator-tests.xcresult" ]; then
  ditto -c -k --sequesterRsrc --keepParent "$RUNNER_TEMP/simulator-tests.xcresult" "$out/simulator-tests.xcresult.zip"
  (cd "$out"; shasum -a 256 *.zip > SHA256SUMS)
fi
cmp "$pins" "$out/Package.resolved"
test -z "$(git status --porcelain --untracked-files=no)"
if [ "$rc" = 0 ]; then echo 'PASS: upstream screenshot UI journey; remote seeking and focus exercised, supplement-specific assertions NOT RUN' | tee -a "$out/runtime-status.txt"; else echo 'UI journey failed or blocked; inspect test log before classification' | tee -a "$out/runtime-status.txt"; fi
exit "$rc"
