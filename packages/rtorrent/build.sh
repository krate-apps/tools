#!/usr/bin/env bash
set -e

# =============================================================================
# build_all.sh
#
# This script bundles the building of dependencies and rtorrent. 
#
# It performs:
# - Compilation/installation of libudns, xmlrpc-c, mktorrent, and libtorrent
# - Compilation of rtorrent with dual installation:
# - Live installation in the /opt/Krate/vendor/... prefix
# - Staging installation via DESTDIR for final packaging
#
# The final package will contain all components and include:
# - A generated md5sums file
# - RPATH via patchelf for dpkg-deb -x extraction (no apt postinst)
# - Optional UPX on vendor/usr/bin *after* patchelf (UPX before patchelf breaks patchelf)
#
# Usage:
# ./build_all.sh <VERSION_WITH_OPTIONAL_BUILD>
# Example:
# ./build_all.sh 0.13.8 or 0.14.0
#
# Notes:
# - For rtorrent 0.9.8, xmlrpc-c 1.59.4 is used. # - For rtorrent 0.14.0 or 0.15.1, xmlrpc-c 1.64.1 is used.
# - All configures use the following prefix:
# /opt/Krate/vendor/rtorrent_${RT_VER}
# =============================================================================

usage() {
    echo "Usage: $0 <VERSION_WITH_OPTIONAL_BUILD>"
    echo "Exemple: $0 0.9.8-1 ou 0.15.0"
    exit 1
}

if [ $# -ne 1 ]; then
    usage
fi

# -----------------------------------------------------------------------------
# 0) Parameter analysis and definition of global variables
# -----------------------------------------------------------------------------
INPUT_VERSION="$1"                           # Ex: "0.9.8" or "0.14.0"
REAL_VERSION="${INPUT_VERSION%%-*}"          # Ex: "0.9.8"
BUILD="${INPUT_VERSION#*-}"                  # Debian revision (default 1)
if [ "$BUILD" = "$REAL_VERSION" ]; then
    BUILD="1"
fi
FULL_VERSION="${REAL_VERSION}-${BUILD}"      # Ex: "0.9.8-1"

echo "====> Building rtorrent $REAL_VERSION (build: $BUILD)"
echo "====> Full version: $FULL_VERSION"

# Resolve tools root early (packages/rtorrent -> ../../.. = tools tree root)
WHEREAMI="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOLS_DIR="$WHEREAMI"
TOOLS_DIR_PACKAGE="$WHEREAMI/packages/rtorrent"
EXTRAS_DIR="$WHEREAMI/extras"

SKIP_XMLRPC_VERSION=false
# Pinned rTorrent / libtorrent tags only (no floating branches).
MINOR="$(echo "$REAL_VERSION" | cut -d'.' -f2)"
PATCH_VERSION="$(echo "$REAL_VERSION" | cut -d'.' -f3)"
case "$MINOR" in
    9)
        RT_VER="$INPUT_VERSION"
        LIBTORRENT_VERSION="0.13.8"
        FLTO=$(nproc)
        ;;
    10)
        RT_VER="$INPUT_VERSION"
        LIBTORRENT_VERSION="0.14.0"
        FLTO=$(nproc)
        ;;
    15)
        RT_VER="$INPUT_VERSION"
        LIBTORRENT_VERSION="$INPUT_VERSION"
        FLTO=$(nproc)
        if [ "${PATCH_VERSION:-0}" -ge 2 ]; then
            SKIP_XMLRPC_VERSION="true"
        fi
        ;;
    16)
        RT_VER="$INPUT_VERSION"
        LIBTORRENT_VERSION="$INPUT_VERSION"
        FLTO=$(nproc)
        SKIP_XMLRPC_VERSION="true"
        ;;
    *)
        echo "ERROR: Unrecognized version '$REAL_VERSION' (expected 0.9.x, 0.10.x, 0.15.x, or 0.16.x)."
        exit 1
        ;;
esac
if [ "$MINOR" -ge 15 ]; then
    XMLRPC_TINYXML="--with-xmlrpc-tinyxml2"
else
    XMLRPC_TINYXML="--with-xmlrpc-c"
