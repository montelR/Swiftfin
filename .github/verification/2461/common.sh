#!/bin/bash
set -euo pipefail
base=35a5f35812deb9838dfc69b6554a6a3f935797d1
expected=1b49e16455f8fca1d96b6c2c081f066a0816cab771573133530077e21004aa89
ci="$(cd "$(dirname "$0")" && pwd)"
out="$RUNNER_TEMP/evidence"
mkdir -p "$out"
exec > >(tee "$out/verification.log") 2>&1
test "$(uname -m)" = arm64
test -d "$DEVELOPER_DIR"
sw_vers
xcodebuild -version | tee "$out/xcode-version.txt"
grep -qx 'Xcode 27.1' "$out/xcode-version.txt"
xcrun swift --version | tee "$out/swift-version.txt"
grep -Eq 'Swift version 6\.4([. ]|$)' "$out/swift-version.txt"
xcodebuild -showsdks
df -h "$RUNNER_TEMP"
appcommit="$(git rev-parse HEAD^)"
test "$(git rev-parse "$appcommit^")" = "$base"
git diff --binary --abbrev=8 "$base" "$appcommit" > "$out/approved.patch"
test "$(shasum -a 256 "$out/approved.patch" | awk '{print $1}')" = "$expected"
git diff --name-only "$appcommit" HEAD | tee "$out/ci-files.txt"
# The build itself runs outside the CI commit, at the exact application commit.
git worktree add --detach "$RUNNER_TEMP/approved-source" "$appcommit"
cd "$RUNNER_TEMP/approved-source"
test -z "$(git status --porcelain --untracked-files=no)"
git rev-parse HEAD | tee "$out/app-commit.txt"
pins=Swiftfin.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
cp "$pins" "$out/Package.resolved"
