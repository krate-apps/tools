#!/usr/bin/env bash
set -e

# =============================================================================
# build-boost.sh
#
# This script builds the latest version of Boost and packages it as a .deb file
# that installs to a standard Debian-like directory structure.
#
# Usage:
# ./build.sh <VERSION> [--nobuild]
# Example:
# ./build.sh 1.84.0 or 1.88.0_rc1
# ./build.sh 1.84.0 --nobuild
#
# Notes:
# - With --nobuild: Installs directly to /usr
# - Without --nobuild: Creates a .deb package with Debian-like structure
# =============================================================================

usage() {
    echo "Usage: $0 <VERSION> [--nobuild]"
    echo "Example: $0 1.84.0 or 1.88.0_rc1"
    echo "         $0 1.84.0 --nobuild"
    exit 1
}

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    usage
fi

# -----------------------------------------------------------------------------
# 0) Parameter analysis and definition of global variables
# -----------------------------------------------------------------------------
INPUT_VERSION="$1"
NOBUILD=false
if [ "$2" == "--nobuild" ]; then
    NOBUILD=true
    PREFIX="/usr"
else
    # Using empty prefix for .deb package as we'll handle paths manually
    PREFIX=""
fi

BOOST_VERSION="${INPUT_VERSION}"
BUILD="1"
FULL_VERSION="${BOOST_VERSION}-${BUILD}"
PYTHON_VERSION=$(python3 --version | awk '{print $2}')
PYTHON_VERSION_SHORT=$(echo "$PYTHON_VERSION" | cut -d. -f1-2)
# Get exact Python version without dots (e.g. 311 for 3.11)
PYTHON_VERSION_NO_DOTS=$(echo "$PYTHON_VERSION" | sed 's/\.//g' | cut -c1-3)
GCC_VERSION=$(gcc -dumpversion | cut -d. -f1)
echo "====> Building boost $BOOST_VERSION (build: $BUILD)"
echo "====> Full version: $FULL_VERSION"
echo "====> Installation prefix: $PREFIX"
echo "====> No package build: $NOBUILD"
echo "====> GCC version: $GCC_VERSION"
echo "====> Python version: $PYTHON_VERSION (short: $PYTHON_VERSION_SHORT, no dots: $PYTHON_VERSION_NO_DOTS)"

WHEREAMI="$(dirname "$(readlink -f "$0")")"
ARCHITECTURE="amd64"
BASE_DIR="$PWD/custom_build"
mkdir -p "$BASE_DIR"
INSTALL_DIR="$BASE_DIR/install"
mkdir -p "$INSTALL_DIR"

# For .deb package, these are the directories we'll create
if [ "$NOBUILD" = false ]; then
    mkdir -p "$INSTALL_DIR/usr/include/c++/$GCC_VERSION/bits"
    mkdir -p "$INSTALL_DIR/usr/share/aclocal"
    mkdir -p "$INSTALL_DIR/usr/share/lintian/overrides"
    mkdir -p "$INSTALL_DIR/usr/share/doc/autoconf-archive/html"
    mkdir -p "$INSTALL_DIR/usr/share/doc/libboost$BOOST_VERSION"
    mkdir -p "$INSTALL_DIR/etc/default/boost"
    mkdir -p "$INSTALL_DIR/usr/lib/x86_64-linux-gnu/cmake"
    mkdir -p "$INSTALL_DIR/usr/bin"
fi