fi
ARCHITECTURE="amd64"
BASE_DIR="$PWD/custom_build"
mkdir -p "$BASE_DIR"
INSTALL_DIR="$BASE_DIR/install"
mkdir -p "$INSTALL_DIR"
LIBTORRENT_PATCH_DIR="$EXTRAS_DIR/libtorrent-rakshasa"
RTORRENT_PATCH_DIR="$EXTRAS_DIR/rtorrent"
codename=$(lsb_release -cs)
distro=$(lsb_release -is | tr '[:upper:]' '[:lower:]')
os=$distro-$codename
export os

# -----------------------------------------------------------------------------
# 1) Dumptorrent build
# -----------------------------------------------------------------------------
build_dumptorrent() {
    echo "====> Building dumptorrent"
    local TMP_DIR
    TMP_DIR=$(mktemp -d)
    PKGFILE=$(find / -name "dumptorrent*.deb" | head -n 1)
    if [ -n "$PKGFILE" ]; then
        dpkg-deb -x "$PKGFILE" "$TMP_DIR"
        mkdir -p "$INSTALL_DIR/usr/bin"
        for file in "$TMP_DIR/usr/bin/"*; do
            if [ -f "$file" ]; then
                cp -p "$file" "$INSTALL_DIR/usr/bin/"
                chmod +x "$INSTALL_DIR/usr/bin/$(basename "$file")"
            fi
        done
        DUMPTORRENT_VERSION=$(basename "$PKGFILE" | sed -E 's/dumptorrent_([0-9]+)\.([0-9]+)(\.[0-9]+)?.*_amd64\.deb/\1.\2\3/')
        export DUMPTORRENT_VERSION
    else
        echo "ERROR: dumptorrent package not found"
        exit 1
    fi
    rm -rf "$TMP_DIR"
}

# -----------------------------------------------------------------------------
# 2) Libudns build
# -----------------------------------------------------------------------------
build_libudns() {
    echo "====> Building libudns"
    local TMP_DIR
    TMP_DIR=$(mktemp -d)
    PKGFILE=$(find / -name "libudns*.deb" | head -n 1)
    if [ -n "$PKGFILE" ]; then
        dpkg-deb -x "$PKGFILE" "$TMP_DIR"
        mkdir -p "$INSTALL_DIR/usr/bin" "$INSTALL_DIR/usr/include" "$INSTALL_DIR/usr/lib/x86_64-linux-gnu"
        cp -p "$TMP_DIR/usr/bin/dnsget" "$INSTALL_DIR/usr/bin/"
        cp -p "$TMP_DIR/usr/bin/rblcheck" "$INSTALL_DIR/usr/bin/"
        cp -p "$TMP_DIR/usr/include/udns.h" "$INSTALL_DIR/usr/include/"
        cp -p "$TMP_DIR/usr/lib/x86_64-linux-gnu/libudns.a" "$INSTALL_DIR/usr/lib/x86_64-linux-gnu/"
        cp -p "$TMP_DIR/usr/lib/x86_64-linux-gnu/libudns.so.0" "$INSTALL_DIR/usr/lib/x86_64-linux-gnu/"
        ln -sf libudns.so.0 "$INSTALL_DIR/usr/lib/x86_64-linux-gnu/libudns.so"
        LIBUDNS_VERSION=$(basename "$PKGFILE" | sed -E 's/libudns_([0-9]+)\.([0-9]+)(\.[0-9]+)?.*_amd64\.deb/\1.\2\3/')
        export LIBUDNS_VERSION
    else
        echo "ERROR: libudns package not found"
        exit 1
    fi
    rm -rf "$TMP_DIR"
}

# -----------------------------------------------------------------------------
# 3) xmlrpc-c build
# -----------------------------------------------------------------------------
build_xmlrpc() {
    echo "====> Building xmlrpc-c"
    local PKGFILE TMP_DIR
    PKGFILE="$(find "/" -name "libxmlrpc-c3*.deb" | head -n 1)"
    if [ -n "$PKGFILE" ]; then
        XMLRPC_VERSION="$(basename "$PKGFILE" | sed -E 's/libxmlrpc-c3_([0-9]+)\.([0-9]+)\.([0-9]+).*_amd64\.deb/\1.\2.\3/')"
        export XMLRPC_VERSION
    else
        export TINYXML2_USED="true"
    fi
}

