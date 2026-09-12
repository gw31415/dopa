#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
BUILD_ROOT="${ROOT_DIR}/.build"
SOCKET_NAME="ipc/control.sock"

usage() {
  cat <<'EOF'
Usage: scripts/run-ui-fixture.sh [--help]

Build and launch the isolated dopa UI fixture with a mock-power daemon.
The fixture uses a temporary directory under /tmp and cleans up both
fixture processes when the UI exits.
EOF
}

die() {
  printf 'run-ui-fixture: %s\n' "$*" >&2
  exit 1
}

case "${1:-}" in
  '') ;;
  --help|-h)
    usage
    exit 0
    ;;
  *)
    usage >&2
    die "unknown argument: $1"
    ;;
esac

if [[ -x /opt/homebrew/bin/mise ]]; then
  MISE_BIN=/opt/homebrew/bin/mise
else
  MISE_BIN="$(command -v mise || true)"
fi
[[ -n "${MISE_BIN}" ]] || die "mise is required to select Swift"

printf 'Building the UI fixture…\n'
"${SCRIPT_DIR}/build-app.sh" --ui-test-fixture

printf 'Building the test daemon harness…\n'
(cd "${ROOT_DIR}" && "${MISE_BIN}" exec -- swift build --product DopaTestHarness)
HARNESS_BIN="$(cd "${ROOT_DIR}" && "${MISE_BIN}" exec -- swift build --product DopaTestHarness --show-bin-path)/DopaTestHarness"
[[ -x "${HARNESS_BIN}" ]] || die "SwiftPM did not produce ${HARNESS_BIN}"

FIXTURE_DIR="$(mktemp -d /tmp/dopa-ui.XXXXXX)"
HARNESS_PID=''
UI_PID=''

cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM

  if [[ -n "${UI_PID}" ]]; then
    kill "${UI_PID}" 2>/dev/null || true
    wait "${UI_PID}" 2>/dev/null || true
  fi
  if [[ -n "${HARNESS_PID}" ]]; then
    kill "${HARNESS_PID}" 2>/dev/null || true
    wait "${HARNESS_PID}" 2>/dev/null || true
  fi
  rm -rf -- "${FIXTURE_DIR}"
  exit "${status}"
}
trap cleanup EXIT HUP INT TERM

printf '0' > "${FIXTURE_DIR}/power"
printf '0' > "${FIXTURE_DIR}/lid"

SOCKET_PATH="${FIXTURE_DIR}/${SOCKET_NAME}"
printf 'Starting the mock-power daemon…\n'
(
  cd "${ROOT_DIR}"
  exec env DOPA_TEST_DIRECTORY="${FIXTURE_DIR}" \
    DOPA_TEST_DAEMON=1 \
    DOPA_TEST_ADMIN_AUTH=1 \
    "${HARNESS_BIN}"
) &
HARNESS_PID=$!

deadline=$((SECONDS + 10))
while [[ ! -S "${SOCKET_PATH}" ]]; do
  if ! kill -0 "${HARNESS_PID}" 2>/dev/null; then
    wait "${HARNESS_PID}" || die "test daemon harness exited before creating ${SOCKET_PATH}"
  fi
  if (( SECONDS >= deadline )); then
    die "timed out waiting for ${SOCKET_PATH}"
  fi
  sleep 0.05
done

APP_BIN="${BUILD_ROOT}/Dopa-Test.app/Contents/MacOS/dopa-ui"
[[ -x "${APP_BIN}" ]] || die "missing ${APP_BIN}"
printf 'Launching the UI fixture…\n'
"${APP_BIN}" --test-socket "${SOCKET_PATH}" &
UI_PID=$!

wait "${UI_PID}"
