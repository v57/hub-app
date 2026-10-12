# Hub Network packet-tunnel extension

This directory contains the macOS Hub Network packet-tunnel extension target.

The extension target:

- is a `com.apple.product-type.app-extension` using
  `com.apple.networkextension.packet-tunnel`;
- imports `NetworkExtension` and WireGuardKit;
- reads only versioned `HubNetworkProfileConfiguration` data from
  `group.dev.v57.hub`;
- installs only the `100.96.0.0/11` and `fd48:5542:4e45::/48` overlay routes;
- resolves authorized `hub.invalid` names through its local DNS listener;
- validates Hub-signed grants before configuring a peer; and
- owns gateway-serving lifecycle state and acknowledges readiness to the
  containing app before Hub capability advertisement;
- never registers a default route or a rendezvous node as a data-plane peer.

Gateway serving remains disabled unless `gatewayServingEnabled` is explicitly
persisted. Startup failure reports unavailable, and tunnel teardown clears the
runtime state. The containing app removes Hub advertisement before disabling
the extension.

WireGuardKit belongs to this target only. The Hub app and HubService package
must remain free of WireGuard implementation dependencies.

Hub App uses the source-controlled fork at `Vendor/wireguard-apple`, pinned
from upstream revision `56231f3c6aec8fad3332cf5a6fe5f5c8bb7ffa14`. Its only
backend extension is `wgSendDatagram`: an outbound-only, 16 KiB-bounded call
that sends an authenticated rendezvous observation probe through the active
WireGuard UDP bind. It exposes no socket, receive callback, plaintext tunnel
traffic, or relay API. This lets hub-net-node observe the exact NAT mapping
without restarting the tunnel or changing existing peers.

Both extension and containing app require automatic profiles with Network
Extension and `group.dev.v57.hub` App Group capabilities. See
`docs/apple-packet-tunnel.md`.
