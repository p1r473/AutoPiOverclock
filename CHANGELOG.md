# Changelog

## 0.1.0-alpha.23 — 2026-08-28

- Fixed the Debian `/tmp` worker lifecycle exposed by alpha.22: one shared post-reboot handshake now waits for a changed boot ID, re-uploads the exact run-isolated worker, and only then permits candidate, recovery, watchdog, reset, or apply verification. A target that clears `/tmp` during reboot no longer produces a false missing-worker harness failure.
- Preserved the worker's structured watchdog failure class and exact reason through `prepare` instead of replacing a post-mutation `RECOVERY_FAILURE` with the generic `PREFLIGHT_FAILURE` message.
- Added default-on, state-bound maximum cooling with an explicit `--no-max-fan` new-run opt-out. The selected policy is passed through candidate planning and installation, retained across resume, shown in configuration comments, summaries, status, and reports, and cannot change midway through a run.
- Kept cooling changes strictly inside owned candidate/final tryboots. Existing permanent fan directives are preserved, normal recovery restores the user's ordinary curve automatically, and permanent apply never imports the test-only maximum-fan block.
- Added regressions for post-reboot redeployment and deployment failure, default/opt-out rendering, custom fan-curve preservation, CLI compatibility, continuation immutability, later-edge policy selection, state compatibility, and report metadata.
- Audited the README and supporting CLI, safety, architecture, and output documentation so the public three-command workflow remains the primary interface and advanced cooling/recovery details are accurate.

## 0.1.0-alpha.22 — 2026-08-28

- Allowed `autopioverclock overclock TARGET --edge-cpu-24h` to start a later CPU +25 MHz/24-hour edge validation directly from a retained, applied current-schema eight-hour floor; the completed floor endurance is not repeated.
- Created a separate linked edge run with its own immutable artifacts and apply/rollback backup identity, preserving the original eight-hour result and its stock-config backup.
- Re-proved the live applied-floor hash, clear tryboot state, normal clocks, watchdog health, and saved validation mode before the edge candidate can be staged; unknown or changed state fails closed.
- Preserved automatic graphical or headless operation exactly from the source floor, including screenless targets, and added regressions for headless continuation and direct 86,400-second endurance.
- Made repeated `overclock TARGET` calls idempotently reopen an already-applied result instead of attempting stock discovery against an intentionally tuned host.
- Added a temporary maximum-cooling policy to every candidate and final-validation tryboot: Pi 5 fan level zero starts at 0C and all four PWM levels are set to 255, while permanent apply and normal recovery preserve the user's ordinary fan curve.
- Added live `pwmfan` proof before candidate health/stress and throughout stress telemetry. A detected fan below PWM 255, malformed telemetry, or a zero tachometer aborts as harness uncertainty rather than becoming a false clock boundary; systems without a Linux PWM fan device are explicitly reported as `not-detected` and remain protected by temperature/throttle gates.
- Kept reset compatible with both the earlier five-line managed tryboot block and the new exact max-fan block while rejecting any altered fan override as foreign evidence.
- Standardized Debian's per-run worker directory, write probe, and stress I/O probe under `/tmp`; run IDs still isolate every controller and cleanup remains exact-path scoped.

## 0.1.0-alpha.21 — 2026-08-27

- Made configuration-free `overclock TARGET` treat a safely recovered stability failure during ordinary CPU-only or GPU-only final stress as a new production boundary: CPU steps down 50 MHz, GPU steps down 25 MHz, and the complete final validation restarts automatically.
- Kept combined-endurance, boot, harness, and recovery uncertainty fatal instead of guessing which clock caused it; a backoff is allowed only after verified normal recovery has cleared all owned tryboot evidence.
- Persisted a bounded, ordered final-backoff history and bound the eventual production floor, optional CPU edge, resume, and apply identities to the reduced clocks.
- Allowed repeating the same public `overclock TARGET` command to adopt the exact recovered schema-7 final-stress failure produced by alpha.20, upgrade only that narrow state to schema 8, and continue without retesting the rejected clock.
- Added regressions for GPU and CPU backoff size, complete final-validation restart, malformed-history rejection, legacy failed-run continuation, and refusal to reinterpret harness or combined-stress uncertainty.

## 0.1.0-alpha.20 — 2026-08-27

- Made `make install` copy an explicit manifest of the three Batocera watchdog assets instead of expanding `assets/batocera/*`, so an ignored Python `__pycache__` directory can never be passed to `install` as a file.
- Added an installation regression that creates the exact ignored cache directory, verifies all declared assets, and proves the cache is neither copied nor treated as an installation error.
- Made Debian graphical preparation capture audio automatically: it preserves a working PipeWire/PulseAudio default sink when available and otherwise records the sorted complete ALSA playback inventory. Graphical validation no longer silently skips audio merely because no desktop audio server is running.
- Added worker and public-safety regressions for multi-device ALSA fallback, mandatory graphical audio baselines, disappearing outputs, and the removal of the former skip warning.
- Clarified that every operational command runs on a separate controller and requires an explicit target, while keeping public README connection examples in ordinary `ssh` syntax.