# -----------------------------------------------------------------------------
# 1) Download and extract Boost
# -----------------------------------------------------------------------------
build_boost() {
    echo "====> Downloading and extracting Boost $BOOST_VERSION"
    local VERSION_UNDERSCORE="${BOOST_VERSION//./_}"
    echo "====> Cleaning any existing boost directories"
    cd "$BASE_DIR"
    rm -rf boost_*
    echo "====> Downloading Boost"    
    if [[ "$BOOST_VERSION" == *"_rc"* ]]; then
        local BASE_VERSION
        BASE_VERSION=$(echo "$BOOST_VERSION" | sed 's/_rc[0-9]*//')
        echo "====> Using RC version: base=$BASE_VERSION, rc from $BOOST_VERSION"
        wget "https://archives.boost.io/release/$BASE_VERSION/source/boost_${VERSION_UNDERSCORE}.tar.gz" -O "boost.tar.gz"
    else
        wget "https://archives.boost.io/release/$BOOST_VERSION/source/boost_${VERSION_UNDERSCORE}.tar.gz" -O "boost.tar.gz"
    fi
    echo "====> Extracting archive"
    tar xzf "boost.tar.gz"
    rm "boost.tar.gz"
    local SRC_DIR=$(find "$BASE_DIR" -maxdepth 1 -type d -name "boost_*" | head -n 1)
    if [ -z "$SRC_DIR" ]; then
        echo "ERROR: Could not find extracted Boost directory. Contents of $BASE_DIR:"
        ls -la "$BASE_DIR"
        exit 1
    fi
    echo "====> Found Boost source directory: $SRC_DIR"
    cd "$SRC_DIR" || { echo "Cannot change to directory $SRC_DIR"; exit 1; }
    echo "====> Ensuring Python development files are installed"
    sudo apt-get update
    sudo apt-get install -y python3-dev
    echo "====> Bootstrapping Boost with Python $PYTHON_VERSION_SHORT"
    cat > user-config.jam << EOF
using python : $PYTHON_VERSION_SHORT : /usr/bin/python$PYTHON_VERSION_SHORT : /usr/include/python${PYTHON_VERSION_SHORT} : /usr/lib ;
EOF
    # Boost.System is header-only since 1.69 — do not pass system to bootstrap/b2 (--with-system errors on recent Boost).
    ./bootstrap.sh --with-libraries=python --with-python=/usr/bin/python3 --with-python-version="$PYTHON_VERSION_SHORT"
    grep -q "using python" project-config.jam || echo "using python : $PYTHON_VERSION_SHORT : /usr/bin/python$PYTHON_VERSION_SHORT : /usr/include/python${PYTHON_VERSION_SHORT} : /usr/lib ;" >> project-config.jam
}