# -----------------------------------------------------------------------------
# 4) mktorrent build
# -----------------------------------------------------------------------------
build_mktorrent() {
    echo "====> Building mktorrent"
    local TMP_DIR
    TMP_DIR=$(mktemp -d)
    PKGFILE=$(find / -name "mktorrent*.deb" | head -n 1)
    if [ -n "$PKGFILE" ]; then
        dpkg-deb -x "$PKGFILE" "$TMP_DIR"
        mkdir -p "$INSTALL_DIR/usr/bin"
        cp -p "$TMP_DIR/usr/bin/mktorrent" "$INSTALL_DIR/usr/bin/"
        if [ -f "$TMP_DIR/usr/share/man/man1/mktorrent.1" ]; then
            mkdir -p "$INSTALL_DIR/usr/share/man/man1"
            cp -p "$TMP_DIR/usr/share/man/man1/mktorrent.1" "$INSTALL_DIR/usr/share/man/man1/"
        fi
        MKTORRENT_VERSION=$(basename "$PKGFILE" | sed -E 's/mktorrent_([0-9]+)\.([0-9]+)(\.[0-9]+)?.*_amd64\.deb/\1.\2\3/')
        export MKTORRENT_VERSION
    else
        echo "ERROR: mktorrent package not found"
        exit 1
    fi
    rm -rf "$TMP_DIR"
}

# -----------------------------------------------------------------------------
# 5) check package versions
# -----------------------------------------------------------------------------
check_package_versions() {
    echo "====> Checking package versions"
    echo "====> LIBUDNS_VERSION: $LIBUDNS_VERSION"
    echo "====> XMLRPC_VERSION: $XMLRPC_VERSION"
    echo "====> MKTORRENT_VERSION: $MKTORRENT_VERSION"
    echo "====> DUMPTORRENT_VERSION: $DUMPTORRENT_VERSION"
    if [ -z "$LIBUDNS_VERSION" ] || [ -z "$MKTORRENT_VERSION" ] || [ -z "$DUMPTORRENT_VERSION" ]; then
        echo "ERROR: Unknown package version."
        exit 1
    fi
    if [ "$SKIP_XMLRPC_VERSION" = true ]; then
        echo "====> Skipping XMLRPC version check"
    elif [ -z "$XMLRPC_VERSION" ]; then
            echo "ERROR: Unknown XMLRPC version."
            exit 1
    fi
}

# -----------------------------------------------------------------------------
# 6) libtorrent (rakshasa) build
# -----------------------------------------------------------------------------
build_libtorrent() {
    echo "====> Building libtorrent (version $LIBTORRENT_VERSION)"
    local GIT_REPO_URL SRC_DIR TMP_DIR
    TMP_DIR=$(mktemp -d)
    GIT_REPO_URL="https://github.com/rakshasa/libtorrent.git"
    SRC_DIR="$BASE_DIR/libtorrent-rakshasa-$LIBTORRENT_VERSION"
    rm -rf "$SRC_DIR"
    git clone --depth 1 --branch "v${LIBTORRENT_VERSION}" "$GIT_REPO_URL" "$SRC_DIR"
    cd "$SRC_DIR"
    git --no-pager log -1 --oneline
    if [ "$LIBTORRENT_VERSION" = "0.13.8" ]; then
        echo "Applying patches for libtorrent 0.13.8..."
        for patch in udns scanf lookup-cache; do
            if [ -f "$LIBTORRENT_PATCH_DIR/${patch}-0.13.8.patch" ]; then
                patch -p1 --fuzz=3 --ignore-whitespace --verbose --unified < "$LIBTORRENT_PATCH_DIR/${patch}-0.13.8.patch" || true
            fi
        done
    fi
    if [ -f ./autogen.sh ]; then
        if ! grep -q "AC_CONFIG_MACRO_DIRS" configure.ac; then
            sed -i '2iAC_CONFIG_MACRO_DIRS([scripts])' configure.ac
        fi
        ./autogen.sh
    else
        wget -O autogen.sh 'https://github.com/rakshasa/libtorrent/blob/2ce482a3bea8a5f051d2595fad5a1d19c6f10471/autogen.sh?raw=true'
        chmod +x autogen.sh
        ./autogen.sh
    fi
    autoreconf -vfi
    ./configure \
        --disable-debug \
        --with-posix-fallocate \
        --enable-aligned \
        --enable-static \
        --disable-shared
    make -j"$FLTO"
    make install DESTDIR="$TMP_DIR"
    cp -pR "$TMP_DIR/usr/"* "/usr/"
    cd "$WHEREAMI"
}