## 0.1.0-alpha.19 — 2026-08-27

- Made Batocera `prepare` preserve any already-positive `BOOT_WATCHDOG_TIMEOUT` instead of unnecessarily scheduling a fixed EEPROM replacement. A target such as Tron with an active 30-second EEPROM watchdog now skips EEPROM mutation while still installing and verifying the missing kernel/userspace chain.
- Bound the detected current timeout, effective timeout, apply decision, and rendered EEPROM hash through the controller state and apply recheck so a route or EEPROM-state change cannot silently alter the approved plan.
- Retained complete `rpi-eeprom-config --apply` diagnostics in the verified watchdog backup whenever a genuinely disabled EEPROM watchdog requires scheduling and the updater fails.
- Added fixtures for positive-timeout preservation, disabled/missing timeout installation, malformed/duplicate rejection, EEPROM-apply skipping, and updater diagnostic retention.

## 0.1.0-alpha.18 — 2026-08-27

- Added a three-action normal workflow—`autopioverclock prepare TARGET`, `autopioverclock overclock TARGET`, and `autopioverclock reset TARGET`—while retaining the full expert `run`, `resume`, `status`, `recover`, `apply`, `report`, and postfix `TARGET reset` interface. Every operational command requires an explicit target.
- Made `prepare` install and verify missing workload dependencies and the complete watchdog recovery chain. Batocera now receives a project-owned keeper and service through hash-bound planning, verified backups, read-only `/boot` restoration, current-default-gateway liveness, startup grace, and bounded reboot-loop suppression.
- Made `overclock` the complete automatic operation: it selects the fixed candidate policy, retains every tryboot/recovery and validation gate, safely continues its own latest resumable current-schema run when repeated, optionally runs the final `--edge-cpu-24h` test, displays the exact permanent diff, applies only a validated result, and verifies the post-apply reboot without a second ordinary prompt.
- Made command-first `reset TARGET` the normal spelling while retaining the historical postfix form, without weakening reset's protected-hash, watchdog, stock-clock, backup, or artifact-preservation gates.
- Added simple-CLI and Batocera-watchdog installer fixtures and updated public documentation around the three-command contract.
- Added a standard `make install` layout and a PATH entry-point test so public examples use the installed `autopioverclock` command instead of repository-relative paths.

## 0.1.0-alpha.17 — 2026-08-26

- Distinguished a proven autonomous reboot during active candidate or final stress from an ordinary SSH interruption: recovery must observe the saved candidate boot ID change to a clear normal boot before the controller issues any reboot.
- Promoted only an unstructured stress-result fallback with that exact reboot proof from `HARNESS_FAILURE` to `STABILITY_FAILURE`, allowing automatic sweeps to record the clock as a boundary and continue refinement; same-boot transport loss and structured harness failures remain fatal harness uncertainty.
- Preserved `RECOVERY_FAILURE` precedence whenever normal boot, tryboot cleanup, permanent-config evidence, or normal health cannot be verified, and retained a previously validated production floor when an optional edge test ends in a proven autonomous reboot and verified normal recovery.
- Added structured-result, autonomous-reboot, same-boot transport, recovery-precedence, candidate-resume, and optional-edge regressions without changing the run-state schema.

## 0.1.0-alpha.16 — 2026-08-25

- Constrained Batocera's OpenSSL CPU load to one 16 KiB SHA-256 benchmark measured in elapsed time, so a requested stress duration is the total run time instead of being repeated once for every default buffer size.
- Preserved the independent 60-second hard shutdown deadline and its failure classification; a genuinely stuck worker is still terminated and never reinterpreted as a successful timeout.
- Made SSH and reboot wait limits account for time spent inside connection attempts, preventing a nominal five-minute recovery timeout from stretching to roughly eighteen minutes on an unreachable target.
- Added regressions for the exact one-block OpenSSL invocation and wall-time-based SSH/reboot deadline accounting.

## 0.1.0-alpha.15 — 2026-08-25

- Added the exact postfix `./autopioverclock TARGET reset` action as a standalone, noninteractive stock-reset workflow while preserving the historical interpretation of `run reset` and lone `reset` as a target hostname.
- Made reset create and verify persistent, no-clobber boot-config backups; retain standalone disabled clock/voltage directives as audit comments while removing the clock directives and markers from one structurally valid AutoPiOverclock managed block without losing its `[all]` section boundary; and fail closed on includes, symlinked or changing configs, malformed markers, and foreign or ambiguous tryboot paths.
- Required a fresh permanent-config reboot, changed boot ID, exact post-reset hash, clear tryboot state, active Raspberry Pi 5 stock clocks, current throttle/power proof, and the active watchdog chain before `COMPLETE/STOCK_VERIFIED` success, without claiming tuning's broader health gates.
- Kept reset independent of prompts, tuning/run-selection flags, terminal multiplexers, and process-wide signaling, while preserving all previous logs and saved runs and recording a separate reset audit.
- Added postfix-parser compatibility, option-exclusivity, artifact/process preservation, controller dispatch, persistent-backup, and dual-worker reset contract regressions.

