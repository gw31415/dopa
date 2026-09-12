#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
BUILD_ROOT="${ROOT_DIR}/.build"
INFO_PLIST_SOURCE="${ROOT_DIR}/Resources/Dopa-Info.plist"
ICON_SOURCE="${ROOT_DIR}/Resources/Dopa.icon"

usage() {
  cat <<'EOF'
Usage: scripts/build-app.sh [--ui-test-fixture]

Build and bundle the dopa menu bar app with its CLI and daemon helpers.
The fixture option uses an isolated SwiftPM scratch path and emits the UI-only
Dopa-Test.app instead of Dopa.app. Building does not install the daemon.
EOF
}

die() {
  printf 'build-app: %s\n' "$*" >&2
  exit 1
}

fixture=0
case "${1:-}" in
  '') ;;
  --ui-test-fixture) fixture=1 ;;
  --help|-h)
    usage
    exit 0
    ;;
  *)
    usage >&2
    die "unknown argument: $1"
    ;;
esac

[[ -f "${INFO_PLIST_SOURCE}" ]] || die "missing ${INFO_PLIST_SOURCE}"
[[ -d "${ICON_SOURCE}" ]] || die "missing ${ICON_SOURCE}"

ACTOOL_BIN="$(xcrun --sdk macosx --find actool 2>/dev/null || true)"
[[ -n "${ACTOOL_BIN}" ]] || die "actool is required to compile ${ICON_SOURCE}"

if [[ -x /opt/homebrew/bin/mise ]]; then
  MISE_BIN=/opt/homebrew/bin/mise
else
  MISE_BIN="$(command -v mise || true)"
fi
[[ -n "${MISE_BIN}" ]] || die "mise is required to select Swift"

swift_build_args=(build --configuration release -Xswiftc -warnings-as-errors)
products=(dopa-ui)
if (( fixture )); then
  SCRATCH_PATH="${BUILD_ROOT}/ui-fixture"
  swift_build_args+=(--scratch-path "${SCRATCH_PATH}" -Xswiftc -DDOPA_UI_TESTING)
  APP_NAME=Dopa-Test.app
  BUNDLE_IDENTIFIER=dev.amas.dopa.test
else
  SCRATCH_PATH="${BUILD_ROOT}"
  APP_NAME=Dopa.app
  BUNDLE_IDENTIFIER=dev.amas.dopa
  products+=(dopa dopa-daemon)
fi

printf 'Building %s…\n' "${APP_NAME}"
for product in "${products[@]}"; do
  (cd "${ROOT_DIR}" && "${MISE_BIN}" exec -- swift "${swift_build_args[@]}" --product "${product}")
done

BIN_DIR="$(cd "${ROOT_DIR}" && "${MISE_BIN}" exec -- swift "${swift_build_args[@]}" --show-bin-path)"
for product in "${products[@]}"; do
  [[ -x "${BIN_DIR}/${product}" ]] || die "SwiftPM did not produce ${BIN_DIR}/${product}"
done

APP_PATH="${BUILD_ROOT}/${APP_NAME}"
CONTENTS_PATH="${APP_PATH}/Contents"
MACOS_PATH="${CONTENTS_PATH}/MacOS"
HELPERS_PATH="${CONTENTS_PATH}/Helpers"
RESOURCES_PATH="${CONTENTS_PATH}/Resources"
INFO_PLIST_PATH="${CONTENTS_PATH}/Info.plist"

rm -rf "${APP_PATH}"
mkdir -p "${MACOS_PATH}" "${RESOURCES_PATH}"
install -m 0755 "${BIN_DIR}/dopa-ui" "${MACOS_PATH}/dopa-ui"
if (( ! fixture )); then
  mkdir -p "${HELPERS_PATH}"
  for helper in dopa dopa-daemon; do
    install -m 0755 "${BIN_DIR}/${helper}" "${HELPERS_PATH}/${helper}"
    codesign --force --sign - "${HELPERS_PATH}/${helper}" >/dev/null
  done
fi
cp "${INFO_PLIST_SOURCE}" "${INFO_PLIST_PATH}"

if (( fixture )); then
  plutil -replace CFBundleIdentifier -string "${BUNDLE_IDENTIFIER}" "${INFO_PLIST_PATH}"
  plutil -replace CFBundleDisplayName -string "dopa (UI test)" "${INFO_PLIST_PATH}"
