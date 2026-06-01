#!/bin/bash
set -e

VERSION=$1
if [ -z "$VERSION" ]; then
    echo "Usage: $0 <version>"
    exit 1
fi

# Get absolute path of the script
WHEREAMI="$(readlink -f "$(dirname "${BASH_SOURCE[0]}")")"

# 1. Create a temporary work directory
TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR"
codename=$(lsb_release -cs)
distro=$(lsb_release -is | tr '[:upper:]' '[:lower:]')
os="${distro}-${codename}"

# 2. Download and extract OpenSSL
echo "Downloading OpenSSL ${VERSION}..."
wget "https://www.openssl.org/source/openssl-${VERSION}.tar.gz"
tar xzf "openssl-${VERSION}.tar.gz"
cd "openssl-${VERSION}"

# 3. Configure and build
PREFIX="/usr"
OPENSSLDIR="/usr/lib/ssl"
LIBDIR="/usr/lib/x86_64-linux-gnu"

echo "Configuring OpenSSL..."
./Configure shared \
    --prefix="${PREFIX}" \
    --openssldir="${OPENSSLDIR}" \
    --libdir="${LIBDIR}" \
    -DCMAKE \
    -DBUILD_SHARED_LIBS=ON

echo "Building OpenSSL..."
make -j"$(nproc)"
sed -i "s/install: install_sw install_ssldirs install_docs/install: install_sw install_ssldirs install_programs generate generate_buildinfo generate_crypto_conf generate_crypto_asn1 generate_fuzz_oids/" Makefile

# 4. Install into staging directory
MAIN_INSTALL_DIR="${TEMP_DIR}/install"
make DESTDIR="$MAIN_INSTALL_DIR" install

# 5. Create staging directories for each package
if [ "$codename" = "bullseye" ]; then
    LIBSSL_CORE="libssl3"
else
    LIBSSL_CORE="libssl3t64"
fi
OPENSSL_DIR="${TEMP_DIR}/openssl"
LIBSSL_DIR="${TEMP_DIR}/${LIBSSL_CORE}"
LIBSSL_DEV_DIR="${TEMP_DIR}/libssl-dev"

# Create directory structure for openssl package
mkdir -p "${OPENSSL_DIR}/"{etc/ssl/{certs,private},usr/{bin,lib/ssl/misc}}
chmod 755 "${OPENSSL_DIR}/etc/ssl/certs"
chmod 750 "${OPENSSL_DIR}/etc/ssl/private"

# Create directory structure for libssl3/t64 package
mkdir -p "${LIBSSL_DIR}/usr/lib/x86_64-linux-gnu/engines-3"
chmod 755 "${LIBSSL_DIR}/usr/lib/x86_64-linux-gnu/engines-3"

# Create directory structure for libssl-dev package
mkdir -p "${LIBSSL_DEV_DIR}/usr/"{include/{openssl,x86_64-linux-gnu/openssl},lib/x86_64-linux-gnu/{cmake/OpenSSL,engines-3,pkgconfig}}
chmod 755 "${LIBSSL_DEV_DIR}/usr/include/openssl"
chmod 755 "${LIBSSL_DEV_DIR}/usr/include/x86_64-linux-gnu/openssl"
chmod 755 "${LIBSSL_DEV_DIR}/usr/lib/x86_64-linux-gnu/"{cmake/OpenSSL,engines-3,pkgconfig}

# Distribute files to openssl package
cp "${MAIN_INSTALL_DIR}${OPENSSLDIR}/openssl.cnf" "${OPENSSL_DIR}/etc/ssl/"
chmod 644 "${OPENSSL_DIR}/etc/ssl/openssl.cnf"

cp "${MAIN_INSTALL_DIR}/usr/bin/"{openssl,c_rehash} "${OPENSSL_DIR}/usr/bin/"
chmod 755 "${OPENSSL_DIR}/usr/bin/openssl"
chmod 755 "${OPENSSL_DIR}/usr/bin/c_rehash"

cp "${MAIN_INSTALL_DIR}${OPENSSLDIR}/misc/"{CA.pl,tsget.pl} "${OPENSSL_DIR}/usr/lib/ssl/misc/"
chmod 755 "${OPENSSL_DIR}/usr/lib/ssl/misc/CA.pl"
chmod 755 "${OPENSSL_DIR}/usr/lib/ssl/misc/tsget.pl"
cd "${OPENSSL_DIR}/usr/lib/ssl/misc" && ln -sf tsget.pl tsget && cd -

