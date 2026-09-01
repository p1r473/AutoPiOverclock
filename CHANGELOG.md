# Changelog

## 0.1.0-alpha.37 — 2026-09-01

- Fixed progress-line stacking after a Byobu/tmux client changed between a narrow phone viewport and a wider terminal. The renderer no longer reserves a blank row or uses vertical cursor movement, both of which can be remapped by terminal reflow.
- Repaints now erase and replace only the current logical row, park the cursor at column one, and temporarily disable autowrap without emitting a newline. The worker-stream consumer still runs in the controller shell, preserving progress state across the pipeline.
- Added byte-level narrow-to-wide-to-narrow, ordinary-output, and shutdown regressions proving that progress paints contain no newline, carriage return, cursor-up, or cursor-down controls and that only real output advances the terminal.

## 0.1.0-alpha.36 — 2026-08-31

- Closed the candidate boot/health handoff gap exposed on Tron. The reboot handshake now retains the distinct candidate boot ID before redeploying the run-isolated worker, so a second autonomous reboot during worker deployment or required health can be proved through the same clear-tryboot, owned-file-cleanup, protected-hash, stock-clock, and watchdog recovery gates used for stress failures.
- Added one bounded automatic transport supervisor across sweep, refinement, CPU/GPU qualification, edge/floor final validation, and post-stress health. A safely recovered unstructured SSH/worker loss repeats the complete affected gate up to two times; an exactly proved autonomous reboot becomes the appropriate boot/stability boundary and backs off automatically; recovery uncertainty still stops without relabeling evidence.
- Made the simple `overclock TARGET` and plain `resume TARGET` adopt the exact safely recovered alpha.35 Tron-style worker-loss checkpoint and retry it in place. Retry context/count are persisted and validated, preventing both immediate terminal exits and infinite retry loops.

## 0.1.0-alpha.35 — 2026-08-31

- Fixed linked longer-final validation so a fully recovered `BOOT_FAILURE` or `STABILITY_FAILURE` no longer stops at stock. Ambiguous combined evidence now lowers every still-overclocked domain by its existing production guard, repeats both saved-duration qualifications, and continues into a fresh edge-first final sequence without claiming whether CPU or GPU caused the reboot.
- Made the linked run's requested longer-final duration govern both alternatives after backoff: CPU +25 MHz is tested first, and a safely rejected edge starts the guarded floor for the same complete duration. Rejected source clocks are never reapplied; harness or recovery uncertainty remains fatal with verified stock active.
- Made plain `resume TARGET` adopt the exact recovered alpha.34 linked-run failure after a fresh stock-health proof, preserving source-run identity, rollback evidence, backoff history, and automatic final apply. Added regressions for both the live failure path and later direct resume.

## 0.1.0-alpha.34 — 2026-08-31

- Fixed the remaining Byobu/tmux progress-row stacking case exposed by a live narrow-to-wide layout transition. The renderer now reserves one blank cursor-anchor row beneath the display, repaints the dedicated row above it, and always returns the cursor to column one of the anchor instead of leaving it at the variable-length end of the bar.
- Kept the worker-stream progress consumer in the controller shell with Bash `lastpipe`, restoring the caller's prior shell option afterward. Cursor-anchor and telemetry state therefore survive worker completion and cannot diverge from the terminal state through a pipeline subshell.
- Added byte-level regressions for one-time row reservation, narrow-to-wide repainting, balanced cursor-up/down movement, no carriage returns, autowrap restoration, parent-shell state preservation, and shutdown clearing. Non-TTY output and retained raw telemetry remain unchanged.

## 0.1.0-alpha.33 — 2026-08-31

