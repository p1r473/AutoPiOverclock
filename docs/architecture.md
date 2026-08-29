# Architecture

The controller owns policy, state, logging, candidate order, recovery decisions, and reporting. A small standalone worker performs privileged target operations. Workers emit structured `APO_DATA` and `APO_RESULT` records so controller-side classification does not depend only on prose greps.

## Controller layers

- `common.sh`: validation, quoting, target parsing, backoff.
- `config.sh`: strict non-executable configuration.
- `state.sh`: durable, atomic base64-encoded resume state with run and validation schema versions.
- `logging.sh`: flat immutable run artifacts and latest symlinks.
- `progress.sh`: TTY-only dynamic whole-workflow estimates and worker-elapsed current-stress display; raw telemetry remains authoritative.
- `ssh.sh`: `command ssh -F /dev/null` transport and root/sudo wrapper.
- `detect.sh`: OS/profile discovery, dependency preflight, active watchdog-chain proof, and the shared post-reboot worker handshake.
- `recovery.sh`: tryboot trigger, boot-ID tracking, and normal return.
- `reset.sh`: standalone explicit-target reset orchestration, persistent-backup evidence, permanent reboot, and verified-stock completion.
- `candidates.sh`: resumable candidate/manual-test substages, edge handling, selection, and final-validation substages.
- `apply.sh`: current-schema/eight-hour eligibility, exact diff, explicit overclock authorization or standalone typed confirmation, persisted backup plan, normal-reboot health, and rollback.

For `--mode auto` without an explicit configuration, each worker hashes the permanent root config before and after auditing all documented clock/voltage control families. Snapshot changes and explicit tuning controls are reported, and any `include` directive fails closed because the existing protected permanent hash covers only the root config. `config.sh` defers candidate resolution until `detect.sh` has verified both that provenance evidence and the active stock tuple (2400 MHz CPU, supported 800/960 MHz firmware-stock V3D, zero voltage delta). It then creates bounded coarse ladders and checkpoints them before tuning confirmation. `candidates.sh` checkpoints a 25 MHz refinement gap, observed failure boundaries, tested 50/25 MHz CPU/GPU guard targets, and optional post-floor edge-validation evidence. Explicit configuration files bypass stock-gated generation and remain authoritative.

## Target profiles

Raspberry Pi OS, Debian, and supported Ubuntu Pi layouts use `stress-ng`, systemd watchdog inspection, and normal writable boot configuration. Screenless systems automatically use headless health gates: no display/audio identity is required, but the actual V3D render node and a usable GPU stress route remain mandatory. The worker uses explicit `--gpu-devnode` routing when available and permits the older default-device form only when exactly one render node exists and it is the discovered V3D node. Batocera uses OpenSSL for CPU load, a persistent portable glmark2 payload for GPU load, an OS-specific read-only `/boot` remount cycle, a reboot syscall for tryboot, and a project-owned network/hardware watchdog keeper installed by `prepare` when the active chain is incomplete.

Each run receives a collision-resistant ID and its own target-side worker directory. Debian uses `/tmp` and never assumes that directory survives a reboot; the controller re-uploads the exact worker after every changed boot ID before collecting target-side evidence. Batocera uses persistent userdata but deliberately follows the same handshake. Boot-critical mutations on a target—tryboot staging, triggering and cleanup; normal reboot; watchdog repair; permanent apply; and rollback—share one atomic target lock. A controller can therefore observe another active run, but it cannot overlap that run's recovery-sensitive operation.

Every candidate attempt also receives a fresh 256-bit ownership token. The controller durably checkpoints the token, reservation hash, completed-file hash, and quarantine path before the worker may create `tryboot.txt`. The worker uses no-clobber creation and held-descriptor checks, repeats exact verification immediately before reboot, and removes the file only after verified normal recovery through a no-clobber quarantine-and-revalidation step. Unknown or raced evidence is preserved and fails closed.

## State phases