fi

ICON_NAME="${ICON_SOURCE##*/}"
ICON_NAME="${ICON_NAME%.icon}"
ICON_PARTIAL_INFO="${BUILD_ROOT}/${ICON_NAME}-icon-partial.plist"
rm -f "${ICON_PARTIAL_INFO}"
printf 'Compiling %s…\n' "${ICON_SOURCE}"
if ! "${ACTOOL_BIN}" \
  --compile "${RESOURCES_PATH}" \
  --platform macosx \
  --minimum-deployment-target 26.0 \
  --app-icon "${ICON_NAME}" \
  --standalone-icon-behavior default \
  --output-partial-info-plist "${ICON_PARTIAL_INFO}" \
  "${ICON_SOURCE}"; then
  die "actool failed to compile ${ICON_SOURCE}"
fi
[[ -f "${RESOURCES_PATH}/Assets.car" ]] || die "actool did not produce Assets.car"
[[ -f "${RESOURCES_PATH}/${ICON_NAME}.icns" ]] || die "actool did not produce ${ICON_NAME}.icns"
[[ "$(plutil -extract CFBundleIconFile raw -o - "${ICON_PARTIAL_INFO}")" == "${ICON_NAME}" ]] \
  || die "actool did not declare CFBundleIconFile"
[[ "$(plutil -extract CFBundleIconName raw -o - "${ICON_PARTIAL_INFO}")" == "${ICON_NAME}" ]] \
  || die "actool did not declare CFBundleIconName"

if ! plutil -replace CFBundleIconFile -string "${ICON_NAME}" "${INFO_PLIST_PATH}" 2>/dev/null; then
  plutil -insert CFBundleIconFile -string "${ICON_NAME}" "${INFO_PLIST_PATH}"
fi
if ! plutil -replace CFBundleIconName -string "${ICON_NAME}" "${INFO_PLIST_PATH}" 2>/dev/null; then
  plutil -insert CFBundleIconName -string "${ICON_NAME}" "${INFO_PLIST_PATH}"
fi
rm -f "${ICON_PARTIAL_INFO}"

plutil -lint "${INFO_PLIST_PATH}" >/dev/null
[[ "$(plutil -extract CFBundleExecutable raw -o - "${INFO_PLIST_PATH}")" == dopa-ui ]] \
  || die "CFBundleExecutable must be dopa-ui"
[[ "$(plutil -extract CFBundleIdentifier raw -o - "${INFO_PLIST_PATH}")" == "${BUNDLE_IDENTIFIER}" ]] \
  || die "unexpected bundle identifier"
[[ "$(plutil -extract LSMinimumSystemVersion raw -o - "${INFO_PLIST_PATH}")" == 26.0 ]] \
  || die "LSMinimumSystemVersion must be 26.0"
[[ "$(plutil -extract LSUIElement raw -o - "${INFO_PLIST_PATH}")" == true ]] \
  || die "LSUIElement must be true"

codesign --force --sign - "${APP_PATH}" >/dev/null
codesign --verify --deep --strict --verbose=2 "${APP_PATH}" >/dev/null
[[ -x "${MACOS_PATH}/dopa-ui" ]] || die "missing executable dopa-ui in bundle"
codesign --verify --strict --verbose=2 "${MACOS_PATH}/dopa-ui" >/dev/null
if (( ! fixture )); then
  for helper in dopa dopa-daemon; do
    [[ -x "${HELPERS_PATH}/${helper}" ]] || die "missing executable ${helper} in bundle"
    codesign --verify --strict --verbose=2 "${HELPERS_PATH}/${helper}" >/dev/null
    # Help exits before connecting to or changing the installed service.
    "${HELPERS_PATH}/${helper}" --help >/dev/null
  done
fi

printf 'Created %s\n' "${APP_PATH}"
printf 'Executable: %s\n' "${MACOS_PATH}/dopa-ui"
if (( ! fixture )); then
  printf 'CLI: %s\n' "${HELPERS_PATH}/dopa"
  printf 'Daemon: %s\n' "${HELPERS_PATH}/dopa-daemon"
fi
printf 'Bundle ID: %s\n' "${BUNDLE_IDENTIFIER}"
