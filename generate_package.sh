#!/bin/bash
set -e

# Check arguments
if [ "$#" -lt 3 ]; then
    echo "Usage: $0 <package_name> <source_dir> <deb_label>"
    echo "Example: $0 qbittorrent /tmp/qbittorrent-build/install release"
    exit 1
fi

PACKAGE_NAME="$1"
SOURCE_DIR="$2"
DEB_LABEL="${3}"
ARCHITECTURE="amd64"
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
PACKAGE_DIR="packages/${PACKAGE_NAME}"
PKG_DIR="debian"
DATE=$(date +%Y-%m-%d)
mkdir -p "${PKG_DIR}/DEBIAN"
mkdir -p "${PKG_DIR}/usr/local/bin"
if [ -d "${SOURCE_DIR}/bin" ]; then
    cp -r "${SOURCE_DIR}/bin/"* "${PKG_DIR}/usr/local/bin/"
elif [ -d "${SOURCE_DIR}" ]; then
    cp -r "${SOURCE_DIR}"/* "${PKG_DIR}/usr/local/bin/"
else
    echo "Error: Source directory ${SOURCE_DIR} not found"
    exit 1
fi
find "${PKG_DIR}" -type f -exec file {} \; | grep ELF | cut -d: -f1 | xargs --no-run-if-empty strip --strip-unneeded
if [ -f "${SCRIPT_DIR}/${PACKAGE_DIR}/control" ]; then
    sed -e "s/@DEB_LABEL@/${DEB_LABEL}/g" \
        -e "s/@VERSION@/${VERSION}/g" \
        -e "s/@ARCH@/${ARCHITECTURE}/g" \
        -e "s/@DATE@/${DATE}/g" \
        "${SCRIPT_DIR}/${PACKAGE_DIR}/control" > "${PKG_DIR}/DEBIAN/control"
else
    echo "Error: Control file ${SCRIPT_DIR}/${PACKAGE_DIR}/control not found"
    exit 1
fi
for script in postinst prerm; do
    if [ -f "${SCRIPT_DIR}/${PACKAGE_DIR}/${script}" ]; then
        cp "${SCRIPT_DIR}/${PACKAGE_DIR}/${script}" "${PKG_DIR}/DEBIAN/${script}"
        chmod 755 "${PKG_DIR}/DEBIAN/${script}"
    fi
done
if [ ! -f "${PKG_DIR}/DEBIAN/postinst" ]; then
    cat > "${PKG_DIR}/DEBIAN/postinst" << 'EOF'
#!/bin/bash
set -e
exit 0
EOF
    chmod 755 "${PKG_DIR}/DEBIAN/postinst"
fi
cd "${PKG_DIR}"
find . -type f ! -path "./DEBIAN/*" -exec md5sum {} \; > DEBIAN/md5sums
cd ..
dpkg-deb --build -Zxz -z9 -Sextreme --root-owner-group "${PKG_DIR}" "${PACKAGE_NAME}-${DEB_LABEL}_${VERSION}-1_${ARCHITECTURE}.deb"
