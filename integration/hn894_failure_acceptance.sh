#!/usr/bin/env bash
set -euo pipefail

# Cross-component HN-894 failure and cleanup gate. This gate is safe to run on
# any macOS developer host: packet-tunnel lifecycle uses deterministic fakes,
# while hub-pro and hub-net-node exercise their production state stores.

workspace=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
app_dir="$workspace/Hub App"
derived=${HUB_APP_DERIVED_DATA:-"$app_dir/build/HN894DerivedData"}
developer_dir=${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}

export DEVELOPER_DIR="$developer_dir"

xcodebuild test \
  -project "$app_dir/Hub.xcodeproj" \
  -scheme Hub \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived" \
  -only-testing:Tests/ShareNetworkAppAgentCoordinatorTests \
  -only-testing:Tests/PacketTunnelBootstrapComponentTests

bun test \
  "$workspace/hub-pro/src/network/apple-agent.test.ts" \
  "$workspace/hub-pro/src/network/apple-bootstrap.test.ts"

(
  cd "$workspace/hub-net-node"
  go test ./server ./session \
    -run 'Test(AppleInvitationRejectsStaleTunnelBeforeStateCreation|AppleInvitationRejectsReplayAndCleansDisconnectedState|AppleInvitationCloseCancelsSessionState|BootstrapSessionExpiresAtInvitationBoundary|SweepExpiresSessionsAndCandidates|CloseUnlinksPeer)$' \
    -count=1
)

echo "PASS: HN-894 failure teardown leaves zero Apple bindings, peers, routes, assignments, and rendezvous sessions"
