#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
CONFIG_PATH="${ROOT_DIR}/release/artifacts.json"

usage() {
  cat <<'EOF'
Usage: scripts/package-release.sh --check
       scripts/package-release.sh vX.Y.Z

--check validates that every SwiftPM executable product is classified by the
release inventory. Passing a tag additionally verifies built artifacts and
creates the complete release asset set under dist/.
EOF
}

die() {
  printf 'package-release: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 1 ]] || {
  usage >&2
  exit 64
}

case "$1" in
  --check) mode=check; tag='' ;;
  v[0-9]*.[0-9]*.[0-9]*) mode=package; tag=$1 ;;
  --help|-h)
    usage
    exit 0
    ;;
  *)
    usage >&2
    die "expected --check or a vX.Y.Z release tag"
    ;;
esac

[[ -f "${CONFIG_PATH}" ]] || die "missing ${CONFIG_PATH}"
if [[ -x /opt/homebrew/bin/mise ]]; then
  MISE_BIN=/opt/homebrew/bin/mise
else
  MISE_BIN="$(command -v mise || true)"
fi
[[ -n "${MISE_BIN}" ]] || die "mise is required"

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dopa-release.XXXXXX")"
cleanup() {
  rm -rf -- "${TEMP_DIR}"
}
trap cleanup EXIT

(cd "${ROOT_DIR}" && "${MISE_BIN}" exec -- swift package dump-package) \
  >"${TEMP_DIR}/package.json"

cd "${ROOT_DIR}"
"${MISE_BIN}" exec -- python "${SCRIPT_DIR}/package_release.py" \
  "${ROOT_DIR}" "${CONFIG_PATH}" "${TEMP_DIR}/package.json" "${mode}" "${tag}" \
  "${TEMP_DIR}"
