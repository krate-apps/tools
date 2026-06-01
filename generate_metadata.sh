#!/usr/bin/env bash
set -e

# defaults
CURRENT_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
BUILD="1"
EXTRA_FIELDS=()
DEPENDENCIES=()
OS=""
TYPE=""
CATEGORY=""
TAG=""
VERSION=""

function usage {
  cat <<EOF
Usage: $0 [options] path/to/debian/package.deb

Options:
  --category VALUE     Package category (e.g.: qbittorrent)
  --tag VALUE          Metadata tag (e.g.: release)
  --version VALUE      Explicit version (otherwise extracted)
  --build VALUE        Debian package revision (default: 1)
  --os VALUE           Distribution name (e.g.: bullseye, jammy)
  --extra KEY=VALUE    Add additional field (can be repeated)
  --dep KEY=VALUE      Add dependency field (can be repeated)
  -h|--help            Show this help
EOF
  exit 1
}

# parse args
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --category) CATEGORY="$2"; shift 2 ;;
    --tag)      TAG="$2";       shift 2 ;;
    --version)  VERSION="$2";   shift 2 ;;
    --build)    BUILD="$2";     shift 2 ;;
    --os)       OS="$2";        shift 2 ;;
    --extra)
      [[ "$2" == *=* ]] || usage
      EXTRA_FIELDS+=("$2")
      shift 2
      ;;
    --dep)
      [[ "$2" == *=* ]] || usage
      DEPENDENCIES+=("$2")
      shift 2
      ;;
    -h|--help)  usage ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL[@]}"

DEB_PACKAGE="$1"
[[ -f "$DEB_PACKAGE" ]] || { echo "Error: file not found: $DEB_PACKAGE"; exit 1; }

# compute basics
PACKAGE_ID=$(basename "$DEB_PACKAGE" .deb)
CHECKSUM=$(sha256sum "$DEB_PACKAGE" | awk '{print $1}')

# infer version if needed
if [[ -z "$VERSION" ]]; then
  VERSION=$(echo "$PACKAGE_ID" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || echo "unknown")
fi

# infer type if needed
if [[ -z "$TYPE" ]]; then
  if [[ "$PACKAGE_ID" == *-dev* ]]; then
    TYPE="dev"
  else
    TYPE="bin"
  fi
fi

# infer tag if needed
if [[ -z "$TAG" ]]; then
  TAG="release"
fi

# prepare jq args
JQ_ARGS=(
  --arg package_id       "$PACKAGE_ID"
  --arg version          "$VERSION"
  --arg build            "$BUILD"
  --arg checksum_sha256  "$CHECKSUM"
  --arg build_date       "$CURRENT_DATE"
  --arg category         "$CATEGORY"
  --arg tag              "$TAG"
  --arg type             "$TYPE"
)
# add OS
if [[ -n "$OS" ]]; then
  JQ_ARGS+=(--arg os "$OS")
fi
# add extras
for pair in "${EXTRA_FIELDS[@]}"; do
  key=${pair%%=*}
  val=${pair#*=}
  JQ_ARGS+=(--arg "extra_$key" "$val")
done
# add deps
for pair in "${DEPENDENCIES[@]}"; do
  key=${pair%%=*}
  val=${pair#*=}
  JQ_ARGS+=(--arg "dep_$key" "$val")
done

# build the jq filter
JQ_FILTER="{ 
  package_id: \$package_id,
  version: \$version,
  build: \$build,
  checksum_sha256: \$checksum_sha256,
  build_date: \$build_date,
  category: \$category,
  tag: \$tag,
  type: \$type"

if [[ -n "$OS" ]]; then
  JQ_FILTER+=", os: \$os"
fi

for pair in "${EXTRA_FIELDS[@]}"; do
  key=${pair%%=*}
  JQ_FILTER+=', '"$key"': $'"extra_$key"
done

if (( ${#DEPENDENCIES[@]} > 0 )); then
  JQ_FILTER+=', dependencies: {'
  for pair in "${DEPENDENCIES[@]}"; do
    key=${pair%%=*}
    JQ_FILTER+=' "'"$key"'": $'"dep_$key"','
  done
  JQ_FILTER=${JQ_FILTER%,}
  JQ_FILTER+=" }"
fi

JQ_FILTER+=' }'

# generate
JSON_FILE="${PACKAGE_ID}.json"
echo "Writing metadata to $JSON_FILE"
jq -n "${JQ_ARGS[@]}" "$JQ_FILTER" > "$JSON_FILE"

echo "---- $JSON_FILE ----"
cat "$JSON_FILE"
