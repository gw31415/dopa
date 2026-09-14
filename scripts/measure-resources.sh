#!/usr/bin/env bash
#
# Reproducible resource measurement for dopa-daemon.
#
# Spawns DopaTestHarness as a fixture daemon (DOPA_TEST_DAEMON=1) on a private
# socket and state directory, drives one of three load scenarios, and samples
# CPU time, %CPU, RSS/VSZ, and open FDs. The production service, user defaults,
# and managed files are never touched. All spawned processes, sockets, and
# state directories belong to this script and are removed on exit.
#
# Usage:
#   scripts/measure-resources.sh [--scenario idle|monitor|owner]
#                                [--duration SEC] [--warmup SEC]
#                                [--clients N]
#                                [--harness PATH] [--out DIR]
#
# A measurement is only comparable with the same release harness binary, SDK,
# OS, machine, and scenario. Short runs validate the harness; adoption-grade
# baselines use --duration 60 repeated 3 times after warm-up (see
# docs/resource-measurements.md).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"

SCENARIO="idle"
DURATION="60"
WARMUP="5"
CLIENTS="1"
HARNESS=""
OUT=""

usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}"
  echo "Usage: scripts/measure-resources.sh [options]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scenario|--duration|--warmup|--clients|--harness|--out)
      [[ $# -ge 2 ]] || {
        echo "missing value for $1" >&2
        exit 2
      }
      [[ -n "$2" ]] || {
        echo "missing value for $1" >&2
        exit 2
      }
      case "$1" in
        --scenario) SCENARIO="$2" ;;
        --duration) DURATION="$2" ;;
        --warmup) WARMUP="$2" ;;
        --clients) CLIENTS="$2" ;;
        --harness) HARNESS="$2" ;;
        --out) OUT="$2" ;;
      esac
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "${SCENARIO}" in
  idle|monitor|owner) ;;
  *) echo "scenario must be idle, monitor, or owner" >&2; exit 2 ;;
esac

[[ "${CLIENTS}" =~ ^[0-9]+$ ]] && (( CLIENTS >= 1 && CLIENTS <= 64 )) || {
  echo "clients must be an integer from 1 through 64" >&2
  exit 2
}
NUMBER_PATTERN='^([0-9]+([.][0-9]*)?|[.][0-9]+)$'
[[ "${DURATION}" =~ ${NUMBER_PATTERN} ]] \
  && awk -v value="${DURATION}" 'BEGIN { exit !(value > 0) }' || {
  echo "duration must be a finite number greater than zero" >&2
  exit 2
}
[[ "${WARMUP}" =~ ${NUMBER_PATTERN} ]] \
  && awk -v value="${WARMUP}" 'BEGIN { exit !(value >= 0) }' || {
  echo "warmup must be a finite nonnegative number" >&2
  exit 2
}

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required for the scenario driver" >&2
  exit 2
fi

# BSD date on older supported macOS releases does not implement `%N`. Prefer
# date where it returns a numeric fractional timestamp (lower measurement
# overhead), and use the already-required Python runtime as the compatibility
# fallback.
DATE_TIMESTAMP_PROBE="$(date +%s.%N 2>/dev/null || true)"
if [[ "${DATE_TIMESTAMP_PROBE}" =~ ^[0-9]+[.][0-9]+$ ]]; then
  CLOCK_SOURCE="date-percent-N"
  wall_timestamp() { date +%s.%N; }
else
  CLOCK_SOURCE="python-time_ns"
  wall_timestamp() {
    python3 -c 'import time; print(f"{time.time_ns() / 1_000_000_000:.9f}")'
  }
fi
if [[ -x /opt/homebrew/bin/mise ]]; then
  MISE_BIN=/opt/homebrew/bin/mise
else
  MISE_BIN="$(command -v mise || true)"
fi
[[ -n "${MISE_BIN}" ]] || { echo "mise is required to build the measurement harness" >&2; exit 2; }

if [[ -z "${HARNESS}" ]]; then
  # Build the current source in a deterministic release location. Picking the
  # first file under .build can silently measure a stale debug or old-SDK copy.
  (cd "${ROOT_DIR}" && "${MISE_BIN}" exec -- swift build \
    --configuration release --target DopaTestHarness) >&2
  BIN_DIR="$(cd "${ROOT_DIR}" && "${MISE_BIN}" exec -- swift build \
    --configuration release --show-bin-path)"
  HARNESS="${BIN_DIR}/DopaTestHarness"
