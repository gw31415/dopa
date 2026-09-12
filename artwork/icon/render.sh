#!/usr/bin/env bash
set -euo pipefail

ARTWORK_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -- "${ARTWORK_DIR}/../.." && pwd -P)"
XCODE_CONTENTS="$(cd -- "$(xcode-select -p)/.." && pwd -P)"
ICTOOL="${XCODE_CONTENTS}/Applications/Icon Composer.app/Contents/Executables/ictool"
if [[ ! -x "${ICTOOL}" ]]; then
  ICTOOL="/Applications/Icon Composer.app/Contents/Executables/ictool"
fi
[[ -x "${ICTOOL}" ]] || { printf 'Icon Composer is required.\n' >&2; exit 1; }

mkdir -p "${ARTWORK_DIR}/renders"
for rendition in Default Dark ClearLight ClearDark TintedLight TintedDark; do
  filename="$(printf '%s' "${rendition}" | tr '[:upper:]' '[:lower:]')"
  "${ICTOOL}" "${ROOT_DIR}/Resources/Dopa.icon" \
    --export-image --output-file "${ARTWORK_DIR}/renders/${filename}.png" \
    --platform macOS --rendition "${rendition}" \
    --width 1024 --height 1024 --scale 1
done