# -----------------------------------------------------------------------------
# 2) Create Debian package with proper directory structure
# -----------------------------------------------------------------------------
create_deb_package() {
    echo "====> Creating Debian package with proper directory structure"
    local SRC_DIR=$(find "$BASE_DIR" -maxdepth 1 -type d -name "boost_*" | head -n 1)
    if [ -z "$SRC_DIR" ]; then
        echo "ERROR: Could not find Boost source directory."
        exit 1
    fi
    cd "$SRC_DIR" || { echo "Cannot change to directory $SRC_DIR"; exit 1; }
    echo "====> Building Boost libraries"
    ./b2 -j"$(nproc)" \
        variant=release \
        link=static,shared \
        runtime-link=shared \
        threading=multi \
        cxxflags="-std=c++17 -fPIC" \
        --layout=system \
        --with-python \
        python="$PYTHON_VERSION_SHORT" \
        install \
        --prefix=stage \
        --cmake
        
    echo "====> Installing to temporary location with proper directory structure"
    find stage/include/boost -type d -empty -delete
    cp -a stage/include/boost "$INSTALL_DIR/usr/include/"
    cp stage/lib/libboost_*.so* "$INSTALL_DIR/usr/lib/x86_64-linux-gnu/" 2>/dev/null || true
    cp stage/lib/libboost_*.a "$INSTALL_DIR/usr/lib/x86_64-linux-gnu/" 2>/dev/null || true
    CMAKE_STAGE="stage/lib/cmake"
    if [ -d "$CMAKE_STAGE" ]; then
        for f in BoostConfig.cmake BoostConfigVersion.cmake; do
            find "$CMAKE_STAGE" -name "$f" -exec cp --parents {} "$INSTALL_DIR/usr/lib/x86_64-linux-gnu/cmake/" \;
        done
        find "$CMAKE_STAGE" -name "BoostDetectToolset-*.cmake" -exec cp --parents {} "$INSTALL_DIR/usr/lib/x86_64-linux-gnu/cmake/" \;
        find "$CMAKE_STAGE" -name "boost_headers-config*.cmake" -exec cp --parents {} "$INSTALL_DIR/usr/lib/x86_64-linux-gnu/cmake/" \;
    fi
    mkdir -p "$INSTALL_DIR/usr/share/lintian/overrides"
    BOOST_SHORT_VERSION="$(printf '%s' "$BOOST_VERSION" | cut -d. -f1-2)"
    echo "libboost${BOOST_SHORT_VERSION}-dev: extra-license-file" > "$INSTALL_DIR/usr/share/lintian/overrides/libboost${BOOST_SHORT_VERSION}-dev"
    cp b2 "$INSTALL_DIR/usr/bin/"
    chmod +x "$INSTALL_DIR/usr/bin/b2"
    cp Jamroot "$INSTALL_DIR/etc/default/boost/"
    cp boost-build.jam "$INSTALL_DIR/etc/default/boost/"
    cp project-config.jam "$INSTALL_DIR/etc/default/boost/"
    cp user-config.jam "$INSTALL_DIR/etc/default/boost/"
    mkdir -p "$INSTALL_DIR/DEBIAN"
    cat > "$INSTALL_DIR/DEBIAN/control" << EOF
Package: libboost-all-dev
Version: ${BOOST_VERSION}-${BUILD}
Architecture: $ARCHITECTURE
Maintainer: ${COMMITTER_NAME:-"KRATE"} <${COMMITTER_EMAIL:-"info@krate.org"}>
Depends: python3-dev
Description: Boost libraries (KRATE build with Python $PYTHON_VERSION_SHORT support)
 The Boost web site provides free, peer-reviewed, portable C++ source libraries. 
 The emphasis is on libraries which work well with the C++ Standard Library. 
 One goal is to establish "existing practice" and provide reference implementations so that the Boost libraries are suitable for eventual standardization. 
 Some of the libraries have already been proposed for inclusion in the C++ Standards Committee's upcoming C++ Standard Library Technical Report.
 .
 Compiled on $(date +%Y-%m-%d)
Section: libs
Priority: optional
EOF
    cat > "$INSTALL_DIR/DEBIAN/postinst" << 'EOF'
#!/bin/sh
set -e
# Create symbolic link for bjam
ln -sf /usr/bin/b2 /usr/bin/bjam
EOF
    chmod 755 "$INSTALL_DIR/DEBIAN/postinst"
    cat > "$INSTALL_DIR/DEBIAN/prerm" << 'EOF'
#!/bin/sh
set -e
# Remove symbolic link for bjam if it exists
if [ -L /usr/bin/bjam ]; then
    rm -f /usr/bin/bjam
fi
EOF
    chmod 755 "$INSTALL_DIR/DEBIAN/prerm"
    echo "====> Copying files from $INSTALL_DIR to $INSTALL_DIR"
    cd "$INSTALL_DIR"
    find . -type f -exec file {} \; | grep ELF | cut -d: -f1 | xargs --no-run-if-empty strip --strip-unneeded
    find . -type f ! -path "./DEBIAN/*" -exec md5sum {} \; > DEBIAN/md5sums
    cd "$WHEREAMI"
    dpkg-deb --build -Zxz -z9 -Sextreme --root-owner-group "$INSTALL_DIR" "$WHEREAMI/libboost-all-dev_${BOOST_VERSION}-${BUILD}_amd64.deb"
    echo "====> Debian package created: libboost-all-dev_${BOOST_VERSION}-${BUILD}_amd64.deb"
}

# -----------------------------------------------------------------------------
# 3) Direct installation (when --nobuild is used)
# -----------------------------------------------------------------------------
direct_install() {
    local SRC_DIR=$(find "$BASE_DIR" -maxdepth 1 -type d -name "boost_*" | head -n 1)
    cd "$SRC_DIR" || { echo "Cannot change to directory $SRC_DIR"; exit 1; }
    sudo ./b2 headers
    echo "====> Building Boost libraries"
    sudo ./b2 -j"$(nproc)" \
        --prefix="$PREFIX" \
        variant=release \
        link=static,shared \
        runtime-link=shared \
        threading=multi \
        cxxflags="-std=c++17 -fPIC" \
        --layout=system \
        --with-python \
        python="$PYTHON_VERSION_SHORT" \
        install
    sudo ln -sf "$SRC_DIR/b2" /usr/bin/b2
    sudo ln -sf /usr/bin/b2 /usr/bin/bjam
    echo "====> Installation complete"
}

# -----------------------------------------------------------------------------
# Main execution
# -----------------------------------------------------------------------------
build_boost

if [ "$NOBUILD" = true ]; then
    direct_install
else
    create_deb_package
fi

echo "====> All done!"
exit 0 
