#!/usr/bin/env bash
set -euo pipefail
umask 077

# Signed macOS and iOS native-join acceptance. Fixture variables must describe
# one direct-path invitation and a cleanup endpoint scoped to that transaction.

workspace=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
app_dir="$workspace/Hub App"
developer_dir=${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}
derived=${HUB_APP_DERIVED_DATA:-"$app_dir/build/HN907DerivedData"}
mac_destination=${HUB_HN907_MAC_DESTINATION:-platform=macOS,arch=arm64}
ios_destination=${HUB_HN907_IOS_DESTINATION:-}

for name in \
  HUB_HN907_MAC_INVITATION HUB_HN907_MAC_OVERLAY_URL HUB_HN907_MAC_CLEANUP_URL \
  HUB_HN907_IOS_INVITATION HUB_HN907_IOS_OVERLAY_URL HUB_HN907_IOS_CLEANUP_URL; do
  if [[ -z ${!name:-} ]]; then
    echo "FAIL: $name is required"
    exit 2
  fi
done
if [[ -z "$ios_destination" ]]; then
  echo "FAIL: HUB_HN907_IOS_DESTINATION must name a signed iOS device destination"
  exit 2
fi

export DEVELOPER_DIR="$developer_dir"
export HUB_HN907_SIGNED_ACCEPTANCE=1

export HUB_HN907_INVITATION="$HUB_HN907_MAC_INVITATION"
export HUB_HN907_OVERLAY_URL="$HUB_HN907_MAC_OVERLAY_URL"
export HUB_HN907_CLEANUP_URL="$HUB_HN907_MAC_CLEANUP_URL"
xcodebuild test \
  -project "$app_dir/Hub.xcodeproj" \
  -scheme Hub \
  -destination "$mac_destination" \
  -derivedDataPath "$derived/macOS" \
  -only-testing:Tests/HN907SignedDeviceTests/testCleanDeviceNativeJoinTrafficAndCleanup

export HUB_HN907_INVITATION="$HUB_HN907_IOS_INVITATION"
export HUB_HN907_OVERLAY_URL="$HUB_HN907_IOS_OVERLAY_URL"
export HUB_HN907_CLEANUP_URL="$HUB_HN907_IOS_CLEANUP_URL"
xcodebuild test \
  -project "$app_dir/Hub.xcodeproj" \
  -scheme Hub \
  -destination "$ios_destination" \
  -derivedDataPath "$derived/iOS" \
  -only-testing:Tests/HN907SignedDeviceTests/testCleanDeviceNativeJoinTrafficAndCleanup

echo "PASS: HN-907 macOS and iOS native join, direct overlay traffic, and complete cleanup"
