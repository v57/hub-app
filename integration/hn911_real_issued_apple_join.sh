#!/usr/bin/env bash
set -euo pipefail
umask 077

# Signed-device regression. Fixture must expose two distinct invitations issued
# by production hub-pro. Success transcript records server-side event order;
# failure invitation points at a node path that times out without fixture prearm.

workspace=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
app_dir="$workspace/Hub App"
developer_dir=${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}
derived=${HUB_APP_DERIVED_DATA:-"$app_dir/build/HN911DerivedData"}
destination=${HUB_HN911_DESTINATION:-platform=macOS,arch=arm64}

for name in \
  HUB_HN911_SUCCESS_INVITATION HUB_HN911_SUCCESS_TRANSCRIPT_URL HUB_HN911_SUCCESS_CLEANUP_URL \
  HUB_HN911_FAILURE_INVITATION HUB_HN911_FAILURE_TRANSCRIPT_URL HUB_HN911_FAILURE_CLEANUP_URL; do
  if [[ -z ${!name:-} ]]; then
    echo "FAIL: $name is required"
    exit 2
  fi
done

export DEVELOPER_DIR="$developer_dir"
export HUB_HN911_SIGNED_ACCEPTANCE=1

xcodebuild test \
  -project "$app_dir/Hub.xcodeproj" \
  -scheme Hub \
  -destination "$destination" \
  -derivedDataPath "$derived" \
  -only-testing:Tests/HN907SignedDeviceTests/testHN911RealIssuedInvitationRendezvousBeforeClaim \
  -only-testing:Tests/HN907SignedDeviceTests/testHN911TimeoutLeavesNoTransactionState

echo "PASS: HN-911 real-issued Apple rendezvous ordering, single consume, and failure cleanup"
