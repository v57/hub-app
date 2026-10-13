#!/usr/bin/env bash
set -euo pipefail
umask 077

# Signed macOS plus Linux direct-enrollment gate for HN-893.
# Hub App must already contain one authenticated owner Hub. Linux hub-net daemon
# must be installed and reachable through HUB_HN893_LINUX_HOST.
#
# NOTE (2026-08-05): this script drives the legacy owner-app invitation path.
# The Hub App is joiner-only: it cannot register as an online inviter
# (finding 5 in TESTING.md), so an app-signed invitation is rejected by
# hub-net-node with "inviter offline". The current Phase 3 Linux acceptance is
# integration/hn93_linux_inviter_join.sh (root integration/), which runs the
# standalone cmd/inviter + real `hub-net join` over kernel WireGuard in
# network namespaces. See that script before using this one.

workspace=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
app_dir="$workspace/Hub App"
developer_dir=${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}
derived=${HUB_APP_DERIVED_DATA:-"$app_dir/build/HN893DerivedData"}
linux_host=${HUB_HN893_LINUX_HOST:-ubuntu}
remote_hub_net=${HUB_HN893_REMOTE_HUB_NET:-hub-net}
result_dir=$(mktemp -d "${TMPDIR:-/tmp}/hn893.XXXXXX")
result_json="$result_dir/invitation.json"
app_log="$result_dir/hub-app.log"
app_pid=

cleanup() {
  if [[ -n "$app_pid" ]] && kill -0 "$app_pid" 2>/dev/null; then
    kill "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
  fi
  rm -rf "$result_dir"
}
trap cleanup EXIT

export DEVELOPER_DIR="$developer_dir"
xcodebuild build \
  -project "$app_dir/Hub.xcodeproj" \
  -scheme Hub \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived"

app="$derived/Build/Products/Debug/Hub.app"
codesign --verify --deep --strict "$app"
codesign --verify --strict "$app/Contents/PlugIns/PacketTunnelExtension.appex"

HUB_HN893_LIVE_ACCEPTANCE=1 \
HUB_HN893_RESULT_JSON="$result_json" \
HUB_HN893_LOCAL_HUB="${HUB_HN893_LOCAL_HUB:-ws://127.0.0.1:1997}" \
  "$app/Contents/MacOS/Hub" >"$app_log" 2>&1 &
app_pid=$!

for _ in {1..180}; do
  [[ -s "$result_json" ]] && break
  if ! kill -0 "$app_pid" 2>/dev/null; then
    tail -40 "$app_log"
    exit 1
  fi
  sleep 1
done
if [[ ! -s "$result_json" ]]; then
  echo "FAIL: Hub App did not produce HN-893 invitation within 180 seconds"
  tail -40 "$app_log"
  exit 1
fi

invitation=$(/usr/bin/plutil -extract invitation raw "$result_json")
ssh "$linux_host" sudo "$remote_hub_net" join "$invitation"

if ! wait "$app_pid"; then
  app_pid=
  tail -40 "$app_log"
  exit 1
fi
app_pid=
grep -q 'HN-893 LIVE ACCEPTANCE PASSED' "$app_log"
echo "PASS: HN-893 Available (This Mac), invitation issuance, Linux direct enrollment"