# Create SSL symlinks in openssl package
ln -sf /etc/ssl/certs/ca-certificates.crt "${OPENSSL_DIR}/usr/lib/ssl/cert.pem"
ln -sf /etc/ssl/certs "${OPENSSL_DIR}/usr/lib/ssl/certs"
ln -sf /etc/ssl/openssl.cnf "${OPENSSL_DIR}/usr/lib/ssl/openssl.cnf"
ln -sf /etc/ssl/private "${OPENSSL_DIR}/usr/lib/ssl/private"

# Distribute files to libssl3/t64 package
cp "${MAIN_INSTALL_DIR}/usr/lib/x86_64-linux-gnu/lib"{crypto,ssl}.so.3 "${LIBSSL_DIR}/usr/lib/x86_64-linux-gnu/"
chmod 755 "${LIBSSL_DIR}/usr/lib/x86_64-linux-gnu/lib"{crypto,ssl}.so.3

# Check for specific engine files and copy them
for engine in "afalg.so" "loader_attic.so" "padlock.so"; do
    found_file=$(find "${MAIN_INSTALL_DIR}" -type f -name "${engine}")
    if [ -n "${found_file}" ]; then
        cp "${found_file}" "${LIBSSL_DIR}/usr/lib/x86_64-linux-gnu/engines-3/"
        chmod 755 "${LIBSSL_DIR}/usr/lib/x86_64-linux-gnu/engines-3/${engine}"
    else
        echo "Warning: Engine file ${engine} not found"
    fi
done

# Distribute files to libssl-dev package
# Copy header files
cp "${MAIN_INSTALL_DIR}/usr/include/openssl/"* "${LIBSSL_DEV_DIR}/usr/include/openssl/"
find "${LIBSSL_DEV_DIR}/usr/include/openssl" -type f -name "*.h" -exec chmod 644 {} \;

# Copy architecture-specific headers
if [ -d "${MAIN_INSTALL_DIR}/usr/include/x86_64-linux-gnu/openssl" ]; then
    cp "${MAIN_INSTALL_DIR}/usr/include/x86_64-linux-gnu/openssl/"* "${LIBSSL_DEV_DIR}/usr/include/x86_64-linux-gnu/openssl/"
    find "${LIBSSL_DEV_DIR}/usr/include/x86_64-linux-gnu/openssl" -type f -name "*.h" -exec chmod 644 {} \;
fi

# Copy development libraries and create symlinks
cp "${MAIN_INSTALL_DIR}/usr/lib/x86_64-linux-gnu/lib"{crypto,ssl}.a "${LIBSSL_DEV_DIR}/usr/lib/x86_64-linux-gnu/"
chmod 644 "${LIBSSL_DEV_DIR}/usr/lib/x86_64-linux-gnu/lib"{crypto,ssl}.a

cp "${MAIN_INSTALL_DIR}/usr/lib/x86_64-linux-gnu/lib"{crypto,ssl}.so.3 "${LIBSSL_DEV_DIR}/usr/lib/x86_64-linux-gnu/"
chmod 755 "${LIBSSL_DEV_DIR}/usr/lib/x86_64-linux-gnu/lib"{crypto,ssl}.so.3

cd "${LIBSSL_DEV_DIR}/usr/lib/x86_64-linux-gnu"
ln -sf libcrypto.so.3 libcrypto.so
ln -sf libssl.so.3 libssl.so
cd -

# Copy engine files to libssl-dev
for engine in "afalg.so" "loader_attic.so" "padlock.so"; do
    found_file=$(find "${MAIN_INSTALL_DIR}" -type f -name "${engine}")
    if [ -n "${found_file}" ]; then
        cp "${found_file}" "${LIBSSL_DEV_DIR}/usr/lib/x86_64-linux-gnu/engines-3/"
        chmod 755 "${LIBSSL_DEV_DIR}/usr/lib/x86_64-linux-gnu/engines-3/${engine}"
    fi
done
if [ -d "${OPENSSL_DIR}/usr/lib/x86_64-linux-gnu/engines-3" ]; then
    rm -rf "${OPENSSL_DIR}/usr/lib/x86_64-linux-gnu/engines-3"
fi
if [ -d "${LIBSSL_DIR}/usr/lib/x86_64-linux-gnu/engines-3" ]; then
    rm -rf "${LIBSSL_DIR}/usr/lib/x86_64-linux-gnu/engines-3"
fi

# Copy pkgconfig files
cp "${MAIN_INSTALL_DIR}/usr/lib/x86_64-linux-gnu/pkgconfig/"*.pc "${LIBSSL_DEV_DIR}/usr/lib/x86_64-linux-gnu/pkgconfig/"
chmod 644 "${LIBSSL_DEV_DIR}/usr/lib/x86_64-linux-gnu/pkgconfig/"*.pc

