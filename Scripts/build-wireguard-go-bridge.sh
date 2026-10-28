#!/bin/sh
set -eu

action="${1:-build}"

# The Makefile adds -m<platform>-version-min from these, but Xcode 27 no longer
# passes them to external build targets, so the Go objects came out built for
# the SDK's version (27.0) instead of the deployment target.
if [ -z "${DEPLOYMENT_TARGET_CLANG_FLAG_NAME:-}" ]; then
  case "${PLATFORM_NAME}" in
    macosx) DEPLOYMENT_TARGET_CLANG_FLAG_NAME=mmacosx-version-min ;;
    iphoneos) DEPLOYMENT_TARGET_CLANG_FLAG_NAME=miphoneos-version-min ;;
    iphonesimulator) DEPLOYMENT_TARGET_CLANG_FLAG_NAME=mios-simulator-version-min ;;
  esac
  DEPLOYMENT_TARGET_CLANG_ENV_NAME="${DEPLOYMENT_TARGET_SETTING_NAME:-}"
  export DEPLOYMENT_TARGET_CLANG_FLAG_NAME DEPLOYMENT_TARGET_CLANG_ENV_NAME
fi

archs="$(echo ${ARCHS} | tr ' ' '-')"
deployment_target="$(eval echo "\${${DEPLOYMENT_TARGET_CLANG_ENV_NAME:-unset}:-any}")"
source_stamp="$(cksum *.go wireguard.h go.mod go.sum Makefile | cksum | awk '{print $1}')"
cache_root="/tmp/hub-wireguard-go-${UID}/${CONFIGURATION}-${PLATFORM_NAME}-${deployment_target}-${archs}-${source_stamp}"
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
