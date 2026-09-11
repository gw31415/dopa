# Remaining hardware acceptance

Follow docs/acceptance.md on a Mac with no external display. Record the macOS version, model, power source, and observed results.

- [ ] Verify actual SleepDisabled enable/readback and restoration.
- [ ] Confirm sustained closed-lid execution on AC and battery power.
- [ ] Verify physical lid closure restores and exits with --stop-on-lid-close.
- [ ] Confirm --keep-display-on across the normal idle display timeout.
- [ ] Exercise power-source transitions and recovery after guardian loss.

For each case, confirm the final system setting and recovery journal state before proceeding. Read-only API probes and simulated process tests do not replace these observations.
