#!/bin/sh
set -eu

action="${1:-build}"
set -- ${ARCHS}
target_arch="${1:-unknown}"
source_stamp="$(cksum api-apple.go wireguard.h go.mod Makefile | cksum | awk '{print $1}')"
cache_root="/tmp/hub-wireguard-go-${UID}/${CONFIGURATION}-${PLATFORM_NAME}-${target_arch}-${source_stamp}"
products="${cache_root}/products"
objects="${cache_root}/objects"

# Go keeps its module cache in GOPATH (default ~/go). When ~/go is a symlink to
# an unmounted volume, go build fails with "mkdir ~/go: file exists" and Xcode
# reports only "never received target ended message". Use a cache of our own.
if [ -z "${GOPATH:-}" ] && [ -L "${HOME}/go" ] && [ ! -d "${HOME}/go" ]; then
  export GOPATH="/tmp/hub-wireguard-go-${UID}/gopath"
fi

# Upstream Makefile uses Xcode output paths as make target names. A project path
# containing spaces is therefore parsed as multiple targets. Build in a stable,
# space-free cache and copy only resulting archive/header into Xcode products.
/usr/bin/make "${action}" DESTDIR="${products}" BUILDDIR="${objects}"

if [ "${action}" != "clean" ]; then
  /bin/mkdir -p "${CONFIGURATION_BUILD_DIR}"
  /bin/cp "${products}/libwg-go.a" "${CONFIGURATION_BUILD_DIR}/libwg-go.a"
  if [ -f "${products}/wireguard-go-version.h" ]; then
    /bin/cp "${products}/wireguard-go-version.h" \
      "${CONFIGURATION_BUILD_DIR}/wireguard-go-version.h"
  fi
fi