- Replaced the public 8-hour-floor-then-optional-edge order with one default edge-first final sequence. After the saved 2-hour CPU/GPU qualifications, CPU +25 MHz receives a 24-hour combined CPU/GPU/I/O test first. A pass is final; a safely rejected or known-unsafe edge starts one fresh 24-hour guarded-floor fallback instead, so a passing edge never triggers a redundant second long workload.
- Preserved automatic recovery below the new sequence: a guarded-floor pair failure still lowers every overclocked domain conservatively, repeats both qualifications, and starts a new edge-first sequence. Harness or recovery uncertainty remains fatal, and the previous edge disposition remains in immutable logs rather than being used as evidence for a different clock pair.
- Added `--restart-from current|cpu-qualification|gpu-qualification|final` to `overclock TARGET` and `resume TARGET`. Eligible pre-final runs take their clocks only from retained guarded/backoff state while accepting a new explicit duration plan; prerequisite qualifications are verified and an already-started final sequence cannot be relabeled. Direct resume of an overclock retains unattended extended SSH monitoring and automatic apply. A completed applied result may run a longer linked final validation through its verified stock rollback backup and is reapplied only after PASS.
- Corrected the progress estimate for edge-first operation: it initially budgets one long final result and dynamically adds the guarded-floor fallback only after edge rejection. The TTY bar's single-row repaint behavior remains unchanged.
- Made 24 hours the public default for both alternative final paths, retained 1–168 hour overrides, documented latest-run selection and live JSON timing, and clarified that Debian worker files are intentionally transient under `/tmp` while durable artifacts remain under `$HOME/overclock-results` and verified rollback backups remain outside temporary storage.
- Clarified that deployment requires one Raspberry Pi 5 target and one separate Linux controller; the controller is not required to be another Raspberry Pi. Fixed the worker fixture setup so library-only loading cannot accidentally suppress later executable-worker coverage.

## 0.1.0-alpha.32 — 2026-08-30

- Fixed progress rows still stacking when Byobu/tmux or a newly attached mobile client exposed a narrower viewport than the controlling terminal reported. Each repaint now temporarily disables terminal autowrap, selects a complete content-aware compact layout instead of truncating the verbose layout at the right edge, leaves an eight-column safety margin, and restores normal wrapping immediately afterward.
- Added regressions for wide, medium, narrow, consecutive-repaint, no-newline, no-autowrap, wrap-restoration, and shutdown-clear behavior. Raw telemetry, saved progress state, and non-TTY output remain unchanged.

## 0.1.0-alpha.31 — 2026-08-29

- Added simple whole-hour controls to the public automatic workflow: `--qualification-hours HOURS`, `--final-hours HOURS`, and `--edge-hours HOURS`, each accepting 1–168. Qualifications default to 2 hours, final validation defaults to 8 hours, the edge remains optional with 24 hours recommended, and `--edge-cpu-24h` remains a compatibility spelling.
- Raised run state to schema 10 and bound qualification, final, and edge durations plus a `default`/`custom` policy label immutably into each run. Repeating `overclock TARGET` inherits the saved plan, rejects mid-run duration changes, and upgrades eligible schema-9 runs with their historical qualification/edge defaults while preserving their recorded final duration.
- Made CPU/GPU qualifications, final validation, later-edge eligibility, automatic backoff/restart, progress ETA/countdown, status/report output, and permanent apply use the exact saved duration plan instead of hardcoded long-test durations. Apply still requires exact current-schema evidence; shorter custom tests trade confidence for time without bypassing recovery or health gates.
- Clarified the interactive progress line as `CPU: XMHz | GPU: YMHz`, expanded README requirements for the separate controller and target, and added a public overclock-strategy section covering CPU-first search, guarded selection, GPU qualification, combined validation, automatic recovery/backoff, optional edge testing, and final application.

## 0.1.0-alpha.30 — 2026-08-29

- Rebuilt the top of the GitHub README as a numbered public quick start: clone the repository, enter it, run the local tests, install under `/usr/local`, verify the installed version, prepare an explicit target, overclock it, and reset it when needed.
- Explained directly beside the commands that `make test` does not contact or reboot a target, separated first installation from later updates, and added a fixture contract that keeps the complete installation and three-command path in the quick-start section.

## 0.1.0-alpha.29 — 2026-08-29

- Kept the intentional extended-SSH-recovery fixtures quiet during `make test`. The tests now capture and assert both expected recovery notices instead of printing realistic target warnings into the user's terminal.
- Left production recovery messages unchanged: a real unattended overclock still reports when bounded SSH waiting becomes read-only monitoring and when the target returns for reconciliation.

## 0.1.0-alpha.28 — 2026-08-29

- Fixed interactive progress updates stacking in Byobu/tmux and mobile terminals. Each repaint now reads the controlling terminal's live width instead of trusting a stale `COLUMNS` snapshot, explicitly returns to column one and erases the existing row, emits no newline, and leaves the wrapping final column unused.
- Added narrow-pane rendering, exact cursor-control, and shutdown-cleanup regressions so a live update remains one replace-in-place terminal row.

