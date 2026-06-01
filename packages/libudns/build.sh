#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# build.sh
#
# This script builds the libudns library.
# Usage:
# ./build.sh <ipv6_support>
# =============================================================================

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <ipv6_support>"
    echo "Example: $0 --enable-ipv6|--disable-ipv6"
    exit 1
fi

FLAG="$1"
if [[ "$FLAG" == "--enable-ipv6" ]]; then
    IPV6_SUPPORT="ON"
elif [[ "$FLAG" == "--disable-ipv6" ]]; then
    IPV6_SUPPORT="OFF"
else
    echo "ERROR: IPv6 support must be either --enable-ipv6 or --disable-ipv6"
    exit 1
fi
DESTDIR="${DESTDIR:-/tmp/libudns-build/install-ipv6-${IPV6_SUPPORT}}"
CORES=$(nproc)
echo "====> Building libudns with IPv6 support: ${IPV6_SUPPORT}"
echo "====> Destination directory: ${DESTDIR}"
mkdir -p "${DESTDIR}/usr/include" "${DESTDIR}/usr/bin" "${DESTDIR}/usr/lib"
export CFLAGS="-O2 -DNDEBUG -g0 -ffunction-sections -fdata-sections -w -pipe"
export CXXFLAGS="${CFLAGS}"
export LDFLAGS="-Wl,--gc-sections -s"
echo "====> Running configure..."
./configure "$FLAG"
echo "====> Building libudns..."
make -j"${CORES}" sharedlib dnsget rblcheck
echo "====> Installing libudns to ${DESTDIR}..."
FILES_TO_COPY=(
    "udns.h:${DESTDIR}/usr/include/"
    "dnsget:${DESTDIR}/usr/bin/"
    "rblcheck:${DESTDIR}/usr/bin/"
    "libudns.so.0:${DESTDIR}/usr/lib/"
    "libudns.a:${DESTDIR}/usr/lib/"
)
for FILE in "${FILES_TO_COPY[@]}"; do
    SRC="${FILE%%:*}"
    DEST="${FILE##*:}"
    cp -v "$SRC" "$DEST"
done
ln -sf libudns.so.0 "${DESTDIR}/usr/lib/libudns.so"
echo "====> libudns build completed successfully with IPv6 support: ${IPV6_SUPPORT}"
echo "====> Files are installed in ${DESTDIR}"
exit 0
