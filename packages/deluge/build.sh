#!/usr/bin/env bash
set -e

# =============================================================================
# build.sh
#
# This script compiles Deluge statically in command-line mode
# for use on a dedicated server
#
# Usage:
# ./build.sh <VERSION>
# Example:
# ./build.sh 2.1.1
#
# Notes:
# - Supported versions: 2.1.1, 2.2.0 (pinned upstream tags)
# =============================================================================

usage() {
    echo "Usage: $0 <VERSION>"
    echo "Example: $0 2.1.1"
    echo "Supported versions: 2.1.1, 2.2.0"
    exit 1
}

if [ $# -ne 1 ]; then
    usage
fi
INPUT_VERSION="$1"

# -----------------------------------------------------------------------------
# 0) Parameters and global variables
# -----------------------------------------------------------------------------
DELUGE_VERSION="${INPUT_VERSION}"
BUILD="1"
CREATE_DEB="true"
case "$DELUGE_VERSION" in
    "2.1.1") LIBTORRENT_VERSION="${LIBTORRENT_VERSION:-2.0.11}"; GIT_REF="deluge-2.1.1" ;;
    "2.2.0") LIBTORRENT_VERSION="${LIBTORRENT_VERSION:-2.0.11}"; GIT_REF="deluge-2.2.0" ;;
    *) echo "ERROR: Unsupported version: $DELUGE_VERSION"; exit 1 ;;
esac
BOOST_VERSION="${BOOST_VERSION:-1.91.0}"
DEB_UPSTREAM_VERSION="$DELUGE_VERSION"
FULL_VERSION="${DEB_UPSTREAM_VERSION}-${BUILD}"

echo "====> Building Deluge $DELUGE_VERSION (build: $BUILD)"
echo "====> Debian upstream version: $DEB_UPSTREAM_VERSION (full: $FULL_VERSION)"
echo "====> Build mode: CLI/Web only (server mode)"
echo "====> Using libtorrent: $LIBTORRENT_VERSION"
echo "====> Using Boost: $BOOST_VERSION"
WHEREAMI="$(dirname "$(readlink -f "$0")")"
PREFIX="/usr"
BASE_DIR="$PWD/custom_build"
mkdir -p "$BASE_DIR"
INSTALL_DIR="$BASE_DIR/install"
mkdir -p "$INSTALL_DIR"
ARCHITECTURE=$(dpkg --print-architecture)
PYTHON_VERSION="3"
PYTHON_CMD="python${PYTHON_VERSION}"
# Keep LIBTORRENT_VERSION from env/matrix (e.g. 2.0.11). lt.version (e.g. 2.0.11.0) breaks INSTALL_PATH and .deb globs.

# -----------------------------------------------------------------------------
# 1) Download and build Deluge
# -----------------------------------------------------------------------------
build_deluge() {
    echo "====> Downloading and building Deluge $DELUGE_VERSION"
    local SRC_DIR="$BASE_DIR/deluge-$DELUGE_VERSION"
    echo "====> Cleaning any existing Deluge directories"
    cd "$BASE_DIR"
    rm -rf deluge-*
    echo "====> Downloading Deluge (ref: $GIT_REF)"
    git clone --recurse-submodules --branch "$GIT_REF" https://github.com/deluge-torrent/deluge.git "$SRC_DIR"
    cd "$SRC_DIR"
    git fetch --tags
    git --no-pager log -1 --oneline
    echo "====> Installing Deluge"
    codename=$(lsb_release -cs)
    python_version=$(${PYTHON_CMD} --version 2>&1 | grep -oP 'Python \K[0-9]+\.[0-9]+')
    echo "====> Detected Python version: $python_version on $codename"
    packages=("pyopenssl" "service_identity" "pillow" "rencode" "pyxdg" "chardet" "setproctitle" "wheel" "cryptography")
    is_modern_os=false
    case "$codename" in
        buster|focal) 
            is_modern_os=false
            ;;
        bullseye|bookworm|jammy|noble|*) 
            is_modern_os=true
            packages+=("twisted")
            ;;
    esac
    echo "====> Installing Python packages: ${packages[*]}"
    break_system=""
    if $is_modern_os && python3 -m pip --version | grep -q "pip 2[3-9]"; then
        echo "====> Using --break-system-packages for modern pip"
        break_system="--break-system-packages"
    fi
    echo "====> Creating Python virtualenv"
    VENV_DIR="$BASE_DIR/venv"
    python3 -m venv "$VENV_DIR"
    source "$VENV_DIR/bin/activate"
    echo "====> Installing dependencies in venv"
    for pkg in "${packages[@]}"; do
        echo "====> Installing $pkg"
        ${PYTHON_CMD} -m pip install "$pkg" $break_system
    done
    echo "====> Installing tox"
    ${PYTHON_CMD} -m pip install tox $break_system
    ${PYTHON_CMD} -m pip install --upgrade pip setuptools wheel $break_system
    # pip 25+ removed --install-layout=deb; install to usr/lib/python3.N/site-packages (KRATE handler path).
    echo "====> Installing Deluge into ${INSTALL_DIR}${PREFIX}"
    ${PYTHON_CMD} -m pip install . --root="$INSTALL_DIR" --prefix="$PREFIX" $break_system --no-build-isolation
    echo "====> Bundling setuptools (pkg_resources) into vendor site-packages"
    ${PYTHON_CMD} -m pip install 'setuptools>=61,<82' --root="$INSTALL_DIR" --prefix="$PREFIX" $break_system --no-build-isolation
    if [[ ! -x "${INSTALL_DIR}${PREFIX}/bin/deluged" ]]; then
        echo "====> ERROR: deluged not installed under ${INSTALL_DIR}${PREFIX}/bin"
        exit 1
    fi
    deactivate
    cd "$WHEREAMI"
}

