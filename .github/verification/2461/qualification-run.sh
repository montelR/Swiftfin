#!/bin/bash
set -euo pipefail
variant="$1"
ref="$2"
shift 2
test "$#" -eq 2
for scenario in "$@"; do
  case "$scenario" in testPausedForward|testPausedBackward|testActiveForward|testActiveBackward|testControlsAndPlayback|testSupplementFocus) ;; *) exit 2;; esac
done
ci="$(cd "$(dirname "$0")" && pwd)"
out="$RUNNER_TEMP/evidence"
mkdir -p "$out"
exec > >(tee "$out/verification.log") 2>&1
base=35a5f35812deb9838dfc69b6554a6a3f935797d1
appcommit=12b3c2b4684ced6b412adf865ca793685e331465
expected=1b49e16455f8fca1d96b6c2c081f066a0816cab771573133530077e21004aa89
case "$variant:$ref" in "upstream:$base"|"revision-e:$appcommit") ;; *) exit 2;; esac
test "$(uname -m)" = arm64
xcodebuild -version | tee "$out/xcode-version.txt"
grep -qx 'Xcode 27.1' "$out/xcode-version.txt"
xcrun swift --version | tee "$out/swift-version.txt"
grep -Eq 'Swift version 6\.4([. ]|$)' "$out/swift-version.txt"
sw_vers > "$out/macos-version.txt"
git merge-base --is-ancestor "$appcommit" HEAD
git diff --binary --abbrev=8 "$base" "$appcommit" > "$out/approved.patch"
test "$(shasum -a 256 "$out/approved.patch" | awk '{print $1}')" = "$expected"
git worktree add --detach "$RUNNER_TEMP/comparison-source" "$ref"
cd "$RUNNER_TEMP/comparison-source"
test -z "$(git status --porcelain)"
git rev-parse HEAD > "$out/source-commit.txt"
pins=Swiftfin.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
cp "$pins" "$out/Package.resolved"
git show "$base:$pins" > "$out/upstream-pins.json"
cmp "$pins" "$out/upstream-pins.json"
xcrun simctl list -j devices available > "$out/devices.json"
xcrun simctl list -j runtimes > "$out/runtimes.json"
udid="$(python3 - "$out/devices.json" <<'PY'
import json,sys
for runtime,devices in json.load(open(sys.argv[1]))['devices'].items():
 if runtime.endswith('tvOS-27-0'):
  for x in devices:
   if x.get('isAvailable') and x['name']=='Apple TV 4K (3rd generation)':
    print(x['udid']);sys.exit(0)
