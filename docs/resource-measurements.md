# Resource measurements

## Method

`scripts/measure-resources.sh` spawns `DopaTestHarness` as a fixture daemon
(`DOPA_TEST_DAEMON=1`, file-backed mock power/controls) on a private socket
and state directory. Nothing production is touched: no launchd service, no
managed files, no user defaults. All processes, sockets, and state directories
belong to the script run and are removed on exit (results stay in `--out`).

Scenarios:

- `idle`: no peers. The daemon should sleep in `poll()` until a connection
  or stop-pipe wakeup.
- `monitor`: one subscribed client, draining everything. Covers the ~1s
  power recheck and quiet subscriber steady state. This driver does not mutate
  the mock power source, so event/broadcast load is covered by protocol tests,
  not claimed by this scenario.
- `owner`: one subscribed client holding a session with
  `keepDisplayOn=true`. Covers system and display sleep prevention and session
  steady state. The fixture power source remains stable, so this does not
  intentionally release the session.

Metrics (all from `ps`/`lsof`, no root needed):

- `cpu_per_sec`: `Δcputime / wall`. `ps` CPU time resolution is ~10ms, so
  short quiet runs read `0.0000`; that only proves "below resolution", not
  zero. Longer runs and release binaries tighten this.
- `rss_kb_sampled_max/avg`, `fds_sampled_max/last`: values observed by the
  two-second sampler. Shorter peaks can occur between samples; these are not
  process lifetime peaks.
- `stop_latency_sec`: SIGTERM to process exit. Exercises the stop self-pipe.
  The script records `clock_source`. On older macOS versions where
  `date +%s.%N` is unavailable, the `python-time_ns` fallback includes the
  second timestamp process startup in this value; compare it only with runs
  using the same clock source.
- `ipc rx_bytes/rx_frames/rx_events`: all bytes and newline-delimited frames
  received by each driver, including setup responses and events that share a
  `recv()` with a response. The receive buffer is retained between requests.
  Events appear only when the daemon emits them; a quiet mock power source can
  therefore produce zero events after setup.

## Comparability rules

Same harness binary (prefer release), SDK, OS, machine, power state, panel
state, scenario, duration, and warm-up. Drivers must become ready before
warm-up starts and remain connected through the whole warm-up and measured
interval. Warm up ≥5s, measure ≥60s, repeat 3 times. Never compare `top`
cumulative values as rates, never mix RSS with MEM, and never turn short
observations into reduction guarantees. The script records the requested
duration/warm-up, machine model, harness SHA-256, Git revision/dirty state, SDK,
Swift, and actual wall time in `summary.txt`. With no `--harness`, it first
builds the current release `DopaTestHarness`; with no `--out`, it creates a
unique directory. The directory is included as `output_dir` in the printed
summary. An explicit output path must not already exist.

Disconnect/close detection, deadline expiry, and uninstall reflection are not
measured by this sampler. Use the dedicated automated tests and the manual
acceptance procedure in `docs/acceptance.md`; record those results separately.

## Smoke runs (harness validation, not baselines)

The current script should be exercised with a short run after each harness or
driver change. Short runs validate lifecycle, cleanup, and counter plumbing;
they are not performance baselines.

2026-09-13, `Darwin 25.6.0 arm64`, MacOSX26.5 SDK, Swift 6.3.3,
release `DopaTestHarness`, one run with `--duration 2 --warmup 1` per
scenario. Harness SHA-256 is
`abbb706b7946eb12abeca1c0fcca954bb27047f593105925e1fe372f458af426`;
all three used `clock_source=date-percent-N`. The per-run summaries were
temporary and are not committed.

| scenario | cpu/sec | sampled rss max/avg (KiB) | sampled fds max/last | stop latency | ipc |
| --- | --- | --- | --- | --- | --- |
| idle | 0.0000 | 8544/8544 | 14/14 | 0.01s graceful | n/a |
| monitor | 0.0000 | 8512/8512 | 15/15 | 0.01s graceful | 1 client, 686 bytes / 2 frames / 0 events |
| owner | 0.0000 | 8560/8560 | 15/15 | 0.01s graceful | 1 client, 1382 bytes / 4 frames / 1 event |

These readings only validate the current harness and driver lifecycle. The
zero CPU values are below `ps` resolution and do not establish a reduction.
Record the command, environment, and generated `summary.txt` alongside any
new smoke table. Adoption-grade 60s×3 baselines per scenario remain open until
they are rerun with the current script.
