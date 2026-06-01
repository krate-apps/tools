#!/usr/bin/env bash
set -e

# =============================================================================
# build.sh
#
# This script handles the building of zlib-ng library.
#
# It performs:
# - Download and compilation of zlib-ng
# - Live installation in the /opt/Krate/vendor/... prefix
# - Staging installation via DESTDIR for final packaging
#
# The final package will contain all components and include:
# - A generated md5sums file
#
# Usage:
# ./build.sh <VERSION>
# Example:
# ./build.sh 2.0.0 or 2.1.5 or 2.2.4
#
# Notes:
# - All configures use the following prefix:
# /opt/Krate/vendor/zlib-ng_${ZLIB_VERSION}
# =============================================================================

usage() {
    echo "Usage: $0 <VERSION>"
    echo "Example: $0 2.0.0"
    exit 1
}

if [ $# -ne 1 ]; then
    usage
fi

# -----------------------------------------------------------------------------
# 0) Parameter analysis and definition of global variables
# -----------------------------------------------------------------------------
INPUT_VERSION="$1"                           # Ex: "2.0.0"
REAL_VERSION="${INPUT_VERSION%%-*}"          # Ex: "2.0.0"
BUILD="1"
FULL_VERSION="${REAL_VERSION}-${BUILD}"

echo "====> Building zlib-ng $REAL_VERSION (build: $BUILD)"
echo "====> Full version: $FULL_VERSION"

ZLIB_VERSION="$INPUT_VERSION"
MAJOR="$(echo "$REAL_VERSION" | cut -d'.' -f1)"
MINOR="$(echo "$REAL_VERSION" | cut -d'.' -f2)"
PATCH="$(echo "$REAL_VERSION" | cut -d'.' -f3)"

# Get the absolute path to the tools directory
WHEREAMI="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOLS_DIR_PACKAGE="$WHEREAMI/packages/zlib-ng"
ARCHITECTURE="amd64"
BASE_DIR="$PWD/custom_build"
mkdir -p "$BASE_DIR"
INSTALL_DIR="$BASE_DIR/install"
mkdir -p "$INSTALL_DIR"

codename=$(lsb_release -cs)
distro=$(lsb_release -is | tr '[:upper:]' '[:lower:]')
os=$distro-$codename
export os

# -----------------------------------------------------------------------------
# 1) zlib-ng build
# -----------------------------------------------------------------------------
build_zlib_ng() {
    echo "====> Building zlib-ng"
    local GIT_REPO_URL SRC_DIR TMP_DIR
    TMP_DIR=$(mktemp -d)
    GIT_REPO_URL="https://github.com/zlib-ng/zlib-ng/archive/refs/tags/${ZLIB_VERSION}.tar.gz"
    SRC_DIR="$BASE_DIR/zlib-ng-${ZLIB_VERSION}"
    rm -rf "$SRC_DIR"
    
    echo "====> Downloading zlib-ng"
    echo "====> GIT_REPO_URL: $GIT_REPO_URL"
    curl -NL "$GIT_REPO_URL" -o zlib-ng.tar.gz
    tar xf zlib-ng.tar.gz -C "$BASE_DIR"
    cd "$SRC_DIR"

    # Configure and build using cmake
    cmake -Wno-dev -Wno-deprecated -G Ninja -B build \
        -D CMAKE_BUILD_TYPE="release" \
        -D CMAKE_C_FLAGS="-O3 -march=x86-64-v3 -fno-plt -flto=auto" \
        -D CMAKE_EXE_LINKER_FLAGS="-Wl,--as-needed -Wl,-O2" \
        -D CMAKE_INSTALL_PREFIX=/usr \
        -D ZLIB_COMPAT=ON \
        -D ZLIB_ENABLE_TESTS=OFF \
        -D ZLIBNG_ENABLE_TESTS=OFF \
        -D WITH_OPTIM=ON \
        -D WITH_NEW_STRATEGIES=ON \
        -D WITH_RUNTIME_CPU_DETECTION=ON \
        -D WITH_SSE2=ON \
        -D WITH_SSSE3=ON \
        -D WITH_SSE42=ON \
        -D WITH_PCLMULQDQ=ON \
        -D WITH_AVX2=ON \
        -D WITH_GZFILEOP=OFF \
        -D WITH_MAINTAINER_WARNINGS=OFF \
        -D WITH_CODE_COVERAGE=OFF \
        -D WITH_INFLATE_STRICT=OFF \
        -D WITH_INFLATE_ALLOW_INVALID_DIST=OFF \
        -D WITH_REDUCED_MEM=OFF \
        -D WITH_NATIVE_INSTRUCTIONS=OFF \
        -D WITH_SANITIZER=OFF \
        -D WITH_GTEST=OFF \
        -D WITH_FUZZERS=OFF \
        -D WITH_BENCHMARKS=OFF \
        -D WITH_BENCHMARK_APPS=OFF \
        -D INSTALL_UTILS=ON

    cmake --build build --parallel $(nproc)
    DESTDIR="$TMP_DIR" cmake --install build

    # Copy files to install directory
    cp -pR "$TMP_DIR/"* "$INSTALL_DIR/"
    
    # Optimize binaries
    echo "====> Optimizing zlib-ng binaries"
    find "$INSTALL_DIR" -type f -exec file {} \; | grep ELF | cut -d: -f1 | while read -r file; do
        if [ -f "$file" ] && [ -x "$file" ]; then
            strip --strip-unneeded "$file" 2>/dev/null || true
            if file "$file" | grep -q "ELF.*executable" && command -v upx >/dev/null 2>&1; then
                upx --best --lzma "$file" 2>/dev/null || true
            fi
        fi
    done

    cd "$WHEREAMI"
    rm -rf "$TMP_DIR" zlib-ng.tar.gz
}

# -----------------------------------------------------------------------------
# 2) Final packaging
# -----------------------------------------------------------------------------
package_zlib_ng_deb() {
    echo "====> Packaging zlib-ng to .deb file"
    local PKG_DIR
    PKG_DIR="$BASE_DIR/pkg_zlib_ng"
    DEB_DIR="$PKG_DIR/DEBIAN"
    rm -rf "$PKG_DIR"
    mkdir -p "$DEB_DIR"
    mkdir -p "$PKG_DIR/usr"
    rsync -a "$INSTALL_DIR/" "$PKG_DIR/"

    if [ -z "$(ls -A "$PKG_DIR/usr")" ]; then
        echo "ERROR: $PKG_DIR/usr is empty."
        exit 1
    fi

    echo "====> Copying control file"
    cp -pr "$TOOLS_DIR_PACKAGE/control" "$DEB_DIR/control"

    echo "====> Setting control file values"
    sed -i \
        -e "s|@REVISION@|${BUILD}|g" \
        -e "s|@ARCHITECTURE@|${ARCHITECTURE}|g" \
        -e "s|@VERSION@|${REAL_VERSION}|g" \
        -e "s|@DATE@|$(date +%Y-%m-%d)|g" \
        -e "s|@SIZE@|$(du -s -k "$PKG_DIR/usr" | cut -f1)|g" \
        "$DEB_DIR/control"

    echo "====> Generating md5sums"
    find "$PKG_DIR" -type f ! -path './DEBIAN/*' -exec md5sum {} \; > "$DEB_DIR/md5sums"

    package_name="zlib-ng_${REAL_VERSION}-${BUILD}_amd64.deb"
    cd "$WHEREAMI"
    dpkg-deb --build -Zxz -z9 -Sextreme --root-owner-group "$PKG_DIR" "${package_name}"
    
    package_location=$(find "$WHEREAMI" -name "$package_name")
    if [ -f "$package_location" ]; then
        echo "Package created at: $package_location"
    else
        echo "ERROR: Package not found."
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Sequential execution of builds
# -----------------------------------------------------------------------------
build_zlib_ng
package_zlib_ng_deb

echo "====> zlib-ng $FULL_VERSION has been built and packaged successfully."
