#!/usr/bin/env bash
# Install KRATE Boost .deb from github.com/krate-binaries/boost-builds Releases.
# Usage: install_boost_from_boost_builds.sh <version>
# Example: install_boost_from_boost_builds.sh 1.91.0
# Env: BOOST_BUILDS_REPO (default krate-binaries/boost-builds), GITHUB_TOKEN (optional, for API rate limits / private repos)
set -euo pipefail

VERSION="${1:?usage: $0 <boost_version e.g. 1.91.0>}"
REPO="${BOOST_BUILDS_REPO:-krate-binaries/boost-builds}"
FILENAME="libboost-all-dev_${VERSION}-1_amd64.deb"
TAG="v${VERSION}"

api_curl() {
  local args=(-fsSL)
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi
  curl "${args[@]}" "$@"
}

echo "Fetching release ${TAG} from ${REPO}..."
assets_url=$(api_curl "https://api.github.com/repos/${REPO}/releases/tags/${TAG}" | jq -r '.assets_url')
if [ -z "$assets_url" ] || [ "$assets_url" = "null" ]; then
  echo "::error::Release ${TAG} not found in ${REPO}"
  exit 1
fi

download_url=$(api_curl "$assets_url" | jq -r ".[] | select(.name == \"${FILENAME}\") | .browser_download_url")
if [ -z "$download_url" ] || [ "$download_url" = "null" ]; then
  echo "::error::Asset ${FILENAME} not found in release ${TAG}"
  exit 1
fi

echo "Downloading ${FILENAME}..."
curl -fL --retry 3 --retry-delay 2 -o "$FILENAME" "$download_url"

run_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

echo "Installing ${FILENAME}..."
run_root dpkg -i "$FILENAME" || true
run_root apt-get install -f -y

echo "Boost ${VERSION} installed successfully"
