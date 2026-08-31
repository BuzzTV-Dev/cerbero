#!/bin/bash
# Assembles the per-ABI cerbero tarballs into the universal layout the app
# expects -- <abi>/lib, <abi>/share, ... under one archive -- and checks the
# result before it is published.
#
#   assemble-universal.sh <version> <output-dir> <abi>:<tarball> [<abi>:<tarball> ...]
#
# The per-ABI builds each produce a tarball rooted at the install prefix; the
# universal build produces one with the arch directories already at the top.
# This reproduces the latter from the former, so CI can build the ABIs in
# parallel jobs and still ship the layout the app's fetch script extracts.
set -euo pipefail

if [ "$#" -lt 3 ]; then
    sed -n '2,12p' "$0" >&2
    exit 2
fi

VERSION="$1"; shift
OUTPUT_DIR="$1"; shift

HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGINS_FILE="${HERE}/required-plugins.txt"
STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT

ABIS=""
for arg in "$@"; do
    abi="${arg%%:*}"
    tarball="${arg#*:}"
    if [ "${abi}" = "${arg}" ] || [ -z "${tarball}" ]; then
        echo "ERROR: expected <abi>:<tarball>, got '${arg}'" >&2
        exit 2
    fi
    if [ ! -f "${tarball}" ]; then
        echo "ERROR: no tarball at ${tarball}" >&2
        exit 1
    fi
    echo "unpacking ${abi} <- ${tarball}"
    mkdir -p "${STAGE}/${abi}"
    tar -xf "${tarball}" -C "${STAGE}/${abi}"
    # A per-ABI tarball is rooted at the install prefix, but a universal one is
    # rooted at the arch directory. Accept either, so this keeps working if the
    # build is ever switched back to the universal config.
    if [ -d "${STAGE}/${abi}/${abi}" ]; then
        mv "${STAGE}/${abi}/${abi}" "${STAGE}/${abi}.tmp"
        rm -rf "${STAGE}/${abi}"
        mv "${STAGE}/${abi}.tmp" "${STAGE}/${abi}"
    fi
    ABIS="${ABIS} ${abi}"
done

status=0
for abi in ${ABIS}; do
    for path in lib/pkgconfig lib/gstreamer-1.0 share/gst-android/ndk-build/gstreamer-1.0.mk; do
        if [ ! -e "${STAGE}/${abi}/${path}" ]; then
            echo "ERROR: ${abi} is missing ${path}" >&2
            status=1
        fi
    done
    while read -r plugin; do
        case "${plugin}" in ''|\#*) continue ;; esac
        if [ ! -f "${STAGE}/${abi}/lib/gstreamer-1.0/libgst${plugin}.a" ]; then
            echo "ERROR: ${abi} is missing plugin ${plugin}" >&2
            status=1
        fi
        # ndk-build's libtool emulation resolves each archive through its .la,
        # so a missing one fails the app's link rather than this build.
        if [ ! -f "${STAGE}/${abi}/lib/gstreamer-1.0/libgst${plugin}.la" ]; then
            echo "ERROR: ${abi} is missing ${plugin}'s .la" >&2
            status=1
        fi
    done < "${PLUGINS_FILE}"
    count=$(find "${STAGE}/${abi}/lib/gstreamer-1.0" -maxdepth 1 -name '*.a' 2>/dev/null | wc -l)
    echo "${abi}: ${count} plugins"
done
if [ "${status}" -ne 0 ]; then
    echo "ERROR: the assembled tree is not usable by the app, refusing to publish" >&2
    exit "${status}"
fi

mkdir -p "${OUTPUT_DIR}"
OUTPUT_DIR="$(cd "${OUTPUT_DIR}" && pwd)"
TARBALL="${OUTPUT_DIR}/gstreamer-1.0-android-universal-${VERSION}.tar.xz"

echo "creating ${TARBALL}"
# -T0 so xz uses every core; this is ~450 MB of static archives and the default
# single-threaded compression takes longer than the rest of this script.
XZ_OPT="${XZ_OPT:--6 -T0}" tar -cJf "${TARBALL}" -C "${STAGE}" ${ABIS}

( cd "${OUTPUT_DIR}" && sha256sum "$(basename "${TARBALL}")" > "$(basename "${TARBALL}").sha256" )
cat "${TARBALL}.sha256"
ls -l "${TARBALL}"
