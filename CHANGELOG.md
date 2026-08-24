# Changelog

## 0.1.0-alpha.8 — 2026-08-24

- Made `--mode auto` with no configuration file free of candidate-parameter prompts: it now discovers the permanent baseline first, then generates CPU candidates in 100 MHz steps through 3200 MHz and GPU/V3D candidates in 50 MHz steps through 1200 MHz while preserving the existing voltage.
- Kept explicit configuration files authoritative and retained the separate ordinary tuning confirmation, while persisting generated candidates into state, effective configuration, summaries, and GPU dependency decisions.
- Added regressions proving auto candidate resolution leaves stdin untouched, produces deterministic representative Debian and Batocera plans, persists the resolved configuration and GPU requirement, respects ceilings and explicit configs, rejects oversized discovered clocks without arithmetic overflow, and rejects a live run when both automatic domains are exhausted.

## 0.1.0-alpha.7 — 2026-08-24

- Accepted current `wpctl inspect` output that prefixes the default sink's `node.name` property with `*`, while retaining the older unstarred format on both Debian and Batocera.
- Added an identity-bound ARM64 Batocera fallback for systems whose watchdog driver omits the sysfs `timeout` attribute: the worker duplicates the already-open keeper descriptor with `pidfd_getfd` and issues only `WDIOC_GETTIMEOUT`, failing closed on malformed sysfs evidence, ownership changes, unsupported kernels, permission denial, or races.
- Tightened watchdog sysfs parsing and device binding, kept Debian watchdog behavior unchanged, and added selector, malformed-input, owner-race, embedded-Python syntax, and forbidden-operation regressions.

## 0.1.0-alpha.6 — 2026-08-23

- Fixed Debian GPU-stressor discovery so `pipefail` cannot turn `grep`'s early help-text exit into a false unavailable result after a successful `stress-ng` installation.
- Tightened capability matching to the exact `--gpu` option and added a large-output regression that distinguishes it from longer option names.

## 0.1.0-alpha.5 — 2026-08-23

- Fixed the live worker-upload wrapper so nested root and passwordless-sudo execution preserves strict pre-install and post-install SHA-256 verification under `set -Eeuo pipefail`.
- Added execution-level upload regression coverage for exact multiline bytes, mode 700 installation, safe path punctuation, temporary-file cleanup, and rejection of corrupted streams.

## 0.1.0-alpha.4 — 2026-08-23

- Recorded project-owner approval of the public `KEY=VALUE` configuration schema.
- Implemented exactly the approved 13 lowercase configuration keys and rejected the earlier uppercase and unapproved settings.
- Added configurable 1–60 second telemetry sampling, 2–10 candidate boot cycles, and 3–10 final boot cycles while preserving fail-closed resumability.
- Raised the run and validation schemas from 2 to 3 so older state cannot bypass the new configuration and validation gates.
- Replaced the private-review terms with the Apache License 2.0 for public open-source distribution and contributions.
- Rebuilt the README around the recovery model, safety invariants, live-validation status, and a staged first-hardware-run workflow.
- Added discovery-first configuration templates with deliberately empty candidate lists so public onboarding never imports fixed clock assumptions.
- Removed silent normal-clock/voltage fallbacks and exposed exact dependency evidence in read-only plans.
- Made the first hardware path configuration-free and evidence-first: read-only discovery, independent factory-stock review, a normal-clock tryboot/watchdog/recovery proof, then fresh candidates chosen without remembered host tuning values.
- Refused live runs when any `tryboot.txt` already exists; added per-attempt random ownership tokens, persisted reservation/completed hashes and quarantine paths, no-clobber held-descriptor creation, exact pre-trigger verification, and post-recovery quarantine/revalidation before removal.
- Added random-suffixed run IDs, run-isolated remote workers, durable state flushes, and a target-side mutation lock shared by tryboot, normal-reboot, watchdog-repair, apply, and rollback operations.
- Documented the supported ARM64 Debian-family Batocera payload-builder prerequisites and narrowed `resume` to interruptions after tuning confirmation.
- Kept Debian display validation mandatory while allowing a graphical target with no desktop audio server; captured or explicitly required audio remains enforced, and Batocera's mandatory graphical audio baseline is unchanged.

## 0.1.0-alpha.3 — 2026-08-23

- Replaced raw `config.txt` watchdog inference with active recovery-chain proof: a positive EEPROM `BOOT_WATCHDOG_TIMEOUT`, positive `watchdog.open_timeout` on the running kernel command line, a live watchdog device with a positive runtime timeout, and an actual userspace file-descriptor owner. Debian also retains its systemd runtime-watchdog gate.
- Added planned, hash-tracked Debian watchdog remediation and fail-closed reporting for interrupted or unverified preflight changes.
- Added atomic candidate and final-validation substages so resume repeats any same-boot evidence it cannot safely preserve instead of skipping a gate or restarting completed work.
- Added automatic graphical default-audio-sink baseline capture and identity verification throughout candidate, recovery, and apply health checks.
- Restricted permanent apply to `PASS`/`COMPLETE` runs carrying the current validation schema and a saved final endurance duration of at least 28,800 seconds.
- Hardened interrupted apply reconciliation around persisted old/proposed hashes, deterministic backups, fresh normal-boot health, and verified rollback.
- Kept interrupted `PREPARE` state inspectable through `status` and `report` while refusing mutating resume that could adopt a partial preflight change as a new baseline.
- Public release remains blocked pending explicit approval of the configuration schema and selection of an open-source license.

## 0.1.0-alpha.2 — 2026-08-22

- Initial local Git-ready alpha.
- Debian and Batocera workers.
- Recoverable tryboot state machine and atomic resume state.
- Mandatory Batocera GPU renderer smoke gate and fail-fast child supervision.
- Bounded stress overrun deadlines and requested-clock attainment gates.
- Nonblocking filesystem activity supervision during endurance validation.
- Flat structured artifacts, reporting, exact-diff apply, and rollback path.
- Portable Batocera glmark2 bundle builder.
- Static and fixture regression tests.