fi
if [[ -z "${HARNESS}" || ! -x "${HARNESS}" ]]; then
  echo "DopaTestHarness not found; build it first (e.g. mise exec -- swift build --build-tests)" >&2
  exit 2
fi
if [[ -z "${OUT}" ]]; then
  OUT="$(mktemp -d /tmp/dopa-measure.XXXXXX)"
else
  [[ ! -e "${OUT}" ]] || {
    echo "output path already exists: ${OUT}" >&2
    exit 2
  }
  mkdir -p "${OUT}"
fi

HARNESS_SHA256="$(shasum -a 256 "${HARNESS}" | awk '{print $1}')"
GIT_REVISION="$(git -C "${ROOT_DIR}" rev-parse --verify HEAD 2>/dev/null || echo unknown)"
if [[ "${GIT_REVISION}" != unknown ]] \
  && [[ -n "$(git -C "${ROOT_DIR}" status --porcelain --untracked-files=all)" ]]; then
  GIT_REVISION="${GIT_REVISION}+dirty"
fi
MACHINE_MODEL="$(sysctl -n hw.model 2>/dev/null || uname -m)"

STATE_DIR="$(mktemp -d /tmp/dopa-measure-state.XXXXXX)"
SOCK="${STATE_DIR}/ipc/control.sock"
DAEMON_PID=""
CLIENT_PIDS=""
CLIENT_STOP="${OUT}/clients.stop"

cleanup() {
  local pid
  for pid in ${CLIENT_PIDS}; do
    if kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}" 2>/dev/null || true
    fi
  done
  # Reap every driver even on an error path, so no background child is left
  # behind and its socket is closed before the temporary state is removed.
  for pid in ${CLIENT_PIDS}; do
    wait "${pid}" 2>/dev/null || true
  done
  CLIENT_PIDS=""
  if [[ -n "${DAEMON_PID}" ]]; then
    if kill -0 "${DAEMON_PID}" 2>/dev/null; then
      kill -TERM "${DAEMON_PID}" 2>/dev/null || true
      for _ in $(seq 1 50); do
        kill -0 "${DAEMON_PID}" 2>/dev/null || break
        sleep 0.1
      done
      if kill -0 "${DAEMON_PID}" 2>/dev/null; then
        kill -KILL "${DAEMON_PID}" 2>/dev/null || true
      fi
    fi
    wait "${DAEMON_PID}" 2>/dev/null || true
    DAEMON_PID=""
  fi
  rm -rf "${STATE_DIR}"
}
trap cleanup EXIT

mkdir -p "${STATE_DIR}/ipc"
printf '0' > "${STATE_DIR}/power"
rm -f "${CLIENT_STOP}"
rm -f "${OUT}"/ipc-counters-*.txt "${OUT}"/client-*.ready \
  "${OUT}"/client-*.stdout.log "${OUT}"/client-*.stderr.log

wait_for_clients() {
  local failed=0 pid
  for pid in ${CLIENT_PIDS}; do
    if wait "${pid}"; then
      :
    else
      printf 'client driver %s failed; see %s/client-*.stderr.log\n' \
        "${pid}" "${OUT}" >&2
      failed=1
    fi
  done
  CLIENT_PIDS=""
  return "${failed}"
}

clients_are_alive() {
  local pid state
  for pid in ${CLIENT_PIDS}; do
    if ! kill -0 "${pid}" 2>/dev/null; then
      return 1
    fi
    state="$(ps -o stat= -p "${pid}" 2>/dev/null | tr -d ' ')"
    [[ "${state}" != Z* ]] || return 1
  done
}

DOPA_TEST_DIRECTORY="${STATE_DIR}" DOPA_TEST_DAEMON=1 "${HARNESS}" \
  >"${OUT}/daemon-stdout.log" 2>"${OUT}/daemon-stderr.log" &
DAEMON_PID=$!

for _ in $(seq 1 100); do
  [[ -S "${SOCK}" ]] && break
  kill -0 "${DAEMON_PID}" 2>/dev/null || {
    echo "daemon exited during startup; see ${OUT}/daemon-stderr.log" >&2
    exit 1
  }
  sleep 0.1
done
[[ -S "${SOCK}" ]] || { echo "daemon socket never appeared" >&2; exit 1; }

