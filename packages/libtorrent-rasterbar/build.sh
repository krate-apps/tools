#!/usr/bin/env bash
set -e

# =============================================================================
# build.sh
#
# This script compiles the libtorrent-rasterbar library
#
# Usage:
# ./build.sh <DESTDIR>
# =============================================================================

if [ $# -ne 1 ]; then
    echo "Usage: $0 <DESTDIR>"
    echo "Example: $0 /path/to/install/dir"
    exit 1
fi
DESTDIR="$1"
PREFIX="/usr/local"
: "${BOOST_ROOT:=/usr}"
: "${BOOST_INCLUDEDIR:=/usr/include}"
: "${BOOST_LIBRARYDIR:=/usr/lib/x86_64-linux-gnu}"
CORES=$(nproc)
if [ -z "$SRC_DIR" ]; then
    SRC_DIR="$PWD/libtorrent"
fi
if [ ! -d "$SRC_DIR" ]; then
    echo "ERROR: Source directory $SRC_DIR does not exist"
    exit 1
fi
PYTHON_VERSION=$(python3 --version | awk '{print $2}')
PYTHON_VERSION_SHORT=$(echo "$PYTHON_VERSION" | cut -d. -f1-2)
PYTHON_VERSION_NO_DOTS=$(echo "$PYTHON_VERSION" | sed 's/\.//g' | cut -c1-3)
PYTHON_LIBRARY="/usr/lib/x86_64-linux-gnu/libpython${PYTHON_VERSION_SHORT}.so"
echo "====> Building libtorrent-rasterbar"
echo "====> Boost: ROOT=$BOOST_ROOT INCLUDEDIR=$BOOST_INCLUDEDIR LIBRARYDIR=$BOOST_LIBRARYDIR"
echo "====> Source directory: $SRC_DIR"
echo "====> Python: version=$PYTHON_VERSION, short=$PYTHON_VERSION_SHORT, no_dots=$PYTHON_VERSION_NO_DOTS"
echo "====> Installing build dependencies"
sudo apt-get update
sudo apt-get install -y build-essential libssl-dev cmake ninja-build python3-dev python3-setuptools
if [ ! -f "$PYTHON_LIBRARY" ]; then
    echo "Could not find Python library at $PYTHON_LIBRARY"
    PYTHON_LIBRARY=$(find /usr/lib -name "libpython${PYTHON_VERSION_SHORT}*.so*" | head -1)
    echo "Found Python library at $PYTHON_LIBRARY"
fi
export CFLAGS="-O3 -march=native"
export CXXFLAGS="-O3 -march=native -std=c++17"
echo "====> Building libtorrent-rasterbar with CMake"
cd "$SRC_DIR"
mkdir -p build
cd build
echo "====> Configuring libtorrent-rasterbar with CMake"
    cmake .. \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=$PREFIX \
        -DCMAKE_CXX_STANDARD=17 \
        -DBUILD_SHARED_LIBS=ON \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -Dpython-bindings=ON \
        -Dpython-egg-info=ON \
        -Dpython-install-system-dir=ON \
        -DBOOST_ROOT="$BOOST_ROOT" \
        -DBOOST_INCLUDEDIR="$BOOST_INCLUDEDIR" \
        -DBOOST_LIBRARYDIR="$BOOST_LIBRARYDIR" \
        -GNinja
echo "====> Building libtorrent-rasterbar shared library"
ninja -j$CORES
echo "====> Installing libtorrent-rasterbar into staging area ($DESTDIR)"
mkdir -p "$DESTDIR"
DESTDIR="$DESTDIR" ninja install
echo "====> Creating static library from object files"
cd "$SRC_DIR"
OBJECTS_PATH=$(find build -name "*.o" -not -path "*/CMakeFiles/ShowIncludes/*" -not -path "*/examples/*" -not -path "*/tests/*" -not -path "*/tools/*")
ar crs libtorrent-rasterbar.a $OBJECTS_PATH
echo "====> Static library information:"
ls -la libtorrent-rasterbar.a
echo "====> Installing libtorrent-rasterbar.a to $DESTDIR"
mkdir -p "$DESTDIR$PREFIX/lib"
cp libtorrent-rasterbar.a "$DESTDIR$PREFIX/lib/"
if [ -f "$DESTDIR/$PREFIX/lib/pkgconfig/libtorrent-rasterbar.pc" ]; then
    sed -i "s|^libdir=.*|libdir=$PREFIX/lib|g" "$DESTDIR/$PREFIX/lib/pkgconfig/libtorrent-rasterbar.pc"
fi
SOURCE_DIR="$DESTDIR$PREFIX"
TARGET_DESTDIR="$DESTDIR"
echo "====> Relocating files for packaging"
mkdir -p "$TARGET_DESTDIR/pkg_runtime/usr/lib/x86_64-linux-gnu"
mkdir -p "$TARGET_DESTDIR/pkg_dev/usr/lib/x86_64-linux-gnu"
mkdir -p "$TARGET_DESTDIR/pkg_dev/usr/include"
mkdir -p "$TARGET_DESTDIR/pkg_dev/usr/lib/x86_64-linux-gnu/cmake/LibtorrentRasterbar"
mkdir -p "$TARGET_DESTDIR/pkg_dev/usr/lib/x86_64-linux-gnu/pkgconfig"
mkdir -p "$TARGET_DESTDIR/pkg_dev/usr/share/cmake/Modules"
mkdir -p "$TARGET_DESTDIR/pkg_python/usr/lib/python3/dist-packages"
echo "====> Checking installed files in $SOURCE_DIR"
find "$SOURCE_DIR" -type f -name "*libtorrent*" | sort
echo "====> Copying shared libraries for runtime package"
LIB_PATTERN="libtorrent-rasterbar.so.2.0.*"
SO_FILES=$(find "$SRC_DIR" -type f -name "$LIB_PATTERN")
SOLINK_FILES=$(find "$SRC_DIR" -type l -name "libtorrent-rasterbar.so.2.0")
if [ -n "$SO_FILES" ]; then
    echo "Found shared library files:"
    echo "$SO_FILES"
    echo "$SOLINK_FILES"
    MAIN_SO=$(echo "$SO_FILES" | head -1)
    MAIN_SO_DIR=$(dirname "$MAIN_SO")
    echo "Copying from $MAIN_SO_DIR"
    for SO_FILE in $SO_FILES; do
        cp -P "$SO_FILE" "$TARGET_DESTDIR/pkg_runtime/usr/lib/x86_64-linux-gnu/"
    done
    for SOLINK in $SOLINK_FILES; do
        cp -P "$SOLINK" "$TARGET_DESTDIR/pkg_runtime/usr/lib/x86_64-linux-gnu/"
    done
    cd "$TARGET_DESTDIR/pkg_runtime/usr/lib/x86_64-linux-gnu/"
    SO_VERSION=$(ls libtorrent-rasterbar.so.2.0.* | sort | head -1)
    if [ -n "$SO_VERSION" ] && [ ! -L "libtorrent-rasterbar.so.2.0" ]; then
        ln -sf "$SO_VERSION" "libtorrent-rasterbar.so.2.0"
    fi
    cd - > /dev/null
else
    echo "ERROR: Could not find any libtorrent-rasterbar.so files anywhere!"
    echo "Searched with pattern: $LIB_PATTERN"
    echo "Directories searched:"
    find "$SRC_DIR" -type d | grep -v CMakeFiles | sort
    find "." -type f -name "libtorrent-rasterbar.so*"
fi
if [ -d "$SOURCE_DIR/include/libtorrent" ]; then
    echo "Copying include files from $SOURCE_DIR/include/"
    cp -r "$SOURCE_DIR/include/libtorrent" "$TARGET_DESTDIR/pkg_dev/usr/include/"
else
    echo "WARNING: Include directory not found at $SOURCE_DIR/include/libtorrent"
    FOUND_INCLUDE=$(find "$SRC_DIR/build" -type d -name "libtorrent" -path "*/include/*" | head -1)
    if [ -n "$FOUND_INCLUDE" ]; then
        echo "Found include directory: $FOUND_INCLUDE"
        cp -r "$FOUND_INCLUDE" "$TARGET_DESTDIR/pkg_dev/usr/include/"
    else
        FOUND_INCLUDE=$(find "$SRC_DIR/include" -type d -name "libtorrent" 2>/dev/null | head -1)
        if [ -n "$FOUND_INCLUDE" ]; then
            echo "Found include directory in source: $FOUND_INCLUDE"
            cp -r "$FOUND_INCLUDE" "$TARGET_DESTDIR/pkg_dev/usr/include/"
        else
            echo "ERROR: Could not find libtorrent include directory!"
        fi
    fi
fi
SODEV_FILES=$(find "$SRC_DIR" -name "libtorrent-rasterbar.so" | head -1)
if [ -n "$SODEV_FILES" ]; then
    SODEV="$SODEV_FILES"
    echo "Copying dev library from $(dirname "$SODEV")"
    cp "$SODEV" "$TARGET_DESTDIR/pkg_dev/usr/lib/x86_64-linux-gnu/"
    
    cd "$TARGET_DESTDIR/pkg_dev/usr/lib/x86_64-linux-gnu/"
    if [ -f "libtorrent-rasterbar.so" ] && [ ! -L "libtorrent-rasterbar.so" ]; then
        # mv "libtorrent-rasterbar.so" "libtorrent-rasterbar.so.orig"
        ln -sf "libtorrent-rasterbar.so.2.0" "libtorrent-rasterbar.so"
    fi
    cd - > /dev/null
fi
# Paths
CMAKE_DEST="$TARGET_DESTDIR/pkg_dev/usr/lib/x86_64-linux-gnu/cmake/LibtorrentRasterbar"
PKGCONFIG_DEST="$TARGET_DESTDIR/pkg_dev/usr/lib/x86_64-linux-gnu/pkgconfig"
MODULES_DEST="$TARGET_DESTDIR/pkg_dev/usr/share/cmake/Modules"
PYTHON_DEST="$TARGET_DESTDIR/pkg_python/usr/lib/python3/dist-packages"
FOUND_CMAKE=$(find "$SRC_DIR" -name "LibtorrentRasterbarConfig.cmake" | head -1)
if [ -n "$FOUND_CMAKE" ]; then
    echo "✓ Found CMake files at $(dirname "$FOUND_CMAKE")"
    mkdir -p "$CMAKE_DEST"
    cp -v "$(dirname "$FOUND_CMAKE")"/*.cmake "$CMAKE_DEST/"
else
    echo "✗ CMake files not found, generating minimal config files"
    mkdir -p "$CMAKE_DEST"
    LIBTORRENT_VERSION="2.0.0"
    SO_VERSION_FILE=$(find "$TARGET_DESTDIR" -name "libtorrent-rasterbar.so.*.*" | head -1)
    [ -n "$SO_VERSION_FILE" ] && LIBTORRENT_VERSION=$(basename "$SO_VERSION_FILE" | sed 's/libtorrent-rasterbar.so.//')

    cat > "$CMAKE_DEST/LibtorrentRasterbarConfig.cmake" <<EOF
set(LIBTORRENT_RASTERBAR_VERSION ${LIBTORRENT_VERSION})
set(LIBTORRENT_RASTERBAR_INCLUDE_DIRS "/usr/include")
if(NOT TARGET LibtorrentRasterbar::torrent-rasterbar)
  add_library(LibtorrentRasterbar::torrent-rasterbar SHARED IMPORTED)
  set_target_properties(LibtorrentRasterbar::torrent-rasterbar PROPERTIES
    IMPORTED_LOCATION "/usr/lib/x86_64-linux-gnu/libtorrent-rasterbar.so.${LIBTORRENT_VERSION}"
    INTERFACE_INCLUDE_DIRECTORIES "/usr/include")
endif()
EOF

    cat > "$CMAKE_DEST/LibtorrentRasterbarConfigVersion.cmake" <<EOF
set(PACKAGE_VERSION "${LIBTORRENT_VERSION}")
if(PACKAGE_VERSION VERSION_LESS PACKAGE_FIND_VERSION)
  set(PACKAGE_VERSION_COMPATIBLE FALSE)
else()
  set(PACKAGE_VERSION_COMPATIBLE TRUE)
  if(PACKAGE_FIND_VERSION STREQUAL PACKAGE_VERSION)
    set(PACKAGE_VERSION_EXACT TRUE)
  endif()
fi
EOF
fi

# Try to find and copy .pc file
mkdir -p "$PKGCONFIG_DEST"
PC_FILE=$(find "$SRC_DIR" -name "libtorrent-rasterbar.pc" | head -1)
if [ -n "$PC_FILE" ]; then
    echo "✓ Found pkg-config file: $PC_FILE"
    cp "$PC_FILE" "$PKGCONFIG_DEST/"
    sed -i "s|$PREFIX|/usr|g" "$PKGCONFIG_DEST/libtorrent-rasterbar.pc"
    sed -i "s|libdir=/usr/lib|libdir=/usr/lib/x86_64-linux-gnu|g" "$PKGCONFIG_DEST/libtorrent-rasterbar.pc"
else
    echo "✗ pkg-config file not found"
fi

# Try to find and copy FindLibtorrentRasterbar.cmake
mkdir -p "$MODULES_DEST"
FIND_FILE=$(find "$SRC_DIR" -name "FindLibtorrentRasterbar.cmake" | head -1)
if [ -n "$FIND_FILE" ]; then
    echo "✓ Found FindLibtorrentRasterbar.cmake: $FIND_FILE"
    cp "$FIND_FILE" "$MODULES_DEST/"
else
    echo "✗ FindLibtorrentRasterbar.cmake not found"
fi

# Python extension: ninja install drops PEP 3149 modules under PREFIX/lib/python*/site-packages;
# build dirs may use python3.13 etc., so */python3/* was too narrow.
mkdir -p "$PYTHON_DEST"
PY_SO=$(find "$SOURCE_DIR" "$SRC_DIR/build" -type f \( -name 'libtorrent.cpython*.so' -o -name 'libtorrent.so' \) ! -path '*/CMakeFiles/*' 2>/dev/null | head -1)
if [ -n "$PY_SO" ]; then
    echo "✓ Found Python bindings: $PY_SO"
    cp "$PY_SO" "$PYTHON_DEST/"
else
    echo "✗ Python bindings not found under $SOURCE_DIR or $SRC_DIR/build"
    find "$SOURCE_DIR" "$SRC_DIR/build" -type f -name 'libtorrent*' 2>/dev/null | head -n 20 || true
fi

# Try to find and copy egg-info
EGG_INFO=$(find "$SOURCE_DIR" "$SRC_DIR/build" -type d -name 'libtorrent.egg-info' 2>/dev/null | head -1)
if [ -n "$EGG_INFO" ]; then
    echo "✓ Found Python egg-info: $EGG_INFO"
    cp -r "$EGG_INFO" "$PYTHON_DEST/"
else
    echo "✗ Python egg-info not found"
fi
if ! find "$TARGET_DESTDIR/pkg_python" -type f \( -name 'libtorrent.cpython*.so' -o -name 'libtorrent.so' \) 2>/dev/null | grep -q .; then
    echo "ERROR: python3-libtorrent package has no extension module (fix PY_SO discovery or bindings build)."
    exit 1
fi
find "$TARGET_DESTDIR" -name "*.a" -delete
TARGET_FILES=$(find "$TARGET_DESTDIR" -type f -name 'LibtorrentRasterbarTargets.cmake')
for file in $TARGET_FILES; do
    sudo sed -i \
        -e 's|/__w/rasterbar-builds/rasterbar-builds/libtorrent/include|/usr/include|g' \
        -e 's|/__w/rasterbar-builds/rasterbar-builds/libtorrent/lib|/usr/lib/x86_64-linux-gnu|g' \
        -e 's|/__w/rasterbar-builds/rasterbar-builds/libtorrent/build|/usr/lib/x86_64-linux-gnu|g' \
        "$file"
done
for dir in pkg_runtime pkg_dev pkg_python; do
    find "$TARGET_DESTDIR/$dir" -type f -exec file {} \; | grep ELF | cut -d: -f1 | while read -r file; do
        if [ -f "$file" ] && [ -x "$file" ]; then
            strip --strip-unneeded "$file" 2>/dev/null || true
            if file "$file" | grep -q "ELF.*executable" && command -v upx >/dev/null 2>&1; then
                upx --best --lzma "$file" 2>/dev/null || true
            fi
        fi
    done
done
echo "====> Cleaning runtime package directory"
rm -rf "$TARGET_DESTDIR/pkg_runtime/usr/lib/x86_64-linux-gnu/cmake" 2>/dev/null || true
rm -rf "$TARGET_DESTDIR/pkg_runtime/usr/lib/x86_64-linux-gnu/pkgconfig" 2>/dev/null || true
rm -rf "$TARGET_DESTDIR/pkg_runtime/usr/lib/x86_64-linux-gnu/python3" 2>/dev/null || true
rm -f "$TARGET_DESTDIR/pkg_runtime/usr/lib/x86_64-linux-gnu/libtorrent-rasterbar.so" 2>/dev/null || true
echo "Runtime package directory: $TARGET_DESTDIR/pkg_runtime"
echo "Development package directory: $TARGET_DESTDIR/pkg_dev"
echo "Python package directory: $TARGET_DESTDIR/pkg_python"
echo "====> All done!"