PY
)"
test -n "$udid"
printf '%s\n' "$udid" > "$out/simulator-udid.txt"
packages="$RUNNER_TEMP/SourcePackages"
derived="$RUNNER_TEMP/DerivedData"
testfile=Tools/Screenshots/Tests/ScreenshotTests.swift
cp "$testfile" "$RUNNER_TEMP/original-test.swift"
finish() {
  rc=$?
  set +e
  cp "$RUNNER_TEMP/original-test.swift" "$testfile"
  xcrun simctl shutdown "$udid" >>"$out/shutdown.log" 2>&1
  git diff --binary > "$out/final-source-diff.patch"
  if ! cmp "$pins" "$out/Package.resolved" || [ -s "$out/final-source-diff.patch" ]; then rc=1; fi
  git status --porcelain > "$out/final-source-status.txt"
  if [ -s "$out/final-source-status.txt" ]; then rc=1; fi
  (cd "$out"; find . -type f ! -name SHA256SUMS ! -name verification.log -print0 | xargs -0 shasum -a 256 > SHA256SUMS)
  trap - EXIT
  exit "$rc"
}
trap finish EXIT
cat "$ci/qualification-tests.swift" >> "$testfile"
git diff -- "$testfile" > "$out/test-only-overlay.patch"
test "$(git diff --name-only)" = "$testfile"
cp "$ci/qualification-tests.swift" "$out/test-harness.swift"
unset SDKROOT ARCHS SUPPORTED_PLATFORMS ONLY_ACTIVE_ARCH
args=(-project Swiftfin.xcodeproj -scheme 'Swiftfin tvOS' -configuration Debug -destination "platform=tvOS Simulator,id=$udid" -clonedSourcePackagesDirPath "$packages" -derivedDataPath "$derived" -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipMacroValidation -destination-timeout 180)
# Check the exact preinstalled device BEFORE any build or test; never erase it.
python3 "$ci/comparison-readiness.py" prebuild "$udid" "$out/prebuild-readiness" "${args[@]}"
printf '%q ' xcodebuild "${args[@]}" build-for-testing > "$out/build-command.txt"
echo >> "$out/build-command.txt"
set +e
xcodebuild "${args[@]}" -resultBundlePath "$RUNNER_TEMP/build.xcresult" build-for-testing > "$out/build.log" 2>&1
rc=$?
set -e
echo "$rc" > "$out/build.exit"
if [ -d "$RUNNER_TEMP/build.xcresult" ]; then ditto -c -k --sequesterRsrc --keepParent "$RUNNER_TEMP/build.xcresult" "$out/build.xcresult.zip"; fi
if [ "$rc" != 0 ]; then tail -80 "$out/build.log"; exit "$rc"; fi
python3 "$ci/runtime-macro-audit.py" "$derived" "$out"
python3 "$ci/runtime-pin-audit.py" "$packages" "$out" "$ci/expected-pins.json"
xcrun vtool -show-build "$derived/Build/Products/Debug-appletvsimulator/Swiftfin.app/Swiftfin" > "$out/app-macho.txt"
grep -Eiq 'platform[[:space:]]+TVOSSIMULATOR' "$out/app-macho.txt"
failed=0
for scenario in "$@"; do
  dest="$out/$scenario"; mkdir -p "$dest"
  # Isolate app data and keychain, not the preinstalled simulator runtime.
  export COMPARISON_PRODUCTS="$derived/Build/Products/Debug-appletvsimulator"
  if ! python3 "$ci/comparison-readiness.py" scenario "$udid" "$dest/readiness" "${args[@]}" > "$dest/reset.log" 2>&1; then
    echo "BLOCKED: readiness/reset failed for $scenario" | tee "$dest/scenario-status.txt"
    failed=1
    continue
  fi
  bundle="$RUNNER_TEMP/$scenario.xcresult"
  set +e
  xcodebuild "${args[@]}" -parallel-testing-enabled NO -collect-test-diagnostics never -resultBundlePath "$bundle" "-only-testing:Swiftfin tvOS Screenshots/Phase4DQualificationTests/$scenario" test-without-building > "$dest/test.log" 2>&1
  rc=$?
  set -e
  echo "$rc" > "$dest/test.exit"
  if [ -d "$bundle" ]; then
    ditto -c -k --sequesterRsrc --keepParent "$bundle" "$dest/result.xcresult.zip"
    xcrun xcresulttool get test-results summary --path "$bundle" --format json > "$dest/summary.json" 2>"$dest/summary-error.log" || true
    xcrun xcresulttool export attachments --path "$bundle" --output-path "$dest/attachments" > "$dest/attachments-export.log" 2>&1 || true
  fi
  grep -E 'PHASE4D |Test Case|\\*\\* TEST|error:' "$dest/test.log" | tail -35 || true
  (cd "$dest"; find . -type f ! -name SHA256SUMS -print0 | xargs -0 shasum -a 256 > SHA256SUMS)
  if [ "$rc" -ne 0 ]; then failed=1; fi
  # A skipped XCTest can exit zero; require the explicit scenario completion marker.
  if ! grep -Fq "PHASE4D COMPLETE $scenario" "$dest/test.log"; then failed=1; fi
done
exit "$failed"
