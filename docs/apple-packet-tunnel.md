# Apple packet tunnel

HN-603 isolates Apple VPN packet processing from the Hub app and embedded Hub
services. The initial supported host is macOS 14 or newer.

## Target boundary

Add a macOS Network Extension target named `PacketTunnelExtension` with bundle
identifier `dev.v57.Hub.PacketTunnelExtension`. Only that target links
NetworkExtension and WireGuardKit. The app communicates through `NETunnelProviderProtocol`,
provider messages, and the versioned JSON configuration in the shared app-group
container.

The main app must not import WireGuardKit. HubService remains responsible only
for Hub identity and wire contracts.

## Entitlements and signing

Both the containing app and extension need the App Groups capability for
`group.dev.v57.hub`. Both targets also need the Network Extensions capability
with `packet-tunnel-provider`. Provisioning profiles for both bundle identifiers
must include these entitlements; otherwise `NETunnelProviderManager` fails with
`NEVPNErrorDomain Code=5` (`IPC failed`).

The checked-in entitlements are complete. Regenerate the automatic profile for
`dev.v57.Hub` after enabling Network Extensions in the developer account.

## Shared configuration

`HubNetworkProfileConfiguration` is the only persisted configuration contract.
Readers reject unknown versions, non-Hub DNS suffixes, addresses outside the
overlay, and any routes other than canonical `100.96.0.0/11` and
`fd48:5542:4e45::/48` prefixes. Writes use
an atomic replacement in the app-group container. Key material is stored in a
shared-access Keychain group, not in the app-group JSON file.

### Readiness signing identity (HN-872)

Readiness uses the Hub Ed25519 identity stored as
`dev.v57.Hub.identity.v1` / `ed25519-private-key` in the Keychain access group
shared by `dev.v57.Hub` and `dev.v57.Hub.PacketTunnelExtension`. Assertions do
not carry a public key; hub-server verifies them against authenticated sender
context. WireGuard retains a separate X25519 key because it serves tunnel key
agreement rather than identity signing.

Both targets declare `$(AppIdentifierPrefix)dev.v57.Hub` in
`keychain-access-groups`. Signed-host acceptance asks the running extension for
a purpose-separated fixed-message signature and verifies it with Hub's public
key. The probe response contains only public key and signature and is compiled
in Debug builds only.

## Routing and DNS

The packet tunnel installs only Hub overlay prefixes (`100.96.0.0/11` and
`fd48:5542:4e45::/48`). It does not install `0.0.0.0/0` or `::/0`. DNS handling matches
only `hub.invalid`; ordinary DNS remains on the system resolver.

## WireGuard dependency

WireGuardKit is added directly to `PacketTunnelExtension` and to no app,
service, encoder, or shared-model target. A project check must fail if a
WireGuard product appears in the main Hub or Hub Pro framework phases.

## Activation sequence

1. The app obtains a Hub Network profile and stores validated shared config.
2. The app saves and enables `NETunnelProviderManager`.
3. The extension loads the config, authenticates the profile, and applies
   overlay-only network settings.
4. The extension requests and validates a purpose-separated connection grant.
5. WireGuardKit configures the authorized peer and resource route.
6. Revocation removes the peer/route and terminates affected flows.

The extension is embedded in Hub. It validates Hub-signed grants, configures an
authorized WireGuard peer, publishes overlay-only routes, serves reserved-suffix
DNS locally, and tears down peer, DNS, and network settings on stop.

## Share Network and invitations

On macOS, **Share Network** makes the running Hub App and its packet tunnel the
local invitation agent. Keep both the app and tunnel running while creating an
Invite Code and until the joining device finishes enrollment. The Hub Network
page shows `Available (This Mac)` when invitation bootstrap is ready; membership
alone does not make invitations available.

The configured hub-net-node is rendezvous-only. It authenticates the invitation
and exchanges bounded direct-path candidates, but does not forward Hub RPC,
enrollment, DNS, or application traffic. Joining devices must establish a direct
WireGuard path to this Mac. Share Network installs only transaction-scoped host
routes during enrollment and removes them when the transaction ends.

Share Network does not enable traffic relay, internet forwarding, NAT, default
routes, or gateway service. Gateway serving and gateway selection remain separate
explicit controls. Turning off Share Network, stopping the tunnel, or quitting Hub
makes new Invite Codes unavailable and cancels active bootstrap work.

## HN-604 live acceptance