# Ensure CMake files are properly installed
mkdir -p "${LIBSSL_DEV_DIR}/usr/lib/x86_64-linux-gnu/cmake/OpenSSL"
find "${WHEREAMI}" -type f -name "*.cmake" -print0 | while IFS= read -r -d '' file; do
    if [ -f "$file" ]; then
        chmod 644 "$file"
        cp "$file" "${LIBSSL_DEV_DIR}/usr/lib/x86_64-linux-gnu/cmake/OpenSSL/"
    fi
done

if [ -d "${LIBSSL_DEV_DIR}/usr/lib/x86_64-linux-gnu/cmake/OpenSSL/" ] && [ -z "$(ls -A "${LIBSSL_DEV_DIR}/usr/lib/x86_64-linux-gnu/cmake/OpenSSL/")" ]; then
    cp "${WHEREAMI}/OpenSSLConfig.cmake" "${LIBSSL_DEV_DIR}/usr/lib/x86_64-linux-gnu/cmake/OpenSSL/"
    cp "${WHEREAMI}/OpenSSLConfigVersion.cmake" "${LIBSSL_DEV_DIR}/usr/lib/x86_64-linux-gnu/cmake/OpenSSL/"
    chmod -R 644 "${LIBSSL_DEV_DIR}/usr/lib/x86_64-linux-gnu/cmake/OpenSSL/"
fi

# Create packages
mkdir -p "$TEMP_DIR/openssl-full"
for pkg in "openssl" "${LIBSSL_CORE}" "libssl-dev"; do
    pkg_dir="${TEMP_DIR}/${pkg}"
    find "$pkg_dir" -type f -exec file {} \; | grep ELF | cut -d: -f1 | while read -r file; do
        if [ -f "$file" ] && [ -x "$file" ]; then
            strip --strip-unneeded "$file" 2>/dev/null || true
            if file "$file" | grep -q "ELF.*executable" && command -v upx >/dev/null 2>&1; then
                upx --best --lzma "$file" 2>/dev/null || true
            fi
        fi
    done
    cp -pR --force "$pkg_dir" "$TEMP_DIR/openssl-full"
    echo "Full package size: $(du -sh "$TEMP_DIR/openssl-full")"
    SIZE=$(du -sk "$pkg_dir" | awk '{print $1}')
    mkdir -p "${pkg_dir}/DEBIAN"
    
    # Use package-specific control file
    if [ -f "$WHEREAMI/${pkg}.control" ]; then
        cp "$WHEREAMI/${pkg}.control" "${pkg_dir}/DEBIAN/control"
    else
        cp "$WHEREAMI/core.control" "${pkg_dir}/DEBIAN/control"
        sed -i "s/@PACKAGE_NAME@/${LIBSSL_CORE}/" "${pkg_dir}/DEBIAN/control"
    fi
    
    if [ -f "$WHEREAMI/${pkg}.postinst" ]; then
        cp "$WHEREAMI/${pkg}.postinst" "${pkg_dir}/DEBIAN/postinst"
        chmod 755 "${pkg_dir}/DEBIAN/postinst"
    fi
    find "$pkg_dir" -type d -empty -delete
    sed -i "s/@SIZE@/${SIZE}/" "${pkg_dir}/DEBIAN/control"
    sed -i "s/@LIBSSL_CORE@/${LIBSSL_CORE}/" "${pkg_dir}/DEBIAN/control"
    
    OUTPUT="${WHEREAMI}/${pkg}_${VERSION}-1_amd64.deb"
    dpkg-deb --build -Zxz --root-owner-group "$pkg_dir" "$OUTPUT"
    echo "Created package: $OUTPUT"
done
# create a global package
SIZE=$(du -sk "$TEMP_DIR/openssl-full" | awk '{print $1}')
mkdir -p "$TEMP_DIR/openssl-full/DEBIAN"
cp "$WHEREAMI/openssl-full.control" "$TEMP_DIR/openssl-full/DEBIAN/control"
cp "$WHEREAMI/postinst" "$TEMP_DIR/openssl-full/DEBIAN/postinst"
chmod 755 "$TEMP_DIR/openssl-full/DEBIAN/postinst"
sed -i "s/@SIZE@/${SIZE}/" "$TEMP_DIR/openssl-full/DEBIAN/control"
sed -i "s/@LIBSSL_CORE@/${LIBSSL_CORE}/" "$TEMP_DIR/openssl-full/DEBIAN/control"
dpkg-deb --build -Zxz --root-owner-group "$TEMP_DIR/openssl-full" "$WHEREAMI/openssl-full_${VERSION}-1_amd64.deb"
echo "Created global package: $WHEREAMI/openssl-full_${VERSION}-1_amd64.deb"

# Clean up
cd /
echo "Build and packages complete."