## 0.1.0-alpha.14 — 2026-08-25

- Expanded current-boot kernel-journal failure detection on both Debian-family and Batocera workers to fail immediately on direct kernel panic, ARM internal-error and unable-to-handle-kernel reports, RCU stalls and starvation/timer failures, and hung-task warnings.
- Applied the same signatures to unstructured controller fallback classification so a truncated worker result is still classified as a stability failure, and added per-signature regressions plus a benign RCU-initialization negative control.

## 0.1.0-alpha.13 — 2026-08-25

- Made configuration-free auto mode fail closed unless the active Raspberry Pi 5 baseline is stock: 2400 MHz CPU, a recognized 800/960 MHz firmware-stock V3D clock, zero voltage delta, and no explicit boost, turbo, fixed-clock, `*_freq`/`*_freq_min`, or `over_voltage*` control in one stable before/after-hashed root-config snapshot. Any snapshot change or `include` directive is ambiguous until all content is bound to the protected permanent-config hash. Existing overclocks are reported rather than reinterpreted as the baseline or rewritten automatically.
- Kept stock as the dedicated recovery control, then retained 100 MHz CPU and 50 MHz V3D coarse ascent while adding resumable 25 MHz refinement inside the first genuine passing-to-failing gap.
- Replaced automatic list-position backoff with candidate-tested MHz guards: 50 MHz below the refined CPU boundary and 25 MHz below the V3D boundary, including explicit guard candidates when the desired clock was not part of the coarse list.
- Added optional `--edge-cpu-24h`: first validate the ordinary production floor for eight hours, then try CPU 25 MHz higher through a fresh 24-hour complete validation. A safely recovered boot/stability rejection retains the validated floor; harness and recovery failures remain fatal.
- Bound automatic resume/apply to immutable stock provenance, the exact deterministic candidate/refinement topology, guarded final-clock identity, and persisted 8-hour/24-hour endurance evidence so edited or stale checkpoints fail closed.
- Raised run and validation schemas to 7 and added immutable stock provenance, resumable boundary/refinement/guard state, exact endurance-duration evidence, production-floor identity, edge-target disposition, and edge-failure evidence to status/report artifacts.
- Added regressions for stock tuple acceptance/rejection, deterministic coarse plans, 25 MHz CPU/GPU refinement, tested guard selection, ceiling guards, 24-hour edge success, and validated-floor retention after an edge stability failure.

## 0.1.0-alpha.12 — 2026-08-24

- Moved Batocera graphical GPU stress from direct DRM/VT ownership to an off-screen Wayland workload on the live EmulationStation compositor, leaving the frontend running and eliminating the KMS teardown and VT-switch recovery boundary.
- Added fail-closed discovery of the frontend's Wayland runtime and socket, distinct graphical/headless backend markers, and retained off-screen DRM only for headless operation.
- Extended the portable Batocera bundle with `glmark2-es2-wayland`, rebuilt stale cached bundles that lack either required backend, and verified both executables before activation.
- Distinguished a verified permanent-config mismatch from unavailable or malformed remote hash evidence, preserving the primary worker failure across a transport outage so normal recovery can re-verify the exact hash after SSH returns.
- Added regressions for Wayland session selection, unsafe or ambiguous socket rejection, backend isolation, forbidden frontend/VT calls, and post-stress hash outcomes.

## 0.1.0-alpha.11 — 2026-08-24

- Worked around glmark2 2023.01's DRM canvas-initialization defect by replacing `--fullscreen` with an explicit positive request size guaranteed to differ from the connected native mode; the DRM backend still creates its scanout surface at the kernel-reported mode.
- Added regressions for ordinary, matching-native, and malformed display baselines, and made the retained `GPU_STRATEGY` marker newline-terminated.

## 0.1.0-alpha.10 — 2026-08-24

- Fixed Batocera graphical GPU stress to allocate a free temporary VT instead of force-reusing the active frontend VT, preventing `openvt` rc=8 from trying to deallocate `tty1`.
- Reopened the retained GPU log from inside the VT child so hardware-renderer and score evidence is captured even though `openvt` redirects child stdio to the console.
- Limited failed frontend restoration to one bounded attempt and added a fail-closed, hash-verified normal reboot that may run only after a Batocera graphical smoke recovery failure with completely clear tryboot ownership state.
- Added regressions for safe `openvt` arguments, child-output and exit-code propagation, direct fallback, single-attempt frontend cleanup, and guarded pre/post-reboot recovery checks.

## 0.1.0-alpha.9 — 2026-08-24

- Replaced Batocera `/boot` mount-option verification with a shell parser that does not assign to awk's reserved `index` builtin, fixing the false remount failure that occurred before the first candidate was written.
- Added direct read-only and read-write mount-table regressions while forcing `awk` itself to fail, so the production verifier and its exact target portability boundary are exercised.

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