# Scenario drivers: one per client (a session needs its own connection).
# Each speaks hello/subscribe/acquire over the fixture socket and drains
# everything the daemon sends. The driver keeps one receive buffer across
# requests, so setup responses and events sharing a recv are all counted.
if [[ "${SCENARIO}" != "idle" ]]; then
  for i in $(seq 1 "${CLIENTS}"); do
    rm -f "${OUT}/ipc-counters-${i}.txt" "${OUT}/client-${i}.ready" \
      "${OUT}/client-${i}.stdout.log" "${OUT}/client-${i}.stderr.log"
    python3 - "${SOCK}" "${SCENARIO}" \
      "${OUT}/ipc-counters-${i}.txt" "${OUT}/client-${i}.ready" "${CLIENT_STOP}" \
      "measure-${i}" \
      >"${OUT}/client-${i}.stdout.log" 2>"${OUT}/client-${i}.stderr.log" <<'PYEOF' &
import json
import os
import select
import socket
import sys
import time

path = sys.argv[1]
scenario = sys.argv[2]
counters = sys.argv[3]
ready_path = sys.argv[4]
stop_path = sys.argv[5]
name = sys.argv[6]
RECV_TIMEOUT = 5.0

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(RECV_TIMEOUT)
sock.connect(path)
buffer = b""
next_id = 1
rx_bytes = 0
rx_frames = 0
rx_events = 0

def next_message(timeout):
    global buffer, rx_bytes, rx_frames, rx_events
    deadline = time.monotonic() + timeout
    while True:
        newline = buffer.find(b"\n")
        if newline >= 0:
            line, buffer = buffer[:newline], buffer[newline + 1:]
            if not line:
                continue
            message = json.loads(line)
            rx_frames += 1
            if isinstance(message, dict) and "event" in message:
                rx_events += 1
            return message
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("timed out waiting for daemon frame")
        readable, _, _ = select.select([sock], [], [], remaining)
        if not readable:
            raise TimeoutError("timed out waiting for daemon frame")
        try:
            chunk = sock.recv(65536)
        except BlockingIOError:
            continue
        if not chunk:
            raise RuntimeError("daemon closed connection")
        rx_bytes += len(chunk)
        buffer += chunk

def request(method, params):
    global next_id
    rid = str(next_id)
    next_id += 1
    sock.sendall((json.dumps({"id": rid, "method": method, "params": params}) + "\n").encode())
    while True:
        message = next_message(RECV_TIMEOUT)
        if message.get("id") == rid:
            if "error" in message:
                raise RuntimeError(f"request failed: {message['error']}")
            return message["result"]

request("hello", {"apiVersion": 1, "client": {"name": name, "version": "0"}})
request("status.subscribe", {})
if scenario == "owner":
    request("session.acquire", {"options": {"keepDisplayOn": True}})

# The parent waits for this marker before starting warm-up. The connection is
# therefore established for both warm-up and the complete measured interval.
with open(ready_path, "w") as ready:
    ready.write("ready\n")

sock.setblocking(False)
while not os.path.exists(stop_path):
    try:
        # A finite timeout also bounds a stuck daemon; frames already buffered
        # from a previous request are processed without another recv().
        next_message(1.0)
    except TimeoutError:
        continue

with open(counters, "w") as f:
    f.write(f"rx_bytes={rx_bytes}\nrx_frames={rx_frames}\nrx_events={rx_events}\n")
PYEOF
    CLIENT_PIDS="${CLIENT_PIDS:-} $!"
  done

  # Do not begin warm-up until every driver has completed its handshake and
  # subscription. A failed driver is reported immediately.
  for i in $(seq 1 "${CLIENTS}"); do
    ready_path="${OUT}/client-${i}.ready"
    ready=0
    for _ in $(seq 1 100); do
      if [[ -f "${ready_path}" ]]; then
        ready=1
        break
      fi
      clients_are_alive || break
      sleep 0.1
    done
    (( ready )) || {
      echo "client ${i} did not become ready; see ${OUT}/client-${i}.stderr.log" >&2
      exit 1
    }
  done
fi

sleep "${WARMUP}"

if [[ -n "${CLIENT_PIDS}" ]]; then
  clients_are_alive || {
    echo "client driver exited during warm-up" >&2
    exit 1
  }
fi

