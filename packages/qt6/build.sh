#!/usr/bin/env bash
set -e

# =============================================================================
# build.sh
#
# This script handles the building of Qt6 components (QtBase and QtTools).
#
# It performs:
# - Download and compilation of QtBase
# - Download and compilation of QtTools
# - Staging installation via DESTDIR for final packaging
#
# The final package will contain all components and include:
# - A generated md5sums file
#
# Usage:
# ./build.sh <VERSION>
# Example:
# ./build.sh 6.4.3 or 6.5.2 or 6.8.0
# =============================================================================

usage() {
    echo "Usage: $0 <VERSION>"
    echo "Example: $0 6.4.3"
    exit 1
}

if [ $# -ne 1 ]; then
    usage
fi

# -----------------------------------------------------------------------------
# 0) Parameter analysis and definition of global variables
# -----------------------------------------------------------------------------
INPUT_VERSION="$1"                           # Ex: "6.4.3"
REAL_VERSION="${INPUT_VERSION%%-*}"          # Ex: "6.4.3"
BUILD="1"
FULL_VERSION="${REAL_VERSION}-${BUILD}"

echo "====> Building Qt6 $REAL_VERSION (build: $BUILD)"
echo "====> Full version: $FULL_VERSION"

QT_VER="$INPUT_VERSION"
MAJOR="$(echo "$REAL_VERSION" | cut -d'.' -f1)"
MINOR="$(echo "$REAL_VERSION" | cut -d'.' -f2)"
PATCH="$(echo "$REAL_VERSION" | cut -d'.' -f3)"

if [ "$MAJOR" != "6" ]; then
    echo "ERROR: Only Qt6 is supported"
    exit 1
fi

# Get the absolute path to the tools directory
WHEREAMI="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOLS_DIR_PACKAGE="$WHEREAMI/packages/qt6"
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
# 1) QtBase build
# -----------------------------------------------------------------------------
build_qtbase() {
    echo "====> Building QtBase"
    local GIT_REPO_URL SRC_DIR TMP_DIR
    TMP_DIR=$(mktemp -d)
    GIT_REPO_URL="https://download.qt.io/official_releases/qt/${MAJOR}.${MINOR}/${QT_VER}/submodules/qtbase-everywhere-src-${QT_VER}.tar.xz"
    if [ "$QT_VER" == "6.5.5" ]; then
        GIT_REPO_URL="https://download.qt.io/official_releases/qt/${MAJOR}.${MINOR}/${QT_VER}/src/submodules/qtbase-everywhere-opensource-src-${QT_VER}.tar.xz"
    fi
    SRC_DIR="$BASE_DIR/qtbase-everywhere-src-$QT_VER"
    rm -rf "$SRC_DIR"
    
    echo "====> Downloading QtBase"
    echo "====> GIT_REPO_URL: $GIT_REPO_URL"
    curl -NL "$GIT_REPO_URL" -o qtbase.tar.xz
    tar xf qtbase.tar.xz -C "$BASE_DIR"
    cd "$SRC_DIR"

    # Configure and build using cmake
    cmake -Wno-dev -Wno-deprecated -G Ninja -B build \
        -D CMAKE_BUILD_TYPE="release" \
        -D CMAKE_CXX_FLAGS="-lstdc++fs -O3 -march=x86-64-v3 -fno-plt -flto=auto" \
        -D CMAKE_EXE_LINKER_FLAGS="-lstdc++fs -Wl,--as-needed -Wl,-O2" \
        -D QT_FEATURE_optimize_full=on \
        -D QT_FEATURE_optimize_size=on \
        -D QT_FEATURE_ltcg=on \
        -D QT_FEATURE_precompile_header=on \
        -D QT_FEATURE_ccache=on \
        -D QT_FEATURE_glib=OFF \
        -D QT_FEATURE_gui=off \
        -D QT_FEATURE_openssl_linked=on \
        -D QT_FEATURE_dbus=on \
        -D QT_FEATURE_system_pcre2=off \
        -D QT_FEATURE_widgets=off \
        -D FEATURE_androiddeployqt=OFF \
        -D FEATURE_animation=OFF \
        -D QT_FEATURE_testlib=off \
        -D QT_BUILD_EXAMPLES=off \
        -D QT_BUILD_TESTS=off \
        -D QT_BUILD_EXAMPLES_BY_DEFAULT=OFF \
        -D QT_BUILD_TESTS_BY_DEFAULT=OFF \
        -D QT_FEATURE_system_harfbuzz=off \
        -D QT_FEATURE_system_freetype=off \
        -D QT_FEATURE_zstd=off \
        -D QT_FEATURE_sanitize_fuzzer_no_link=off \
        -D CMAKE_CXX_STANDARD=17 \
        -D CMAKE_INSTALL_PREFIX=/usr

    cmake --build build --parallel $(nproc)
    DESTDIR="$TMP_DIR" cmake --install build
        
    # Optimize binaries
    echo "====> Optimizing QtBase binaries"
    find "$TMP_DIR" -type f -exec file {} \; | grep ELF | cut -d: -f1 | while read -r file; do
        if [ -f "$file" ] && [ -x "$file" ]; then
            strip --strip-unneeded "$file" 2>/dev/null || true
            if file "$file" | grep -q "ELF.*executable" && command -v upx >/dev/null 2>&1; then
                upx --best --lzma "$file" 2>/dev/null || true
            fi
        fi
    done

    # Copy files to install directory
    cp -pR "$TMP_DIR/"* "$INSTALL_DIR/"
    cp -pR "$TMP_DIR/usr/"* "/usr/"

    cd "$WHEREAMI"
    rm -rf "$TMP_DIR" qtbase.tar.xz
}

# -----------------------------------------------------------------------------
# 2) QtTools build
# -----------------------------------------------------------------------------
build_qttools() {
    echo "====> Building QtTools"
    local GIT_REPO_URL SRC_DIR TMP_DIR
    TMP_DIR=$(mktemp -d)
    GIT_REPO_URL="https://download.qt.io/official_releases/qt/${MAJOR}.${MINOR}/${QT_VER}/submodules/qttools-everywhere-src-${QT_VER}.tar.xz"
    if [ "$QT_VER" == "6.5.5" ]; then
        GIT_REPO_URL="https://download.qt.io/official_releases/qt/${MAJOR}.${MINOR}/${QT_VER}/src/submodules/qttools-everywhere-opensource-src-${QT_VER}.tar.xz"
    fi
    SRC_DIR="$BASE_DIR/qttools-everywhere-src-$QT_VER"
    rm -rf "$SRC_DIR"
    
    echo "====> Downloading QtTools"
    echo "====> GIT_REPO_URL: $GIT_REPO_URL"
    curl -NL "$GIT_REPO_URL" -o qttools.tar.xz
    tar xf qttools.tar.xz -C "$BASE_DIR"
    cd "$SRC_DIR"

    # Configure and build using cmake
    cmake -Wno-dev -Wno-deprecated -G Ninja -B build \
        -D CMAKE_BUILD_TYPE="release" \
        -D CMAKE_CXX_STANDARD=17 \
        -D CMAKE_PREFIX_PATH="$INSTALL_DIR/usr" \
        -D CMAKE_INSTALL_PREFIX=/usr

    cmake --build build --parallel $(nproc)
    DESTDIR="$TMP_DIR" cmake --install build
    
    # Optimize binaries
    echo "====> Optimizing QtTools binaries"
    find "$TMP_DIR" -type f -exec file {} \; | grep ELF | cut -d: -f1 | while read -r file; do
        if [ -f "$file" ] && [ -x "$file" ]; then
            strip --strip-unneeded "$file" 2>/dev/null || true
            if file "$file" | grep -q "ELF.*executable" && command -v upx >/dev/null 2>&1; then
                upx --best --lzma "$file" 2>/dev/null || true
            fi
        fi
    done

    cp -pR "$TMP_DIR/"* "$INSTALL_DIR/"
    cp -pR "$TMP_DIR/usr/"* "/usr/"

    cd "$WHEREAMI"
    rm -rf "$TMP_DIR" qtbase.tar.xz
}

# -----------------------------------------------------------------------------
# 3) Final packaging
# -----------------------------------------------------------------------------
package_qt6_deb() {
    echo "====> Packaging Qt6 to .deb file"
    local PKG_DIR
    PKG_DIR="$BASE_DIR/pkg_qt6"
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

    package_name="qt6_${REAL_VERSION}-${BUILD}_amd64.deb"
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
build_qtbase
build_qttools
package_qt6_deb

echo "====> Qt6 $FULL_VERSION has been built and packaged successfully." 
