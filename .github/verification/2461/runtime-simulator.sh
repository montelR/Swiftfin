#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
xcrun simctl list -j devices available > "$out/devices.json"
xcrun simctl list -j runtimes > "$out/runtimes.json"
udid="$(python3 - "$out/devices.json" <<'PY'
import json,sys
for runtime, devices in json.load(open(sys.argv[1]))['devices'].items():
    if runtime.endswith('tvOS-27-0'):
        choices=[x for x in devices if x.get('isAvailable') and 'Apple TV' in x['name']]
        if choices: print(choices[0]['udid']);break
PY
)"
if [ -z "$udid" ]; then echo 'BLOCKED: tvOS 27.0 simulator unavailable' | tee "$out/runtime-status.txt"; exit 1; fi
echo "$udid" > "$out/simulator-udid.txt"
packages="$RUNNER_TEMP/SourcePackages"
derived="$RUNNER_TEMP/DerivedData"
# No global -sdk, SDKROOT, ARCHS, SUPPORTED_PLATFORMS, or platform override.
unset SDKROOT ARCHS SUPPORTED_PLATFORMS ONLY_ACTIVE_ARCH
args=(-project Swiftfin.xcodeproj -scheme 'Swiftfin tvOS' -configuration Debug -destination "platform=tvOS Simulator,id=$udid" -clonedSourcePackagesDirPath "$packages" -derivedDataPath "$derived" -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipMacroValidation)
printf '%q ' xcodebuild "${args[@]}" build > "$out/build-command.txt"
printf '\n' >> "$out/build-command.txt"
pack_result() {
  if [ -d "$1" ]; then ditto -c -k --sequesterRsrc --keepParent "$1" "$out/$2.zip"; fi
}
finish() {
  rc=$?
  set +e
  if [ -n "$udid" ]; then xcrun simctl shutdown "$udid" >>"$out/shutdown.log" 2>&1; fi
  cmp "$pins" "$out/Package.resolved" > "$out/pins-comparison.txt" 2>&1
  pin_rc=$?
  git diff --binary > "$out/final-source-diff.patch"
  if [ "$pin_rc" -ne 0 ] || [ -s "$out/final-source-diff.patch" ]; then rc=1; fi
  (cd "$out"; find . -type f ! -name SHA256SUMS ! -name verification.log -print0 | xargs -0 shasum -a 256 > SHA256SUMS)
  trap - EXIT
  exit "$rc"
}
trap finish EXIT
set +e
xcodebuild "${args[@]}" -resultBundlePath "$RUNNER_TEMP/build.xcresult" build > "$out/simulator-build.log" 2>&1
rc=$?
set -e
echo "$rc" > "$out/simulator-build.exit"
pack_result "$RUNNER_TEMP/build.xcresult" simulator-build.xcresult
# Verify physical Mach-O metadata, not just command-line target strings.
python3 "$ci/runtime-macro-audit.py" "$derived" "$out" || { echo 'BLOCKED: host macro metadata not verified' | tee "$out/macro-status.txt"; exit 1; }
if [ "$rc" != 0 ]; then tail -80 "$out/simulator-build.log"; echo 'BLOCKED: destination-only build failed' | tee "$out/runtime-status.txt"; exit "$rc"; fi
echo 'PASS: host macro metadata verified' | tee "$out/macro-status.txt"
python3 "$ci/runtime-pin-audit.py" "$packages" "$out" "$ci/expected-pins.json"
echo 'PASS: destination-only simulator build' | tee "$out/runtime-status.txt"
app="$derived/Build/Products/Debug-appletvsimulator/Swiftfin.app"
test -d "$app"
xcrun vtool -show-build "$app/Swiftfin" > "$out/simulator-macho.txt"
grep -Eiq 'platform[[:space:]]+TVOSSIMULATOR' "$out/simulator-macho.txt"
bundle="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Info.plist")"
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b
xcrun simctl install "$udid" "$app"
xcrun simctl launch "$udid" "$bundle" | tee "$out/launch.txt"
sleep 10
xcrun simctl io "$udid" screenshot "$out/launch.png"
xcrun simctl spawn "$udid" launchctl list > "$out/launchctl-list.txt"
grep -F "$bundle" "$out/launchctl-list.txt"
echo 'PASS: simulator install, launch and running process observed' | tee -a "$out/runtime-status.txt"
xcrun simctl terminate "$udid" "$bundle"
xcrun simctl uninstall "$udid" "$bundle"
# Test-only overlay in disposable worktree. Original application sources are unchanged.
testfile=Tools/Screenshots/Tests/ScreenshotTests.swift
cp "$testfile" "$RUNNER_TEMP/original-ScreenshotTests.swift"
cat "$ci/runtime-targeted-tests.swift" >> "$testfile"
git diff -- "$testfile" > "$out/test-only-overlay.patch"
test "$(git diff --name-only)" = "$testfile"
set +e
xcodebuild "${args[@]}" -parallel-testing-enabled NO -collect-test-diagnostics never -resultBundlePath "$RUNNER_TEMP/tests.xcresult" -only-testing:'Swiftfin tvOS Screenshots/Phase4BRuntimeTests' test > "$out/simulator-tests.log" 2>&1
rc=$?
set -e
cp "$RUNNER_TEMP/original-ScreenshotTests.swift" "$testfile"
echo "$rc" > "$out/simulator-tests.exit"
pack_result "$RUNNER_TEMP/tests.xcresult" simulator-tests.xcresult
tail -65 "$out/simulator-tests.log"
exit "$rc"
