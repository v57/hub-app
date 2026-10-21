#!/bin/sh
# Builds hub-net-node from ../../../../Network/hub-net-node and runs the inviter client against it
set -e
cd "$(dirname "$0")"
NODE_SRC="${HUB_NET_NODE_SRC:-../../../../Network/hub-net-node}"
mkdir -p .build
(cd "$NODE_SRC" && go build -o "$OLDPWD/.build/hub-net-node" ./cmd/hub-net-node)
HUB_NET_NODE="$PWD/.build/hub-net-node" swift test "$@"
