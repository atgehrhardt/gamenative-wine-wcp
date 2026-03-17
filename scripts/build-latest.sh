#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <output-dir>" >&2
  exit 1
fi

RAW_OUTPUT_DIR="$1"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mkdir -p "${RAW_OUTPUT_DIR}"
OUTPUT_DIR="$(cd "${RAW_OUTPUT_DIR}" && pwd)"

DISCOVERY_ENV="$(
  PYTHONPATH="${ROOT_DIR}/src" python3 - <<'PY'
from wcp_builder.releases import discover_latest_releases

releases = discover_latest_releases()
for name, info in releases.items():
    upper = name.upper()
    print(f"{upper}_VERSION='{info.version}'")
    print(f"{upper}_TAG='{info.tag}'")
    print(f"{upper}_URL='{info.url}'")
PY
)" || {
  echo "Failed to discover the latest official stable Wine release from inside the container." >&2
  echo "This is usually a temporary Docker networking or DNS issue. Try the command again." >&2
  exit 1
}

eval "${DISCOVERY_ENV}"

echo "Building Wine ${WINE_VERSION} from ${WINE_URL}"
"${ROOT_DIR}/scripts/build-wine.sh" "${WINE_VERSION}" "${WINE_URL}" "${OUTPUT_DIR}"

echo "Artifacts written to ${OUTPUT_DIR}"