# -----------------------------------------------------------------------------
# 2) Create the package
# -----------------------------------------------------------------------------
create_package() {
    echo "====> Creating Deluge package"
    files=("deluged" "deluge-web" "deluge-console" "deluge-gtk" "deluge")
    mkdir -p "$WHEREAMI/output"
    # Do not use loop name `file`: it shadows the `file(1)` utility and breaks `file "$path"`.
    for fname in "${files[@]}"; do
        found=$(find "$INSTALL_DIR$PREFIX/bin" -name "$fname" -type f | head -n1)
        if [ -n "$found" ]; then
            echo "====> Found $fname at $found"
            command -v file >/dev/null 2>&1 && file "$found" || ls -l "$found"
            chmod +x "$found"
            cp "$found" "$WHEREAMI/output/"
        else
            found=$(find "$INSTALL_DIR" -name "$fname" -type f | head -n1)
            if [ -n "$found" ]; then
                echo "====> Found $fname at $found (alternative location)"
                command -v file >/dev/null 2>&1 && file "$found" || ls -l "$found"
                chmod +x "$found"
                cp "$found" "$WHEREAMI/output/"
            else
                echo "====> ERROR: $fname not found in installation directory"
                echo "====> WARNING: Continuing without $fname"
            fi
        fi
    done
    essential_files=("deluged" "deluge-web" "deluge-console")
    missing=0
    for efile in "${essential_files[@]}"; do
        if [ ! -f "$WHEREAMI/output/$efile" ]; then
            echo "====> ERROR: Essential file $efile is missing"
            missing=1
        fi
    done
    if [ $missing -eq 1 ]; then
        echo "====> ERROR: Some essential files are missing, cannot continue"
    fi
    if [ -n "$CREATE_DEB" ] && [ "$CREATE_DEB" = "true" ]; then
        echo "====> Creating Debian package"
        local LIBTORRENT_DEB PYTHON_LIBTORRENT_DEB BOOST_DEB PACKAGE_NAME INSTALL_PATH libtorrent_files INSTALLED_SIZE PKG_DIR os_name codename os vendor_libdir
        PKG_DIR="$BASE_DIR/deb-pkg"
        # CI downloads .debs to workspace root (step runs before `cd tools/packages/deluge`). Never `find /`.
        local _deb_roots _workspace_root _repo_root_extra
        _workspace_root="$(cd "$WHEREAMI/../../.." && pwd 2>/dev/null || true)"
        _repo_root_extra="$(cd "$WHEREAMI/../../../.." && pwd 2>/dev/null || true)"
        _deb_roots=( "${GITHUB_WORKSPACE:-}" "$_workspace_root" "$_repo_root_extra" "$PWD" /tmp )
        LIBTORRENT_DEB=""
        PYTHON_LIBTORRENT_DEB=""
        BOOST_DEB=""
        for _root in "${_deb_roots[@]}"; do
            [ -z "$_root" ] || [ ! -d "$_root" ] && continue
            [ -z "$LIBTORRENT_DEB" ] && LIBTORRENT_DEB=$(find "$_root" -maxdepth 12 -type f \( -name 'krate-libtorrent-rasterbar_*.deb' ! -name '*rasterbar-dev*' \) 2>/dev/null | head -1)
            [ -z "$PYTHON_LIBTORRENT_DEB" ] && PYTHON_LIBTORRENT_DEB=$(find "$_root" -maxdepth 12 -type f -name 'krate-python3-libtorrent_*.deb' 2>/dev/null | head -1)
            [ -z "$BOOST_DEB" ] && BOOST_DEB=$(find "$_root" -maxdepth 12 -type f -name "libboost-all-dev_${BOOST_VERSION}*.deb" 2>/dev/null | head -1)
            [ -n "$LIBTORRENT_DEB" ] && [ -n "$PYTHON_LIBTORRENT_DEB" ] && [ -n "$BOOST_DEB" ] && break
        done
        if [ -z "$LIBTORRENT_DEB" ]; then
            for _root in "${_deb_roots[@]}"; do
                [ -z "$_root" ] || [ ! -d "$_root" ] && continue
                LIBTORRENT_DEB=$(find "$_root" -maxdepth 12 -type f -name 'libtorrent-rasterbar_*.deb' 2>/dev/null | head -1)
                [ -n "$LIBTORRENT_DEB" ] && break
            done
        fi
        if [ -z "$PYTHON_LIBTORRENT_DEB" ]; then
            for _root in "${_deb_roots[@]}"; do
                [ -z "$_root" ] || [ ! -d "$_root" ] && continue
                PYTHON_LIBTORRENT_DEB=$(find "$_root" -maxdepth 12 -type f \( -name 'python3-libtorrent_*.deb' -o -name 'krate-python3-libtorrent_*.deb' \) 2>/dev/null | head -1)
                [ -n "$PYTHON_LIBTORRENT_DEB" ] && break
            done
        fi
        echo "====> Vendor .deb paths: LIBTORRENT_DEB=${LIBTORRENT_DEB:-<none>} PYTHON_LIBTORRENT_DEB=${PYTHON_LIBTORRENT_DEB:-<none>} BOOST_DEB=${BOOST_DEB:-<none>}"
        os_name=$(lsb_release -is | tr '[:upper:]' '[:lower:]')
        codename=$(lsb_release -cs)
        os="${os_name}-${codename}"
        PACKAGE_NAME="krate-deluge_${DEB_UPSTREAM_VERSION}-${BUILD}_amd64.deb"
        INSTALL_PATH="/opt/Krate/vendor/deluge_${DELUGE_VERSION}_lt_${LIBTORRENT_VERSION}"
        rm -rf "$PKG_DIR"
        mkdir -p "$PKG_DIR/DEBIAN"
        mkdir -p "$PKG_DIR/usr/share/krate/apt-preferences"
        mkdir -p "$PKG_DIR/$INSTALL_PATH"
        cp -r "$INSTALL_DIR$PREFIX" "$PKG_DIR/$INSTALL_PATH/"
        cp -pr "$WHEREAMI/apt-preferences.pref" "$PKG_DIR/usr/share/krate/apt-preferences/deluge.pref"
        vendor_libdir="$PKG_DIR/$INSTALL_PATH/usr/lib/x86_64-linux-gnu"
        mkdir -p "$vendor_libdir"
        for deb in "$LIBTORRENT_DEB" "$PYTHON_LIBTORRENT_DEB"; do
            if [ -f "$deb" ]; then
                echo "====> Extracting $deb"
                local temp_extract
                temp_extract=$(mktemp -d)
                dpkg-deb -x "$deb" "$temp_extract"
                rm -rf "$temp_extract/DEBIAN"
                if [ -d "$temp_extract/usr" ]; then
                    cp -r "$temp_extract/usr"/* "$PKG_DIR/$INSTALL_PATH/usr/"
                fi
                rm -rf "$temp_extract"
            else
                echo "====> WARNING: vendor .deb missing or not a file: ${deb:-<empty path>}, skipping"
            fi
        done
        # python3-libtorrent links libboost_python*.so; bundle Boost runtime from boost-builds.
        if [ -f "$BOOST_DEB" ]; then
            echo "====> Bundling Boost shared libs from $BOOST_DEB"
            temp_extract=$(mktemp -d)
            dpkg-deb -x "$BOOST_DEB" "$temp_extract"
            if [ -d "$temp_extract/usr/lib/x86_64-linux-gnu" ]; then
                cp -a "$temp_extract/usr/lib/x86_64-linux-gnu"/libboost_*.so* "$vendor_libdir/" 2>/dev/null || true
            fi
            rm -rf "$temp_extract"
        elif [ -d /usr/lib/x86_64-linux-gnu ] && compgen -G "/usr/lib/x86_64-linux-gnu/libboost_python"*.so* >/dev/null; then
            echo "====> Bundling Boost shared libs from host /usr/lib/x86_64-linux-gnu (CI install)"
            cp -a /usr/lib/x86_64-linux-gnu/libboost_*.so* "$vendor_libdir/" 2>/dev/null || true
        else
            echo "====> ERROR: Boost runtime not found (need libboost-all-dev_${BOOST_VERSION}*.deb or host install)"
            exit 1
        fi
        if ! compgen -G "${vendor_libdir}/libboost_python"*.so* >/dev/null; then
            echo "====> ERROR: libboost_python not present under ${vendor_libdir}"
            exit 1
        fi
        libtorrent_files=$(find "$PKG_DIR/$INSTALL_PATH" -name "libtorrent*" -type f)
        if [ -z "$libtorrent_files" ]; then
            echo "====> ERROR: No libtorrent files found in $PKG_DIR/$INSTALL_PATH"
            echo "====> This is required for Deluge to function properly"
            exit 1
        else
            echo "====> Found libtorrent files in $PKG_DIR/$INSTALL_PATH"
        fi
        if command -v patchelf >/dev/null 2>&1; then
            echo "====> Applying RPATH (libtorrent + Boost in usr/lib/x86_64-linux-gnu)"
            find "$PKG_DIR/$INSTALL_PATH/usr/lib/x86_64-linux-gnu" -maxdepth 1 -type f -name 'libtorrent-rasterbar.so*' ! -name '*.a' 2>/dev/null | while read -r _lt_rb; do
                patchelf --set-rpath '$ORIGIN' "$_lt_rb" 2>/dev/null || true
            done
            find "$PKG_DIR/$INSTALL_PATH/usr/lib" -type f -name 'libtorrent.cpython-*.so' 2>/dev/null | while read -r _lt_so; do
                patchelf --set-rpath '$ORIGIN/../../x86_64-linux-gnu' "$_lt_so" || true
            done
        else
            echo "====> WARN: patchelf not found; libtorrent .so may need LD_LIBRARY_PATH at runtime"
        fi
        # Strip ELF objects only; do not use file(1) (often missing in slim CI images and breaks under find -exec).
        while IFS= read -r -d '' _strip_path; do
            head -c 4 "$_strip_path" 2>/dev/null | cmp -s - <(printf '\177ELF') || continue
            strip --strip-unneeded "$_strip_path" 2>/dev/null || true
        done < <(find "$PKG_DIR" -type f -print0)
        INSTALLED_SIZE=$(du -sk "$PKG_DIR/opt" | cut -f1)
        cat > "$PKG_DIR/DEBIAN/control" << EOF
Package: deluge
Version: $FULL_VERSION
Architecture: $ARCHITECTURE
Maintainer: ${COMMITTER_NAME} <${COMMITTER_EMAIL}>
Installed-Size: ${INSTALLED_SIZE}
Depends: python3, python3-twisted, python3-openssl, python3-xdg, python3-chardet, python3-setproctitle, python3-rencode, python3-pillow, libssl3, libc6, zlib1g
Provides: deluged, deluge-console, deluge-web
Conflicts: deluged, deluge-common, deluge-console, deluge-web, deluge-gtk, deluge
Replaces: deluged, deluge-common, deluge-console, deluge-web, deluge-gtk, deluge
Section: net
Priority: optional
Homepage: https://deluge-torrent.org/
Description: BitTorrent client (CLI tools, daemon and web UI)
 Deluge BitTorrent client compiled for server usage.
 Contains CLI tools, daemon and web interface.
 .
 This package contains:
  * CLI tools: deluge-console
  * Daemon: deluged
  * Web UI: deluge-web
 .
 Compiled on $(date +%Y-%m-%d)
EOF
        cat > "$PKG_DIR/DEBIAN/postinst" << 'EOF'
#!/bin/sh
set -e
case "$1" in
    configure)
        PKG_NAME="${DPKG_MAINTSCRIPT_PACKAGE}"
        INSTALL_BASE="__INSTALL_BASE__"
        INSTALL_USR="${INSTALL_BASE}/usr"
        ENV_FILE="${INSTALL_BASE}/.env"
        PRIORITY=50
        cat > "${ENV_FILE}" <<EOF2
export PATH="${INSTALL_USR}/bin:\$PATH"
export PYTHONPATH="${INSTALL_USR}/lib/python3.13/site-packages:${INSTALL_USR}/lib/python3/dist-packages:\$PYTHONPATH"
export LD_LIBRARY_PATH="${INSTALL_USR}/lib/x86_64-linux-gnu:\$LD_LIBRARY_PATH"
EOF2
        PREF_SRC="/usr/share/krate/apt-preferences/${PKG_NAME}.pref"
        PREF_DST="/etc/apt/preferences.d/${PKG_NAME}.pref"
        if [ -f "${PREF_SRC}" ]; then
            mkdir -p /etc/apt/preferences.d
            cp -f "${PREF_SRC}" "${PREF_DST}"
            chmod 0644 "${PREF_DST}"
        fi
        for bin in deluged deluge-web deluge-console deluge-gtk; do
            if [ -f "${INSTALL_USR}/bin/${bin}" ]; then
                update-alternatives --install "/usr/bin/${bin}" "${bin}" "${INSTALL_USR}/bin/${bin}" ${PRIORITY}
            fi
        done
        if command -v mandb >/dev/null 2>&1; then
            mandb || true
        fi
    ;;
    abort-upgrade|abort-install|abort-remove)
    ;;
    *)
    ;;
esac

exit 0
EOF
        cat > "$PKG_DIR/DEBIAN/prerm" << 'EOF'
#!/bin/sh
set -e
case "$1" in
    remove|deconfigure)
        PKG_NAME="${DPKG_MAINTSCRIPT_PACKAGE:-deluge}"
        INSTALL_BASE="__INSTALL_BASE__"
        INSTALL_USR="${INSTALL_BASE}/usr"
        
        # Delete the alternatives for the binaries
        for bin in deluged deluge-web deluge-console deluge-gtk; do
            if [ -f "${INSTALL_USR}/bin/${bin}" ]; then
                update-alternatives --remove "${bin}" "${INSTALL_USR}/bin/${bin}" || true
            fi
        done
        rm -f "/etc/apt/preferences.d/${PKG_NAME}.pref"
    ;;
    upgrade|failed-upgrade|abort-install|abort-upgrade|disappear)
    ;;
    *)
        echo "prerm called with an unknown argument \`$1\`" >&2
        exit 1
    ;;
esac
exit 0
EOF
        echo "Generating md5sums..."
        (
            cd "$PKG_DIR"
            find . -type f ! -path "./DEBIAN/*" -exec md5sum {} \; > DEBIAN/md5sums
        )
        chmod 755 "$PKG_DIR/DEBIAN/postinst" "$PKG_DIR/DEBIAN/prerm"
        sed -i "s|__INSTALL_BASE__|${INSTALL_PATH}|g" "$PKG_DIR/DEBIAN/postinst" "$PKG_DIR/DEBIAN/prerm"
        cd "$WHEREAMI"
        dpkg-deb --build -Zxz -z9 -Sextreme --root-owner-group "$PKG_DIR" "output/$PACKAGE_NAME"
        echo "====> Debian package created at:"
        echo "$WHEREAMI/output/$PACKAGE_NAME"
    fi
}

# -----------------------------------------------------------------------------
# Main execution
# -----------------------------------------------------------------------------
build_deluge
create_package

echo "====> All done! Deluge $DELUGE_VERSION has been built."
echo "====> The binaries are at $WHEREAMI/output/"
if [ -n "$CREATE_DEB" ] && [ "$CREATE_DEB" = "true" ]; then
    echo "====> The Debian package is at $WHEREAMI/output/krate-deluge_${DEB_UPSTREAM_VERSION}-${BUILD}_amd64.deb"
fi
exit 0 