Set `HUB_HN604_LIVE_ACCEPTANCE=1` when launching a signed Debug app. The runner
creates an ephemeral remote WireGuard/S3 fixture, starts the production packet
tunnel, and verifies PNG download, JPEG encode/upload, and exact uploaded-byte
read-back through `s3-hn604.v1-test.hub.invalid`. It always removes the manager
and remote fixture.
The fixture also serves authoritative DNS through its authorized overlay address;
the remote peer installs an explicit caller host route so DNS and HTTP replies
return through WireGuard.

## HN-855 signed-device acceptance

Normal unit tests verify profile validation, gateway selection, DNS
authoritativeness, and kill-switch configuration. `HN855SignedDeviceTests`
runs inside the signed containing app and additionally verifies:

- Hub and embedded packet-tunnel signatures use the same development team.
- clipboard and `hub://net/join/` delivery preserve one canonical invitation.
- Network Extension profile installation and removal use real system
  preferences and leave no installed Hub profile.

The signature gate runs in every macOS test invocation. Live preference tests
are opt-in because macOS may display VPN consent and the test removes any
existing Hub Network profile. Supply a current invitation and validated
profile generated by the release fixture:

```sh
HUB_HN855_SIGNED_ACCEPTANCE=1 \
HUB_HN855_INVITATION='hub://net/join/...' \
HUB_HN855_PROFILE_JSON=/absolute/path/to/live-profile.json \
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild test \
  -project Hub.xcodeproj \
  -scheme Hub \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:Tests/HN855SignedDeviceTests
```

Run remaining traffic acceptance through HN-865 fixture after profile install:
two overlapping Hubs, gateway serving, full-tunnel IPv4/IPv6 and DNS, kill
switch on failed handshake/grant/DNS, immediate revocation, and final teardown.

## HN-893 Apple invitation acceptance

`integration/hn893_apple_join.sh` builds and verifies signed Hub.app and its
embedded PacketTunnelExtension, activates Share Network for the first connected
owner Hub, and waits until hub-server reports `Available (This Mac)`. It writes one
invitation to a private temporary file, asks the configured Linux `hub-net`
daemon to join it over SSH, and passes only after Hub observes a newly connected
agent. The App then stops the tunnel and removes the profile when the harness
installed it.

The Hub App must already contain an authenticated owner Hub. The default Linux
SSH alias is `ubuntu`; override it and the remote command when needed:

```sh
HUB_HN893_LINUX_HOST=ubuntu \
HUB_HN893_REMOTE_HUB_NET=/usr/local/bin/hub-net \
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
./integration/hn893_apple_join.sh
```

## HN-894 failure cleanup acceptance

`integration/hn894_failure_acceptance.sh` is the repeatable cross-component
failure gate. It covers App/coordinator teardown, tunnel stop, sleep/wake
instance rotation, unavailable/no-direct-path node behavior, invitation and
lease expiry, interrupted enrollment, and concurrent transaction isolation.
Every case asserts that its owning layer retains no Apple lease, assignment,
temporary WireGuard peer/route, or rendezvous session after failure.

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
./integration/hn894_failure_acceptance.sh
```

## HN-907 native Apple join acceptance

`integration/hn907_native_apple_join.sh` runs same signed-device test on clean
macOS and iOS devices. Each device must have no installed Hub Network profile;
macOS must also have no `/usr/local/bin/hub-net` or `/opt/homebrew/bin/hub-net`.
Test accepts one fixture invitation through `HubNets.main.join`, verifies returned
Hub is persisted, selected, authenticated, and tunnel-connected, then requests a
fixture HTTP URL through direct overlay path. It removes VPN profile and Hub and
polls transaction-scoped cleanup diagnostics until temporary peer/route, node
session, active claim, and staged-secret counts are all zero.

Cleanup endpoint returns:

```json
{"temporaryPeers":0,"temporaryRoutes":0,"nodeSessions":0,"activeClaims":0,"stagedSecrets":0}
```

Run once per fixture invitation. Fixture should issue separate invitation for
each platform when invitations are single-use:

```sh
HUB_HN907_MAC_INVITATION='hub://net/join/...' \
HUB_HN907_MAC_OVERLAY_URL='http://100.96.0.10/health' \
HUB_HN907_MAC_CLEANUP_URL='https://fixture.example/mac/cleanup' \
HUB_HN907_IOS_INVITATION='hub://net/join/...' \
HUB_HN907_IOS_OVERLAY_URL='http://100.96.0.10/health' \
HUB_HN907_IOS_CLEANUP_URL='https://fixture.example/ios/cleanup' \
HUB_HN907_IOS_DESTINATION='platform=iOS,id=DEVICE_UDID' \
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
./integration/hn907_native_apple_join.sh
```
