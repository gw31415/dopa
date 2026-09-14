#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
CONFIG_PATH="${ROOT_DIR}/release/artifacts.json"

usage() {
  cat <<'EOF'
Usage: scripts/render-homebrew-cask.sh VERSION APP_SHA256 [OUTPUT]

Render the Homebrew Cask from release/artifacts.json. VERSION must not include
the leading "v" used by the Git tag. The Cask is written to OUTPUT, or stdout
when OUTPUT is omitted.
EOF
}

die() {
  printf 'render-homebrew-cask: %s\n' "$*" >&2
  exit 1
}

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  usage
  exit 0
fi
[[ $# -ge 2 && $# -le 3 ]] || {
  usage >&2
  exit 64
}

version=$1
sha256=$2
output=${3:-}

[[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || die "invalid release version: ${version}"
[[ "${sha256}" =~ ^[0-9a-f]{64}$ ]] || die "APP_SHA256 must be 64 lowercase hex characters"
[[ -f "${CONFIG_PATH}" ]] || die "missing ${CONFIG_PATH}"

if [[ -x /opt/homebrew/bin/mise ]]; then
  MISE_BIN=/opt/homebrew/bin/mise
else
  MISE_BIN="$(command -v mise || true)"
fi
[[ -n "${MISE_BIN}" ]] || die "mise is required"

cd "${ROOT_DIR}"
"${MISE_BIN}" exec -- python "${SCRIPT_DIR}/render_homebrew_cask.py" \
  "${CONFIG_PATH}" "${version}" "${sha256}" "${output}"