## 0.1.0-alpha.27 — 2026-08-29

- Made automatic tuning determine CPU before GPU with a fixed evidence ladder: short 10-minute search candidates, a two-hour CPU-only qualification at stock GPU, GPU search at that qualified CPU, a two-hour GPU-only qualification, and an eight-hour combined CPU/GPU/I/O production validation.
- Made a fully recovered `BOOT_FAILURE` or `STABILITY_FAILURE` during either domain qualification lower only that domain and repeat its full qualification. A recovered ambiguous failure during combined production validation lowers every still-overclocked domain, re-runs both qualifications, and restarts the eight-hour validation without pretending to know one cause.
- Made the optional CPU +25 MHz edge a 24-hour combined CPU/GPU/I/O workload at the production-floor GPU. A later edge request still starts directly from an eligible applied floor without repeating its eight-hour validation.
- Kept unattended `autopioverclock overclock TARGET` alive after the ordinary SSH timeout in read-only recovery monitoring. It issues no repeated reboot, reconciles boot identity and owned tryboot evidence when SSH returns, and remains safely interruptible and resumable.
- Promoted screenless Raspberry Pi OS, Debian, and supported Ubuntu Pi layouts to an explicit automatic path: no display/audio baseline is required, the V3D render node is discovered dynamically, and older `stress-ng` builds receive a verified single-V3D-node fallback when device selection is unavailable.
- Added schema-9 qualification and recovery-wait evidence, schema-8 active-run migration, conservative migration of eligible recovered schema-7/8 final failures, updated progress/status/report output, and regressions for headless discovery, dynamic V3D routing, qualification backoff, paired restart, and persistent SSH recovery.

## 0.1.0-alpha.26 — 2026-08-28

- Removed the historical postfix `TARGET reset` compatibility form. Stock reset now has one unambiguous spelling: `autopioverclock reset TARGET`.
- Removed the postfix form from current help and documentation, reject it locally before SSH, and added regression coverage for the single supported command order.

## 0.1.0-alpha.25 — 2026-08-28

- Made a fully recovered `STABILITY_FAILURE` during ordinary combined endurance a conservative pair-level boundary: every still-overclocked domain steps down by its production guard (CPU 50 MHz, GPU 25 MHz) and complete final validation restarts without claiming which domain caused the reboot.
- Limited paired backoff to current-schema automatic runs with verified normal recovery and completely cleared owned tryboot evidence; boot, harness, recovery, optional-edge, and legacy combined-endurance failures retain their existing fail-closed behavior.
- Made repeating `autopioverclock overclock TARGET` adopt an eligible recovered schema-8 endurance failure, while an ordinary user interruption repeats the interrupted workload at the same clocks rather than inventing a stability boundary.
- Cleared the interactive progress line immediately on `INT`, `TERM`, `HUP`, or ordinary exit and suppressed repainting while exit-trap normal recovery emits output.
- Added paired-history validation, current/legacy continuation selection, complete validation-restart, and progress-shutdown regressions; updated the public recovery and output contracts.

## 0.1.0-alpha.24 — 2026-08-28

- Added a controller-side interactive whole-workflow progress bar with target identity, active clocks, current/run-maximum temperature, throttle state, activity, dynamically replanned approximate percentage/ETA, and approximate tests remaining.
- Added a worker-elapsed current-stress countdown while preserving every unmodified telemetry line in retained candidate/main logs; redirected and noninteractive execution keeps ordinary newline-delimited telemetry without terminal control updates.
- Added `autopioverclock test TARGET --cpu MHZ --gpu MHZ --minutes MINUTES` for one exact CPU/GPU stability test through the existing tryboot ownership, watchdog, maximum-cooling, repeated boot/recovery, health, protected-hash, and final normal-recovery gates.
- Kept manual test results evidence-only: they record exact clocks, duration, classification, and maximum temperature with `VALIDATED=0`, create no recommendation, never modify permanent clocks, and are explicitly rejected by `apply` regardless of duration.
- Made repeating an identical interrupted manual command recover and continue its saved plan while refusing clock, duration, or cooling-policy changes mid-test.
- Added CLI, configuration/state, lifecycle, apply-refusal, telemetry parsing, progress-estimate, countdown, and terminal-width regressions, plus public documentation for both features and their validation limits.

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