```text
PREPARE → TRYBOOT_PROOF → GPU_SMOKE → CPU_SWEEP/refinement
        → CPU_QUALIFICATION_2H(stock GPU) → GPU_SWEEP/refinement
        → GPU_QUALIFICATION_2H(qualified CPU) → COMBINED_VALIDATION_8H
        → optional COMBINED_CPU_EDGE_24H → COMPLETE

PREPARE → TRYBOOT_PROOF → GPU_SMOKE → MANUAL_TEST(one exact CPU/GPU pair) → COMPLETE
```

Skipped explicit-plan domains are bypassed. Within each candidate, state records the candidate identity and a generic `BOOT_n`/`NORMAL_n` substage across the configured `candidate_boots` cycles, followed by the stress boot, stress, post-stress health, and final normal recovery. Automatic refinement indices, failure boundaries, guard verification, exact two-hour CPU/GPU qualification identities, and monotonic backoff histories are resumable. Final validation checkpoints one eight-hour combined CPU/GPU/I/O workload, return to normal, the configured `final_boots` post-stress `BOOT_n`/`NORMAL_n` cycles, and final hash verification. Optional edge mode records the completed production floor before starting a 24-hour combined workload so a safely recovered edge failure cannot erase that result.

A later edge request imports only a fully validated and applied current-schema floor into a new linked run. This preserves the source artifacts and original stock rollback backup while giving the edge apply its own run-specific backup. The source validation mode is retained exactly: graphical remains graphical, and a screenless headless run remains headless.

Resume first returns an interrupted tryboot to normal. If a saved substage depended on evidence from that exact candidate boot, the controller safely repeats the required boot or stress rather than claiming that gate passed. Completed substages are not restarted merely because the controller process stopped. A fully recovered boot/stability failure during CPU or GPU qualification lowers only that domain by its guard and repeats the full two-hour qualification. One during combined production validation lowers every still-overclocked domain because pair-level evidence cannot identify one cause, then repeats both qualifications and the complete eight-hour sequence. During the ordinary public command, an extended SSH outage switches to read-only polling after the bounded timeout; no additional reboot is issued, and boot/ownership/health reconciliation resumes when SSH returns.

The controller's interactive bar derives total remaining work from the saved sweep indices, dynamically discovered boundaries/refinement ladders, guarded-candidate state, final-validation stage, and optional edge state. Reboot/SSH segments use bounded estimates, so total percentage/ETA and test counts are explicitly approximate and may change when the plan changes. Timed workers emit `elapsed=current/total`, which gives the current stress phase its own evidence-based countdown. TTY rendering consumes those lines for one in-place display while duplicating the unmodified lines into the candidate and main logs; redirected execution prints them normally. Cleanup marks rendering shut down before clearing the active terminal width so subsequent recovery logging cannot repaint a stale bar.

Controller policy passes `telemetry_interval_seconds` and the saved normal/candidate cooling context to each target worker. Candidate tryboot rendering adds a test-only Pi 5 maximum-fan block by default; `--no-max-fan` selects the normal context for a new run and is then immutable across resume. Workers sample and log temperature, throttle state, active clocks, detected `pwmfan` PWM/RPM state, new kernel errors, and supervised stress processes at the bounded cadence while retaining an independent hard shutdown deadline. Under the default policy, a detected fan that is not at PWM 255 aborts as harness uncertainty. Normal and permanent clock rendering never imports the candidate fan block, so pre-existing fan directives return automatically after every normal boot and remain in the applied result.

An interrupted `PREPARE` is different: dependency or watchdog remediation may have only partially changed the target. Its state remains available to `status` and `report`, but mutating resume is refused so the controller cannot silently adopt an unverified permanent configuration as its new baseline.

The `reset TARGET` path does not consume or erase a prior tuning run. It allocates a standalone audit run, acquires the same controller/target mutation locks, rejects foreign tryboot evidence and unbound includes, checkpoints the expected old/new hashes and no-clobber persistent backup, then performs an ordinary permanent-config reboot. Completion requires a changed boot ID, the exact new hash, no tryboot state, verified firmware-stock clocks, clear current throttle/power state, and the active watchdog chain. It does not claim tuning's broader health gates. Terminal multiplexers and unrelated controller processes are outside its authority. Only the command-first form is accepted, and its target is mandatory.