# -----------------------------------------------------------------------------
# 7) rtorrent build
# -----------------------------------------------------------------------------
build_rtorrent() {
    echo "====> Building rtorrent"
    local GIT_REPO_URL SRC_DIR mem_available_kb mem_available_mb rtorrent_level rtorrent_flto rtorrent_pipe rtorrent_profile TMP_DIR
    TMP_DIR=$(mktemp -d)
    GIT_REPO_URL="https://github.com/rakshasa/rtorrent.git"
    SRC_DIR="$BASE_DIR/rtorrent-$REAL_VERSION"
    rm -rf "$SRC_DIR"
    git clone --depth 1 --branch "v$RT_VER" "$GIT_REPO_URL" "$SRC_DIR"
    cd "$SRC_DIR"
    git --no-pager log -1 --oneline
    export CFLAGS="-Os -DNDEBUG -g0 -ffunction-sections -fdata-sections"
    export LDFLAGS="-Wl,--gc-sections -s -lssl -lcrypto -lz"
    export LIBS="$LIBS -lssl -lcrypto -lz"
    if [[ "$(printf '%s\n' "$REAL_VERSION" "0.15.2" | sort -V | head -n1)" = "$REAL_VERSION" ]] && [ "$REAL_VERSION" != "0.15.2" ]; then
        echo "Applying patches for rtorrent $REAL_VERSION..."
        for patch in fast-session-loading lockfile lockfile rtorrent-ml rtorrent-scrape scgi session-file; do
            if [ -f "$RTORRENT_PATCH_DIR/${patch}-0.9.8.patch" ]; then
                patch -p1 --fuzz=3 --ignore-whitespace --verbose --unified < "$RTORRENT_PATCH_DIR/${patch}-${REAL_VERSION}.patch" || true
            fi
        done
        if [ "$XMLRPC_VERSION" == "1.59.04" ]; then
            for patch in xmlrpc-fix xmlrpc-logic; do
                if [ -f "$RTORRENT_PATCH_DIR/${patch}-0.9.8.patch" ]; then
                    patch -p1 --fuzz=3 --ignore-whitespace --verbose --unified < "$RTORRENT_PATCH_DIR/${patch}-0.9.8.patch" || true
                fi
            done
        fi
    fi
    [[ -f ./autogen.sh ]] && ./autogen.sh || true
    autoreconf -vfi
    ./configure --with-ncursesw $XMLRPC_TINYXML
    mem_available_kb=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
    mem_available_mb=$((mem_available_kb / 1024))
    rtorrent_level=""
    rtorrent_flto=""
    rtorrent_pipe=""
    # Do not use -fprofile-use unless PGO data exists (requires a prior -fprofile-generate build).
    rtorrent_profile="${RTORRENT_PROFILE_FLAGS:-}"
    case "$FLTO" in
        1)
            rtorrent_level="-O1"
        ;;
        [2-3])
            rtorrent_level="-O2"
        ;;
        [4-7])
            rtorrent_level="-O2"
            rtorrent_flto="-flto=$FLTO"
        ;;
        *)
            rtorrent_level="-O3"
            rtorrent_flto="-flto=$FLTO"
        ;;
    esac
    # Parallel LTO during the final link is memory-heavy; uncapped -flto=$(nproc) often hits GHA timeouts.
    if [ -n "$rtorrent_flto" ] && [ -n "${GITHUB_ACTIONS:-}" ]; then
        _lto_jobs="${RTORRENT_LTO_JOBS:-4}"
        rtorrent_flto="-flto=$_lto_jobs"
    fi
    if [ "$mem_available_mb" -gt 512 ]; then
        rtorrent_pipe="-pipe"
    fi
    make -j"$FLTO" CXXFLAGS="-w $rtorrent_level $rtorrent_flto $rtorrent_pipe $rtorrent_profile"
    make install DESTDIR="$TMP_DIR"
    cp -pR "$TMP_DIR/"* "$INSTALL_DIR/"
    find "$INSTALL_DIR" -type f -exec file {} \; | grep ELF | cut -d: -f1 | while read -r file; do
        if [ -f "$file" ] && [ -x "$file" ]; then
            strip --strip-unneeded "$file" 2>/dev/null || true
            # UPX must run after patchelf on the final vendor tree (see package_rtorrent_deb); packed ELFs break patchelf.
        fi
        if [ -f "$file" ] && [ -x "$file" ] && [[ "$file" == *"/usr/local/bin/"* ]]; then
            cp -p "$file" "$INSTALL_DIR/usr/bin/"
        fi
        filename="$(basename "$file")"
        if [[ "$filename" != *.so* ]]; then
            chmod +x "$INSTALL_DIR/usr/bin/$filename"
        fi
    done
    rm -rf "$INSTALL_DIR/usr/local/bin"
    find "$INSTALL_DIR" -type d -empty -delete
    cd "$WHEREAMI"
}

