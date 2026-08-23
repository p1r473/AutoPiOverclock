# Safety and failure policy

AutoPiOverclock optimizes for recoverability and long-term stability rather than the highest benchmark number.

A candidate fails immediately on any current-boot undervoltage/throttle flag, thermal ceiling event, V3D/DRM fault, kernel Oops/BUG/call trace, USB-device reset, device-offline event, I/O error, buffer error, ext4/btrfs error, nonzero stress process, missing renderer proof, required graphical/audio/service failure, watchdog-chain failure, unexpected reboot, or permanent-config hash change.

`BOOT_FAILURE` and `STABILITY_FAILURE` define a sweep boundary. A lower passing candidate can still proceed to conservative selection. `HARNESS_FAILURE` and `RECOVERY_FAILURE` abort the run because they do not establish a silicon stability boundary.

A maximum observed pass is never called “rock solid.” The backed-off recommendation remains distinct from final clocks. Final clocks are recorded only after CPU-only validation, GPU-only validation whenever GPU load is required, combined endurance, filesystem activity, post-stress health, the configured `final_boots` additional candidate boots and normal recoveries, and a final permanent-config hash check. The approved floor is three final boot/recovery cycles.

## Tryboot file ownership and cleanup

Read-only discovery records whether `tryboot.txt` already exists and, when present, its hash. A live `run` requires that file to be absent and refuses to overwrite any pre-existing file, regardless of its contents or apparent origin. The operator must inspect and resolve an existing file explicitly before starting a new run.

Each candidate attempt receives a fresh 256-bit random ownership token. Before the worker can create a remote path, atomic controller state records that token, the exact completed-file hash, the header-reservation hash, and a token-specific quarantine path. The worker creates `tryboot.txt` with shell no-clobber semantics, writes through the held file descriptor, and proves that the pathname still names the same completed, token-bound file. A concurrently appearing operator file is never overwritten. Immediately before reboot, the trigger path again verifies the permanent hash and exact completed candidate.

Controller state is flushed before its atomic rename and the committed state file and containing directory are flushed afterward. Run IDs include a random suffix, target worker paths are isolated by run, and tryboot staging/trigger/cleanup, normal reboot, watchdog repair, permanent apply, and rollback share an atomic `/run` lock. Permanent apply rechecks normal-boot/tryboot absence after typed confirmation, inside the locked worker immediately before replacement, and again after its verification boot.

The controller treats the candidate as possibly live until a separate boot into the untouched permanent configuration proves the tryboot flag clear and the original permanent hash unchanged. Cleanup accepts only the saved completed candidate, exact reservation, or token-header partial file. It uses a no-clobber move to the saved random quarantine path, revalidates ownership after the move, and only then removes it, before the full normal health and watchdog gate. A changed, unowned, ambiguous, or raced file is preserved—at its original or quarantine path—and reported as a recovery failure. An absent live and quarantine path is already clean.

The baseline recovery proof uses the discovered normal clocks before any fresh overclock candidate. It must prove the complete tryboot boot, normal recovery, ownership-checked cleanup, and watchdog chain. A failure aborts the run rather than becoming evidence about clock stability.

## Active watchdog proof

The recovery gate does not infer readiness from an arbitrary `config.txt` line. It requires all of the following on the running target:

1. a positive EEPROM `BOOT_WATCHDOG_TIMEOUT`;
2. a positive `watchdog.open_timeout` handed to the active kernel command line;
3. a watchdog character device whose live sysfs timeout is positive; and
4. a userspace process with an open file descriptor for that device.

Debian additionally requires an active, nonzero systemd runtime-watchdog setting during discovery and after any approved repair. Batocera replacement remains manual because watchdog ownership is installation-specific. Every candidate and normal-boot health gate rechecks the four live conditions above, including the device's current timeout and owner.

## Resume boundaries

Candidate and final-validation operations are checkpointed as explicit substages. Their configured boot loops use range-checked `BOOT_n`/`NORMAL_n` stages: `candidate_boots` is limited to 2–10 and `final_boots` to 3–10. After the ordinary tuning confirmation, resume normalizes any interrupted tryboot first, verifies normal recovery, ownership-checks cleanup, continues completed work, and repeats a boot or stress segment whenever its same-boot evidence was lost. A run from an older state schema is not mutably resumed through newer safety gates.

`telemetry_interval_seconds` is limited to 1–60 seconds and controls target-side sampling during stress. Every sample rechecks temperature, current/new throttle evidence, requested-clock attainment, kernel faults, and supervised workload state; the worker's hard deadline remains separate from the sampling cadence.

An interrupted preflight, failed preflight, or declined tuning confirmation remains readable through `status` and `report`, including any watchdog-repair hashes. It is not mutably resumable: resolve the finding and start a new `run`, because partial dependency or watchdog changes must not become a trusted permanent baseline without a new normal-boot preflight.

## Permanent apply

Permanent apply requires current validation-schema evidence, `PASS`/`COMPLETE` state, and at least 28,800 saved final-endurance seconds. It persists the old and proposed hashes, deterministic backup path, boot ID, and recovery intent before remote mutation. Resume reconciles a known old hash by fresh normal-boot health, a known proposed hash by fresh normal-boot health or verified rollback, and refuses to overwrite an unknown hash. Rollback passes the persisted proposed hash into the locked worker and verifies that exact destination hash both on entry and immediately before replacing it with the verified backup.

Fresh and interrupted permanent-apply paths share the same fail-closed gate: current state schema, no saved tryboot ownership/quarantine evidence, a readable cleared live tryboot flag, and an absent `tryboot.txt`. `--yes` does not bypass the exact typed apply confirmation. A config that already matches the proposal still requires a fresh normal boot and health gate before it is recorded as applied.
