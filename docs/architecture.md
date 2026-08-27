# Architecture

The controller owns policy, state, logging, candidate order, recovery decisions, and reporting. A small standalone worker performs privileged target operations. Workers emit structured `APO_DATA` and `APO_RESULT` records so controller-side classification does not depend only on prose greps.

## Controller layers

- `common.sh`: validation, quoting, target parsing, backoff.
- `config.sh`: strict non-executable configuration.
- `state.sh`: durable, atomic base64-encoded resume state with run and validation schema versions.
- `logging.sh`: flat immutable run artifacts and latest symlinks.
- `ssh.sh`: `command ssh -F /dev/null` transport and root/sudo wrapper.
- `detect.sh`: OS/profile discovery, dependency preflight, and active watchdog-chain proof.
- `recovery.sh`: tryboot trigger, boot-ID tracking, and normal return.
- `reset.sh`: standalone explicit-target reset orchestration, persistent-backup evidence, permanent reboot, and verified-stock completion.
- `candidates.sh`: resumable candidate substages, edge handling, selection, and final-validation substages.
- `apply.sh`: current-schema/eight-hour eligibility, exact diff, explicit overclock authorization or standalone typed confirmation, persisted backup plan, normal-reboot health, and rollback.

For `--mode auto` without an explicit configuration, each worker hashes the permanent root config before and after auditing all documented clock/voltage control families. Snapshot changes and explicit tuning controls are reported, and any `include` directive fails closed because the existing protected permanent hash covers only the root config. `config.sh` defers candidate resolution until `detect.sh` has verified both that provenance evidence and the active stock tuple (2400 MHz CPU, supported 800/960 MHz firmware-stock V3D, zero voltage delta). It then creates bounded coarse ladders and checkpoints them before tuning confirmation. `candidates.sh` checkpoints a 25 MHz refinement gap, observed failure boundaries, tested 50/25 MHz CPU/GPU guard targets, and optional post-floor edge-validation evidence. Explicit configuration files bypass stock-gated generation and remain authoritative.

## Target profiles

Debian uses `stress-ng`, systemd watchdog inspection, and normal writable boot configuration. Batocera uses OpenSSL for CPU load, a persistent portable glmark2 payload for GPU load, an OS-specific read-only `/boot` remount cycle, a reboot syscall for tryboot, and a project-owned network/hardware watchdog keeper installed by `prepare` when the active chain is incomplete.

Each run receives a collision-resistant ID and its own target-side worker directory. Boot-critical mutations on a target—tryboot staging, triggering and cleanup; normal reboot; watchdog repair; permanent apply; and rollback—share one atomic target lock. A controller can therefore observe another active run, but it cannot overlap that run's recovery-sensitive operation.

Every candidate attempt also receives a fresh 256-bit ownership token. The controller durably checkpoints the token, reservation hash, completed-file hash, and quarantine path before the worker may create `tryboot.txt`. The worker uses no-clobber creation and held-descriptor checks, repeats exact verification immediately before reboot, and removes the file only after verified normal recovery through a no-clobber quarantine-and-revalidation step. Unknown or raced evidence is preserved and fails closed.

## State phases

```text
PREPARE → TRYBOOT_PROOF → GPU_SMOKE → CPU_SWEEP/refinement → GPU_SWEEP/refinement
        → SELECTION → FINAL_VALIDATION → optional CPU_EDGE_24H → COMPLETE
```

Skipped domains are bypassed. Within each candidate, state records the candidate identity and a generic `BOOT_n`/`NORMAL_n` substage across the configured `candidate_boots` cycles, followed by the stress boot, stress, post-stress health, and final normal recovery. Automatic refinement indices, failure boundaries, and guard verification are also resumable. Final validation separately checkpoints CPU stress, optional GPU stress, endurance, return to normal, the configured `final_boots` post-stress `BOOT_n`/`NORMAL_n` cycles, and final hash verification. Optional edge mode records the completed production floor before starting the second validation so a safely recovered edge failure cannot erase that result.

Resume first returns an interrupted tryboot to normal. If a saved substage depended on evidence from that exact candidate boot, the controller safely repeats the required boot or stress rather than claiming that gate passed. Completed substages are not restarted merely because the controller process stopped.

Controller policy passes `telemetry_interval_seconds` to each target worker. Workers sample and log temperature, throttle state, active clocks, new kernel errors, and supervised stress processes at that bounded cadence while retaining an independent hard shutdown deadline.

An interrupted `PREPARE` is different: dependency or watchdog remediation may have only partially changed the target. Its state remains available to `status` and `report`, but mutating resume is refused so the controller cannot silently adopt an unverified permanent configuration as its new baseline.

The normal `reset TARGET` path does not consume or erase a prior tuning run. It allocates a standalone audit run, acquires the same controller/target mutation locks, rejects foreign tryboot evidence and unbound includes, checkpoints the expected old/new hashes and no-clobber persistent backup, then performs an ordinary permanent-config reboot. Completion requires a changed boot ID, the exact new hash, no tryboot state, verified firmware-stock clocks, clear current throttle/power state, and the active watchdog chain. It does not claim tuning's broader health gates. Terminal multiplexers and unrelated controller processes are outside its authority. Command-first and older postfix forms remain parser-compatible; both require an explicit target.