# -----------------------------------------------------------------------------
# 7b) patchelf + ldd guard (vendor bundle extracted via dpkg-deb -x, no LD_LIBRARY_PATH)
# -----------------------------------------------------------------------------
krate_ensure_patchelf() {
    if command -v patchelf >/dev/null 2>&1; then
        return 0
    fi
    if command -v sudo >/dev/null 2>&1 && [ "$(id -u)" -ne 0 ]; then
        sudo apt-get update -qq && sudo apt-get install -y patchelf
    else
        apt-get update -qq && apt-get install -y patchelf
    fi
}

krate_apply_rtorrent_rpath() {
    local prefix="$1"
    krate_ensure_patchelf
    if [ ! -d "$prefix/usr/lib/x86_64-linux-gnu" ]; then
        echo "WARN: no usr/lib/x86_64-linux-gnu under prefix; skipping patchelf"
        return 0
    fi
    echo "====> Applying RPATH (patchelf) under $prefix"
    while IFS= read -r -d '' exe; do
        file "$exe" | grep -q 'ELF' || continue
        # Prebuilt tools (e.g. mktorrent/dumptorrent from third-party .deb) are often UPX-packed;
        # `file` reports "statically linked, self-decompressing" and patchelf cannot edit them.
        if ! file "$exe" | grep -Fq 'dynamically linked'; then
            echo "WARN: skip patchelf (not a dynamically linked ELF, e.g. UPX): $exe"
            continue
        fi
        patchelf --set-rpath '$ORIGIN/../lib/x86_64-linux-gnu' "$exe"
    done < <(find "$prefix/usr/bin" -type f -print0 2>/dev/null || true)
    while IFS= read -r -d '' so; do
        file "$so" | grep -q 'ELF' || continue
        if ! file "$so" | grep -Fq 'dynamically linked'; then
            continue
        fi
        patchelf --set-rpath '$ORIGIN' "$so" || true
    done < <(find "$prefix/usr/lib/x86_64-linux-gnu" -name '*.so*' -type f -print0 2>/dev/null || true)
}

krate_verify_rtorrent_vendor_ldd() {
    local prefix="$1"
    local fail=0
    # Allow any soname resolved under distro multiarch dirs (/lib, /usr/lib). libcurl/rtorrent pull many
    # transitive libs (nghttp2, brotli, krb5, …) — enumerating them is brittle; we only ensure nothing
    # resolves outside standard trees (and bundle paths under $prefix are ignored above).
    local wl='^(/lib|/usr/lib|/lib64)(/x86_64-linux-gnu)?/[^/]+\.so(\.[0-9]+)*$'
    echo "====> Verifying bundled binaries link only distro paths for NEEDED (under /lib, /usr/lib)"
    while IFS= read -r -d '' bin; do
        file "$bin" | grep -q ELF || continue
        # Same as patchelf: ldd is meaningless on UPX/static stubs bundled under usr/bin.
        file "$bin" | grep -Fq 'dynamically linked' || continue
        while IFS= read -r path; do
            [ -z "$path" ] && continue
            case "$path" in
                "$prefix"*) continue ;;
            esac
            if ! echo "$path" | grep -qE "$wl"; then
                echo "FAIL: $bin -> unexpected NEEDED path: $path" >&2
                fail=1
            fi
        done < <(LD_LIBRARY_PATH= ldd "$bin" 2>/dev/null | awk '/=>/ {print $3}' | grep '^/' || true)
    done < <(find "$prefix/usr/bin" -type f -print0 2>/dev/null || true)
    if [ "$fail" -ne 0 ]; then
        echo "ERROR: LDD verification failed (adjust whitelist or fix RPATH)."
        exit 1
    fi
}