SAMPLES="${OUT}/samples.tsv"
printf 't\tetime\tcputime\ts_cpu\trss_kb\tvsz_kb\tfds\n' > "${SAMPLES}"
CPU_START="$(ps -o time= -p "${DAEMON_PID}" | tr -d ' ')"
T0="$(wall_timestamp)"
END="$(awk -v start="${T0}" -v duration="${DURATION}" 'BEGIN { printf "%.6f", start + duration }')"
while true; do
  T="$(wall_timestamp)"
  awk -v now="${T}" -v end="${END}" 'BEGIN { exit !(now < end) }' || break
  kill -0 "${DAEMON_PID}" 2>/dev/null || { echo "daemon exited mid-run" >&2; exit 1; }
  if [[ -n "${CLIENT_PIDS}" ]]; then
    clients_are_alive || { echo "client driver exited mid-run" >&2; exit 1; }
  fi
  # shellcheck disable=SC2086
  read -r ETIME CPUTIME PCPU RSS VSZ <<<"$(ps -o etime=,time=,pcpu=,rss=,vsz= -p "${DAEMON_PID}" | tr -s ' ')"
  FDS="$(lsof -p "${DAEMON_PID}" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${T}" "${ETIME}" "${CPUTIME}" "${PCPU}" "${RSS}" "${VSZ}" "${FDS}" >> "${SAMPLES}"
  REMAINING="$(awk -v now="$(wall_timestamp)" -v end="${END}" \
    'BEGIN { left = end - now; if (left <= 0) print 0; else if (left < 2) print left; else print 2 }')"
  if awk -v value="${REMAINING}" 'BEGIN { exit !(value > 0) }'; then
    sleep "${REMAINING}"
  fi
done
CPU_END="$(ps -o time= -p "${DAEMON_PID}" | tr -d ' ')"
T1="$(wall_timestamp)"
MEASURE_WALL="$(awk -v start="${T0}" -v end="${T1}" 'BEGIN { print end - start }')"

if [[ -n "${CLIENT_PIDS}" ]]; then
  : > "${CLIENT_STOP}"
  wait_for_clients || { echo "one or more client drivers failed" >&2; exit 1; }
fi

STOP_T0="$(wall_timestamp)"
STOPPED="pending"
if ! kill -TERM "${DAEMON_PID}" 2>/dev/null; then
  # The daemon disappearing between the last sample and SIGTERM is an
  # abnormal fixture result. Still reap it and emit a diagnostic summary.
  STOPPED="exited-before-sigterm"
fi
for _ in $(seq 1 50); do
  if ! kill -0 "${DAEMON_PID}" 2>/dev/null; then
    break
  fi
  DAEMON_STATE="$(ps -o stat= -p "${DAEMON_PID}" 2>/dev/null | tr -d ' ' || true)"
  [[ "${DAEMON_STATE}" != Z* ]] || break
  sleep 0.1
done
STOP_T1="$(wall_timestamp)"
DAEMON_STATE="$(ps -o stat= -p "${DAEMON_PID}" 2>/dev/null | tr -d ' ' || true)"
if kill -0 "${DAEMON_PID}" 2>/dev/null && [[ "${DAEMON_STATE}" != Z* ]]; then
  kill -KILL "${DAEMON_PID}" 2>/dev/null || true
  STOPPED="killed"
fi
if wait "${DAEMON_PID}" 2>/dev/null; then
  DAEMON_STATUS=0
else
  DAEMON_STATUS=$?
fi
if [[ "${STOPPED}" == pending ]]; then
  if (( DAEMON_STATUS == 0 )); then STOPPED="graceful"
  else STOPPED="failed(exit=${DAEMON_STATUS})"
  fi
fi
DAEMON_PID=""

SYS="$(uname -srm)"
SDK="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || echo unknown)"
SWIFT="$("${MISE_BIN}" exec -- swift --version 2>/dev/null | head -n 1)"
MEASURE_CLIENTS="${CLIENTS}"
[[ "${SCENARIO}" == idle ]] && MEASURE_CLIENTS=0

