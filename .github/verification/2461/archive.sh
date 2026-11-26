#!/bin/bash
set -euo pipefail
key="$1"; scheme="$2"
source "$(dirname "$0")/common.sh"
case "$key" in ios) sdk=iphoneos; platform=iOS; min=18.6;; tvos) sdk=appletvos; platform=tvOS; min=26.1;; *) exit 2;; esac
packages="$RUNNER_TEMP/SourcePackages"
archive="$RUNNER_TEMP/Swiftfin.xcarchive"
result="$RUNNER_TEMP/archive.xcresult"
set +e
xcodebuild -project Swiftfin.xcodeproj -scheme "$scheme" -configuration Release -sdk "$sdk" \
  -destination "generic/platform=$platform" -clonedSourcePackagesDirPath "$packages" \
  -derivedDataPath "$RUNNER_TEMP/DerivedData" -archivePath "$archive" -resultBundlePath "$result" \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO archive > "$out/xcodebuild.log" 2>&1
rc=$?
set -e
printf '%s\n' "$rc" > "$out/archive.exit"
tail -70 "$out/xcodebuild.log"
if [ -d "$result" ]; then ditto -c -k --sequesterRsrc --keepParent "$result" "$out/archive.xcresult.zip"; fi
if [ "$rc" != 0 ]; then exit "$rc"; fi
# Preserve the original Xcode archive before assertions that can fail.
ditto -c -k --sequesterRsrc --keepParent "$archive" "$out/Swiftfin.xcarchive.zip"
unzip -tq "$out/Swiftfin.xcarchive.zip"
cmp "$pins" "$out/Package.resolved"
test -z "$(git status --porcelain --untracked-files=no)"
(cd "$out"; shasum -a 256 *.zip > SHA256SUMS)
python3 "$ci/audit.py" "$key" "$packages" "$archive" "$out" "$ci/expected-pins.json" "$min"