# Run after patchelf + ldd; UPX-packed binaries are not modifiable by patchelf.
krate_upx_rtorrent_vendor_executables() {
    local prefix="$1"
    if [ "${RTORRENT_SKIP_UPX:-0}" = "1" ]; then
        echo "====> RTORRENT_SKIP_UPX=1; skipping UPX"
        return 0
    fi
    if ! command -v upx >/dev/null 2>&1; then
        return 0
    fi
    echo "====> UPX (after RPATH) under $prefix/usr/bin"
    while IFS= read -r -d '' exe; do
        file "$exe" | grep -q 'ELF.*executable' || continue
        upx --best --lzma "$exe" 2>/dev/null || true
    done < <(find "$prefix/usr/bin" -type f -print0 2>/dev/null || true)
}

# -----------------------------------------------------------------------------
# 8) Final packaging
# -----------------------------------------------------------------------------
package_rtorrent_deb() {
    set -e
    echo "====> Packaging rtorrent to .deb file"
    local PKG_DIR
    PKG_DIR="$BASE_DIR/pkg_rtorrent"
    DEB_DIR="$PKG_DIR/DEBIAN"
    rm -rf "$PKG_DIR"
    mkdir -p "$DEB_DIR"
    mkdir -p "$PKG_DIR/opt/Krate/vendor/rtorrent_${RT_VER}/"
    rsync -a "$INSTALL_DIR/" "$PKG_DIR/opt/Krate/vendor/rtorrent_${RT_VER}/"
    if [ -z "$(ls -A "$PKG_DIR/opt/Krate/vendor/rtorrent_${RT_VER}/")" ]; then
        echo "ERROR: $PKG_DIR/opt/Krate/vendor/rtorrent_${RT_VER}/ is empty."
        exit 1
    fi
    local vendor_prefix="$PKG_DIR/opt/Krate/vendor/rtorrent_${RT_VER}"
    krate_apply_rtorrent_rpath "$vendor_prefix"
    krate_verify_rtorrent_vendor_ldd "$vendor_prefix"
    krate_upx_rtorrent_vendor_executables "$vendor_prefix"

    echo "====> Copying control file"
    cp -pr "$TOOLS_DIR_PACKAGE/control" "$DEB_DIR/control"
    echo "====> Setting control file values"
    if [ "$TINYXML2_USED" == true ]; then
        VERSION="$(dpkg-query -W -f='${Version}' tinyxml2 2>/dev/null || echo 'unknown')"
        TINY_OR_XMLRPC="tinyxml2 ($VERSION)"
    else
        TINY_OR_XMLRPC="xmlrpc-c ($XMLRPC_VERSION)"
    fi
    sed -i \
        -e "s|@REVISION@|${BUILD}|g" \
        -e "s|@ARCHITECTURE@|${ARCHITECTURE}|g" \
        -e "s|@VERSION@|${REAL_VERSION}|g" \
        -e "s|@DATE@|$(date +%Y-%m-%d)|g" \
        -e "s|@LIBTORRENT_VERSION@|${LIBTORRENT_VERSION}|g" \
        -e "s|@TINY_OR_XMLRPC@|${TINY_OR_XMLRPC}|g" \
        -e "s|@MKTORRENT_VERSION@|${MKTORRENT_VERSION}|g" \
        -e "s|@LIBUDNS_VERSION@|${LIBUDNS_VERSION}|g" \
        -e "s|@DUMPTORRENT_VERSION@|${DUMPTORRENT_VERSION}|g" \
        -e "s|@SIZE@|$(du -s -k "$PKG_DIR/opt" | cut -f1)|g" \
        "$DEB_DIR/control"
    cat "$DEB_DIR/control"
    echo "====> Generating md5sums"
    find "$PKG_DIR" -type f ! -path './DEBIAN/*' -exec md5sum {} \; > "$DEB_DIR/md5sums"
    package_name="krate-rtorrent_${REAL_VERSION}-${BUILD}_amd64.deb"
    cd "$WHEREAMI"
    dpkg-deb --build -Zxz -z9 -Sextreme --root-owner-group "$PKG_DIR" "${package_name}"
    package_location=$(find "$WHEREAMI" -name "$package_name")
    if [ -f "$package_location" ]; then
        echo "Package created at: $package_location"
    else
        echo "ERROR: Package not found."
        exit 1
    fi
    set +e
}

# -----------------------------------------------------------------------------
# Sequential execution of builds
# -----------------------------------------------------------------------------
build_dumptorrent
build_libudns
build_xmlrpc
build_mktorrent
check_package_versions
build_libtorrent
build_rtorrent
package_rtorrent_deb

echo "====> rtorrent $FULL_VERSION has been built and packaged successfully."