python3 - "${SAMPLES}" "${CPU_START}" "${CPU_END}" "${MEASURE_WALL}" "${OUT}/summary.txt" \
  "${SCENARIO}" "${SYS}" "${SDK}" "${SWIFT}" "${HARNESS}" \
  "${STOP_T0}" "${STOP_T1}" "${STOPPED}" "${OUT}" "${MEASURE_CLIENTS}" \
  "${DURATION}" "${WARMUP}" "${HARNESS_SHA256}" "${GIT_REVISION}" "${MACHINE_MODEL}" \
  "${DAEMON_STATUS}" "${CLOCK_SOURCE}" <<'PYEOF'
import glob
import os
import sys
samples, cpu_start, cpu_end, wall, out = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4]), sys.argv[5]
scenario, sysinfo, sdk, swift, harness = sys.argv[6], sys.argv[7], sys.argv[8], sys.argv[9], sys.argv[10]
stop_t0, stop_t1, stopped, outdir, clients = float(sys.argv[11]), float(sys.argv[12]), sys.argv[13], sys.argv[14], sys.argv[15]
requested_duration, warmup = sys.argv[16], sys.argv[17]
harness_sha256, git_revision, machine_model = sys.argv[18], sys.argv[19], sys.argv[20]
daemon_status = int(sys.argv[21])
clock_source = sys.argv[22]
def to_sec(s):
    s = s.strip()
    days, rest = (s.split("-", 1) + [""])[:2] if "-" in s else ("0", s)
    parts = rest.split(":")
    total = float(parts[-1])
    if len(parts) > 1:
        total += int(parts[-2]) * 60
    if len(parts) > 2:
        total += int(parts[-3]) * 3600
    return int(days) * 86400 + total
cpu = to_sec(cpu_end) - to_sec(cpu_start)
rows = [line.split("\t") for line in open(samples).read().splitlines()[1:] if line.strip()]
rss = [int(r[4]) for r in rows]
fds = [int(r[6]) for r in rows]
ipc = ""
files = sorted(glob.glob(os.path.join(outdir, "ipc-counters-*.txt")))
expected_clients = int(clients)
try:
    total_bytes, total_frames, total_events = 0, 0, 0
    for path in files:
        values = dict(
            line.split("=", 1) for line in open(path).read().splitlines() if "=" in line)
        total_bytes += int(values.get("rx_bytes", 0))
        total_frames += int(values.get("rx_frames", 0))
        total_events += int(values.get("rx_events", 0))
    if expected_clients == 0 and files:
        raise RuntimeError(f"idle scenario unexpectedly produced {len(files)} client counters")
    if expected_clients > 0 and len(files) != expected_clients:
        raise RuntimeError(
            f"expected {expected_clients} client counters, found {len(files)}")
    ipc = f"clients={len(files)} rx_bytes={total_bytes} rx_frames={total_frames} rx_events={total_events}"
    if expected_clients == 0:
        ipc = "n/a (idle scenario has no client)"
except OSError:
    if expected_clients > 0:
        raise
    ipc = "n/a (idle scenario has no client)"
with open(out, "w") as f:
    f.write(f"scenario={scenario} clients={clients}\n")
    f.write(f"output_dir={outdir}\n")
    f.write(f"system={sysinfo}\n")
    f.write(f"machine_model={machine_model}\n")
    f.write(f"sdk={sdk}\n")
    f.write(f"swift={swift}\n")
    f.write(f"harness={harness}\n")
    f.write(f"harness_sha256={harness_sha256}\n")
    f.write(f"git_revision={git_revision}\n")
    f.write(f"requested_duration_sec={requested_duration} warmup_sec={warmup}\n")
    f.write(f"clock_source={clock_source}\n")
    f.write(f"wall_sec={wall:.3f} samples={len(rows)} sample_interval_sec=2\n")
    f.write(f"cpu_sec={cpu} cpu_per_sec={cpu / wall:.4f}\n")
    f.write(f"rss_kb_sampled_max={max(rss)} rss_kb_sampled_avg={sum(rss) / len(rss):.0f}\n")
    f.write(f"fds_sampled_max={max(fds)} fds_last={fds[-1]}\n")
    f.write(f"stop_latency_sec={stop_t1 - stop_t0:.2f} stop={stopped} exit_status={daemon_status}\n")
    f.write(f"ipc: {ipc}\n")
print(open(out).read())
PYEOF

[[ "${STOPPED}" == graceful ]] && (( DAEMON_STATUS == 0 )) || {
  echo "daemon did not exit cleanly after SIGTERM; see ${OUT}/summary.txt" >&2
  exit 1
}
