# AutoPiOverclock

**Recoverable, controller-driven Raspberry Pi 5 overclocking over SSH.**

[![CI](https://github.com/p1r473/AutoPiOverclock/actions/workflows/ci.yml/badge.svg)](https://github.com/p1r473/AutoPiOverclock/actions/workflows/ci.yml)

AutoPiOverclock searches for CPU and GPU clocks, stress-validates the result for 24 hours by default, and applies it without replacing the rest of your boot configuration. Candidate clocks use Raspberry Pi `tryboot.txt`, while a separate Linux controller watches reboots and verifies recovery.

> [!CAUTION]
> Overclocking can crash the target, corrupt storage, or damage data. Back up the Pi first. The recovery safeguards reduce risk; they cannot eliminate it.

## Quick start

You need:

- one 64-bit Raspberry Pi 5 to overclock;
- one separate Linux controller, such as a PC, server, VM, or another Pi;
- key-based SSH access from the controller to the target;
- a target SSH user that is root or has noninteractive passwordless `sudo`; and
- adequate power and cooling.

The controller and target must be different machines.

On a Debian or Ubuntu controller, install the required tools:

```bash
sudo apt-get update
sudo apt-get install -y bash coreutils diffutils findutils gawk git grep make openssh-client python3 sed tar unzip util-linux zip
```

Install AutoPiOverclock on the controller:

```bash
git clone https://github.com/p1r473/AutoPiOverclock.git
cd AutoPiOverclock
make test
sudo make install
autopioverclock --version
```

`make test` validates only the checkout. It does not connect to, modify, or reboot a target.

Confirm key-only SSH works. Replace the example with the target's real username and hostname or IP:

```bash
TARGET=pi@pi-host
ssh "$TARGET" true
ssh -o BatchMode=yes "$TARGET" true
```

Then use the two everyday commands:

```bash
autopioverclock prepare pi@pi-host
autopioverclock overclock pi@pi-host
```

- `prepare` installs and verifies target prerequisites and recovery safeguards, and may update watchdog files and reboot the target.
- `overclock` searches, validates, applies, reboots, and verifies. Repeating it continues the latest eligible interrupted run.

Every operational command requires a target. AutoPiOverclock intentionally ignores `~/.ssh/config`; use `--identity-file FILE` or `--ssh-port PORT` when needed.

> [!IMPORTANT]
> Batocera may require `prepare` to build its graphical payload on an ARM64 Debian-family controller and install a bounded network-loss watchdog. Review [the Batocera notes](docs/batocera.md) before approving those changes.

## Supported targets

“Supported” means the platform has an implemented, fixture-covered alpha path. It does not mean that every hardware/firmware combination has completed end-to-end qualification.

| Target | Status | Notes |
| --- | --- | --- |
| Raspberry Pi OS | Supported | 64-bit ARM Raspberry Pi boot layout. |
| Debian | Supported | 64-bit ARM; `/boot/firmware/config.txt` or `/boot/config.txt`. |
| Ubuntu | Supported | 64-bit ARM Raspberry Pi boot layout only. |
| Batocera | Supported | 64-bit ARM Buildroot; read-only `/boot` handling and graphical gates. |
| Arch Linux | Not supported | Outside the v1 scope. |
| Generic Linux distributions | Not supported | Detection is intentionally narrow. |

Graphical and headless operation are supported. The controller must be a separate Linux machine; Debian or Ubuntu with GNU tools is the tested controller path. Batocera is treated as Buildroot, not Arch Linux, and AutoPiOverclock never attempts an in-place glibc upgrade on Batocera.

## Current validation status

This repository is alpha software. Automated fixtures are not a substitute for Raspberry Pi hardware evidence, and the live CI badge above is the authoritative status for the current GitHub commit.

As of 2026-09-04, `alpha.43` keeps `prepare` and `overclock` as the two everyday commands, with `reset` available when a user wants to return to stock and start over. Automatic tuning searches and qualifies CPU first, then searches and qualifies GPU, and runs one 24-hour combined final validation. One-domain and later-candidate starts retain the same safety pipeline. A fully recovered CPU or GPU boot/stability failure during qualification causes only the identified domain to step down by 25 MHz. A CPU- or GPU-specific final failure also lowers only the identified domain; a genuinely ambiguous full-mode failure tests CPU-only, GPU-only, then paired 25 MHz reductions so a stable domain is not lowered unnecessarily. Transient reads and safely recovered harness failures receive bounded retries, while real active config drift, ownership ambiguity, and uncertain recovery still stop. Raspberry Pi OS/Debian headless operation is automatic and does not require display or audio hardware.

| Evidence | Current status |
| --- | --- |
| Bash fixture suite | 19 scripted suites cover the normal/manual-test interface, progress calculations/rendering, installed entry point, state, classification, workers, tryboot, watchdog installation, selection, resume, apply, reset, packaging, and public-safety contracts. |
| GitHub CI and ShellCheck | The workflow runs all fixture suites and ShellCheck; see the live badge for the current published `main` result. |
| Debian-family Raspberry Pi 5 run | One Debian 13 Pi 5 completed and applied a retained **alpha.39** result at **CPU 3100 MHz and V3D 1175 MHz with the firmware-default voltage state**. Each domain qualification ran for two hours; combined CPU/GPU/I/O validation ran for 24 hours; three additional candidate/normal boot cycles passed; maximum recorded temperature was 59.3 C with `throttled=0x0`; and the apply verification reboot passed. This proves that retained result, not alpha.43's new search and backoff paths. |
| Batocera Raspberry Pi 5 run | Recovery and watchdog preparation have been exercised, but complete `alpha.43` end-to-end validation remains pending. |
| Default 24-hour combined final validation | Proven on the retained Debian run above; no Batocera PASS claim until current-version artifacts complete and are reviewed. |

Do not infer a general production recommendation from one board, a candidate pass, an active run, or this table. Only a run that reaches `COMPLETE`, records `Validated: 1` under the current validation schema, and finishes `overclock` with `APPLY_STATUS=APPLIED` is installed by the normal workflow. The standalone expert `apply` command retains its separate confirmation.

## How automatic overclocking works

The normal `autopioverclock overclock TARGET` strategy is deliberately ordered so a GPU result is never used to guess a CPU boundary, and vice versa:

1. **Prove the stock baseline and recovery path.** The controller verifies the protected permanent config, stock clocks, watchdog chain, normal boot, and owned `tryboot` lifecycle before searching.
2. **Search CPU first.** Searches CPU from 2500 through 3200 MHz in 100 MHz steps with 10-minute candidates, then refines the failure gap in 25 MHz steps to the highest actual pass.
3. **Qualify CPU.** The highest passing CPU is qualified for two hours by default with GPU held at the protected baseline (stock in a normal full run). A fully recovered CPU boot/stability failure steps CPU down 25 MHz and repeats the complete qualification.
4. **Search and qualify GPU.** Searches GPU/V3D through 1200 MHz in 50 MHz steps only after CPU qualification passes, then refines in 25 MHz steps to the highest actual pass. GPU is qualified at the selected CPU; a fully recovered GPU boot/stability failure steps GPU down 25 MHz and repeats the complete qualification.
5. **Validate one final result.** The selected pair runs one fresh 24-hour combined CPU/GPU/I/O validation by default. Exact CPU evidence lowers only CPU; exact GPU evidence lowers only GPU. If the domain is ambiguous, the pair becomes the anchor and CPU 25 MHz lower is tried first. If that attempt also fails ambiguously, CPU is restored and GPU 25 MHz lower is tried; another ambiguous failure tries both 25 MHz lower. Exact evidence from any trial immediately follows the exact-domain rule instead. Each changed domain is requalified before a fresh full final run; if all three trials fail ambiguously, the paired reduction becomes the next anchor and isolation repeats. One-domain mode can lower and requalify only its selected domain; exact evidence against the held domain stops. This avoids sacrificing a stable domain. Even a failure near the end invalidates that attempt, so elapsed time is never credited.
6. **Recover and retry automatically.** A safely recovered structured or unstructured harness failure repeats the complete affected boot, stress, or health gate up to five times. Exhausted harness retries or any recovery uncertainty stop rather than being mislabeled as a clock boundary.
7. **Apply only completed evidence.** The exact permanent diff is retained and shown, then the validated result is applied, rebooted, and re-proved. Maximum PWM fan cooling is temporary during candidate boots; the user's original fan policy returns on normal boots and after application.

`--cpu-only` and `--gpu-only` are mutually exclusive one-domain modes. They require and extend the target's latest eligible applied AutoPiOverclock result. CPU-only holds GPU/V3D at that retained, freshly re-proved clock; GPU-only holds CPU at that retained, freshly re-proved clock. The held clock is a verified baseline, not a claim that its domain is already maximized. Only the selected domain is swept and qualified. A fully recovered final boot/stability failure can lower only that selected domain by 25 MHz; exact evidence against the held domain stops. The pair still receives the same combined final validation, automatic apply, reboot verification, cooling, watchdog, retry, and recovery safeguards. `--cpu-start-at MHZ` and `--gpu-start-at MHZ` accept 25 MHz increments above the protected current clock and begin their automatic sweeps at a later candidate without forcing a final clock. Full mode accepts both from a stock target, while an already applied target uses the matching one-domain mode. Earlier coarse candidates are skipped initially, but if the first requested candidate fails, 25 MHz refinement may probe below that start to find the highest pass above the verified baseline. The CPU ceiling is 3200 MHz and the GPU ceiling is 1200 MHz; either ceiling is still tested when the chosen start does not align with the coarse ladder.

The recommended public policy is two hours for each applicable qualification and one 24-hour final validation. `--qualification-hours HOURS` and `--final-hours HOURS` accept whole-hour values from 1–168; shorter tests reduce confidence and are recorded as custom policy.

Maximum Pi PWM fan cooling is temporary during testing; the target's normal fan settings return afterward. Use `--no-max-fan` only when passive/external cooling or the normal fan policy is intentionally part of the test. Reduced cooling can reduce sustained performance or stability. Headless Debian-family targets require neither a display nor audio hardware.

The saved test lengths can be changed with whole-hour values from 1 through 168:

```bash
autopioverclock overclock pi@pi-host --qualification-hours 3 --final-hours 36
```

## Commands

| Command | Purpose |
| --- | --- |
| `prepare TARGET` | Install and verify dependencies and watchdog recovery. Add `--dry-run` for read-only discovery and plan generation. |
| `overclock TARGET [--cpu-only | --gpu-only] [--cpu-start-at MHZ] [--gpu-start-at MHZ]` | Tune both domains, or extend an eligible applied result by tuning one domain while holding the other at its retained verified clock; optional starts skip earlier coarse candidates. |
| `test TARGET` | Test one exact `--cpu`/`--gpu` pair for `--minutes`; recover normally and retain evidence without applying it. |
| `reset TARGET` | Back up the boot config, remove tuning, reboot, and verify stock clocks. |
| `run TARGET` | Use the advanced prepare, recovery-proof, sweep, selection, and validation interface. |
| `resume TARGET` | Recover when necessary and continue saved progress. |
| `status TARGET` | Show local state for the selected or latest run; supports redaction. |
| `recover TARGET` | Return the target to permanent normal configuration and verify health. |
| `apply TARGET` | Apply only a fully validated result after an exact diff and typed confirmation. |
| `report TARGET` | Generate a concise run report; supports redaction. |

Every operational command requires `TARGET`. `--cpu-only` and `--gpu-only` cannot be combined; CPU-only rejects `--gpu-start-at`, and GPU-only rejects `--cpu-start-at`. Full mode may use either or both starting points only from stock; starting points must be 25 MHz multiples above the protected current clock and no higher than the documented domain ceiling. `--restart-from` is full-mode only; repeat the same one-domain command to continue a one-domain checkpoint. `--qualification-hours` and `--final-hours` customize the long tests. Maximum cooling is the default; `--no-max-fan` opts a new tuning or manual-test run out while preserving every normal thermal/throttle gate.

```bash
autopioverclock overclock pi@pi-host --cpu-only --cpu-start-at 2900
autopioverclock overclock pi@pi-host --gpu-only --gpu-start-at 1050
autopioverclock overclock pi@pi-host --cpu-start-at 2900 --gpu-start-at 1050
```

Common transport options are `--identity-file FILE`, `--ssh-port PORT`, and `--output-dir DIR`. Advanced `run` options include `--config FILE`, `--mode auto|graphical|headless`, `--install-missing`, `--repair-watchdogs`, `--dry-run`, `--yes`, and `--no-max-fan`. Transport/output options, named checkpoint restarts, strict plans, and the complete expert recovery/reporting interface are documented in [the CLI reference](docs/cli.md). They are not required for the normal two-command workflow; `reset TARGET` is available when a user wants to return to stock.

## Configuration

Configuration files are strict, data-only `KEY=VALUE` files. They are parsed, never sourced.

```ini
cpu_candidates_mhz=
gpu_candidates_mhz=
voltage_delta_uv=existing
candidate_duration_seconds=600
final_duration_seconds=86400
max_temp_c=75
telemetry_interval_seconds=5
conservative_backoff_steps=1
candidate_boots=2
final_boots=3
required_services=
frontend_process=
audio_sink_pattern=
```

Custom configuration is an advanced `run TARGET --config FILE` interface retained for development and support. The normal `autopioverclock overclock TARGET` command intentionally uses the fixed automatic policy above and accepts no custom clock plan. Explicit candidate lists must be strictly increasing; empty lists skip that domain, and at least one domain must contain candidates.

`voltage_delta_uv=existing` preserves the target's existing value; AutoPiOverclock never silently raises voltage. `final_duration_seconds` accepts 3,600–604,800 seconds for the advanced explicit plan, candidate boots cannot be lower than two, and final boot/recovery cycles cannot be lower than three. The simple hour options are preferred for automatic tuning because they bind qualification and final timing visibly in one command.

| Key | Meaning and accepted values |
| --- | --- |
| `cpu_candidates_mhz` | Strictly increasing comma-separated CPU clocks; each value 600–4000 MHz. Empty skips CPU tuning. |
| `gpu_candidates_mhz` | Strictly increasing comma-separated V3D clocks; each value 200–3000 MHz. Empty skips GPU tuning. |
| `voltage_delta_uv` | `existing`, or an explicit 0–100000 microvolt delta. |
| `candidate_duration_seconds` | Stress duration for each short search candidate; 10–86400 seconds. |
| `final_duration_seconds` | Combined endurance duration for an advanced explicit plan; 3600–604800 seconds. |
| `max_temp_c` | Exclusive temperature ceiling; 40–95 °C. Reaching the ceiling fails the candidate. |
| `telemetry_interval_seconds` | Temperature, clocks, throttle, and kernel-error sampling cadence; 1–60 seconds. Workload supervision still runs every second. |
| `conservative_backoff_steps` | Explicit-plan positions to step down from the maximum observed pass; 0–10. Automatic tuning instead refines to the highest pass and uses 25 MHz qualification backoff or final-pair isolation. |
| `candidate_boots` | Candidate/normal recovery cycles before candidate stress; 2–10. |
| `final_boots` | Post-endurance candidate/normal recovery cycles; 3–10. |
| `required_services` | Optional comma-separated service names that must remain active. |
| `frontend_process` | Optional single process name that must remain present. |
| `audio_sink_pattern` | Optional literal substring required in the default audio-sink inspection. |

## What every candidate must prove

- SSH returns after the expected boot.
- The firmware reports an active `tryboot` candidate.
- Requested clocks are observed under load within tolerance.
- With the default cooling policy, any detected Pi 5 PWM fan remains at setting 255 (100%) with a live tachometer when exposed; losing that test condition aborts without being labeled a CPU/GPU boundary. `--no-max-fan` uses the target's ordinary policy and does not claim or require PWM 255.
- Current/new throttle and undervoltage evidence remains clean.
- Temperature remains below the configured ceiling.
- No new filesystem, storage, USB-reset, GPU, kernel panic/internal error/Oops, RCU-stall, hung-task, or watchdog fault appears.
- The stress process exits successfully and within its hard deadline.
- Graphical runs always preserve the captured display and audio baselines. Debian automatically prefers the active PipeWire/PulseAudio sink and falls back to the complete ALSA playback-device inventory without guessing one output; Batocera requires its active default sink. `audio_sink_pattern` remains an optional additional expert constraint.
- Required services and processes remain healthy.
- Permanent configuration retains its original SHA-256 hash.
- The following recovery boot clears `tryboot` and passes normal health checks.

GPU harness failures are kept separate from clock-stability failures. A required graphical or headless backend that cannot launch, bind the hardware V3D renderer, complete with its required success evidence, or preserve any applicable display/audio baseline is a `HARNESS_FAILURE`, not proof that the tested GPU clock is unstable. Audio readiness loss by itself follows the safe harness retry/recovery policy and never creates a CPU or GPU boundary. A positive score is required when glmark2 is the selected workload. Batocera graphical testing uses an off-screen Wayland workload on the live EmulationStation compositor; it does not take DRM master or stop and restore the frontend.

Stress timing is fail-closed. Batocera CPU load uses exactly one 1 MiB SHA-256 benchmark measured in elapsed time, so the requested duration is the total workload duration rather than a per-buffer-size duration. The larger block also keeps OpenSSL's signed per-worker operation counter from ending a 24-hour Pi 5 test early; it does not shorten the requested stress time. Because each workload and its Bash supervisor use independent whole-second clocks, a clean exit within 0.1% of the requested duration is accepted only inside a 3–30 second bound; an earlier clean exit or any nonzero exit is still rejected. Workloads retain a separate 60-second shutdown deadline after their requested duration, and controller SSH/reboot budgets include wall time spent inside connection attempts instead of silently stretching a nominal recovery timeout.

Read [Safety](docs/safety.md), [Architecture](docs/architecture.md), and [Output](docs/output.md) for the complete contracts and failure classes.

## Recovery and resume

Each candidate and final-validation substage is checkpointed atomically. The random ownership token, completed-file hash, reservation hash, token-specific quarantine path, and cooling policy are saved before remote creation can begin. If the controller exits while `tryboot` may be active, its exit trap attempts normal recovery. `resume` repeats recovery first whenever saved or live evidence says the target may still be in `tryboot`, verifies normal recovery, and cleans only token/hash-matching project evidence; an unknown or changed path is preserved and fails closed. A resumed run keeps its saved cooling policy rather than changing test conditions halfway through.

An SSH timeout alone remains `HARNESS_FAILURE`. Before classifying missing controller evidence, individual validated reads receive 30 attempts with 10-second spacing and safe read-only/idempotent worker gates receive up to five same-boot attempts. During candidate boot, active stress, or required post-stress health, the controller records the exact candidate boot as soon as it appears—even before transient worker redeployment. Only complete normal recovery proving a later boot ID, clear tryboot flag, owned-file cleanup, protected hash, stock clocks, and watchdog health can promote the loss to the appropriate `BOOT_FAILURE` or `STABILITY_FAILURE`. If the candidate did not autonomously reboot and recovery is complete, the controller may repeat that complete gate five times; the retry count and exact gate are durable across resume. The exact older controller-only “permanent config hash is unavailable” state is adopted only after stock health and the protected hash are freshly re-proved. Exhaustion remains `HARNESS_FAILURE`; a valid hash mismatch or failed normal recovery remains `RECOVERY_FAILURE`.

All live mutating/recovery commands allow a full five-minute SSH/reboot budget, then continue read-only polling every 10 seconds without issuing repeated reboots; a status notice is emitted every five minutes. `Ctrl-C` leaves the saved run resumable. After every expected or observed reboot, the controller re-uploads the run-isolated worker before collecting health evidence, so volatile `/tmp` cleanup is handled automatically.

```bash
autopioverclock status pi@pi-host --run-id RUN_ID
autopioverclock report pi@pi-host --run-id RUN_ID
autopioverclock resume pi@pi-host --run-id RUN_ID
autopioverclock recover pi@pi-host --run-id RUN_ID
```

Without `--run-id`, `resume`, `recover`, `status`, and `report` select the target's latest retained state. Use an explicit run ID when you intentionally want an older run; a reset audit also advances the target's `*-latest` links. Rerunning the same `autopioverclock overclock TARGET` command—including its domain mode and starting-point flags—continues the matching latest eligible interrupted run.

For a current automatic overclock that has not started final validation, `resume` can deliberately repeat a retained checkpoint while taking all clocks from saved evidence:

```bash
autopioverclock resume pi@pi-host --restart-from cpu-qualification --qualification-hours 2 --final-hours 24
autopioverclock resume pi@pi-host --restart-from gpu-qualification --qualification-hours 2 --final-hours 24
autopioverclock resume pi@pi-host --restart-from final --final-hours 24
```

The accepted checkpoints are `current`, `cpu-qualification`, `gpu-qualification`, and `final`. The command line changes only durations and the restart point; it never supplies replacement CPU/GPU result clocks, and any omitted duration retains its saved value. Prerequisite qualifications must already match the retained selected pair, and an active final sequence cannot be rewound or relabeled. Directly resuming an overclock keeps the same unattended extended-SSH monitoring and automatic final apply as `overclock TARGET`.

For a completed applied result, only `--restart-from final` is allowed; a longer requested final creates a linked fresh validation using the retained clocks and verified pre-apply stock backup. A fully recovered ambiguous full-mode boot/stability failure keeps stock active and follows the CPU-only, GPU-only, then paired 25 MHz isolation sequence only while evidence remains ambiguous; exact evidence switches immediately to its identified domain. A one-domain run reduces and requalifies only its selected domain and stops on exact evidence against the held domain. Every attempt runs the complete saved final duration from zero. Plain `resume TARGET` also adopts exact safely recovered unstructured worker-loss or clean-early-exit checkpoints for bounded automatic retry. Exhausted harness or recovery uncertainty still stops, and an older safety schema cannot bypass newer gates.

### Reset a target to verified stock defaults

Reset is command-first:

```bash
autopioverclock reset pi@pi-host
```

No postfix reset spelling is accepted. Reset is noninteractive, so it neither needs nor accepts `--yes`. It also rejects run-selection, tuning, dependency, watchdog, dry-run, duration, fan-policy, mode, and redaction flags; only transport/output selectors may accompany it.

Before changing the permanent root boot config, reset requires a regular non-symlink config, a stable expected hash, no active `include` directive, and no foreign or ambiguous `tryboot.txt`/quarantine path. It writes a hash-verified, no-clobber backup under `/var/lib/autopioverclock/backups/` on Debian-family systems or `/userdata/system/autopioverclock/backups/` on Batocera. Standalone boost, fixed-clock, `*_freq`/`*_freq_min`, and `over_voltage*` lines are retained as comments prefixed with `# AUTOPIOVERCLOCK-STOCK-DISABLED`; the clock directives and markers in one structurally valid AutoPiOverclock managed block are removed while its `[all]` section boundary is retained, with the complete original bytes in the verified backup.

An attributable AutoPiOverclock tryboot artifact is backed up before removal, while unknown paths are preserved and reset fails closed. If the running firmware reports a tryboot boot but no live or quarantined path exists, reset does not claim ownership of that boot; it safely prepares the backed-up permanent stock config, forces a normal reboot, and requires the post-reboot tryboot flag to be clear. Batocera must also restore and verify `/boot` read-only.

Reset then forces a permanent-config reboot and accepts success only after a new boot ID, an exact expected config hash, an absent/cleared tryboot state, and active Raspberry Pi 5 stock clocks are all verified: CPU 2400 MHz, firmware-default V3D 800 or 960 MHz, and the firmware-default voltage state. The same verification checks current throttle/power state and the active watchdog chain; reset does not claim the broader display, audio, service, or workload health gates used by tuning. A reset creates its own audit state/log and reports the remote backup path; it never deletes or truncates prior logs, state, summaries, candidate logs, or saved runs.

Reset does not run `tmux`, Byobu, job-control, or process-wide kill commands. If another controller still owns the per-target lock, reset fails without signaling that process or its terminal session; stop that one foreground controller yourself and repeat `autopioverclock reset TARGET`.

`recover` returns one retained run to its saved protected normal config and stops. `reset` removes permanent tuning and verifies firmware-stock clocks. Neither deletes prior run artifacts.

## Results

All targets and runs share one flat output directory, `$HOME/overclock-results` by default. There are no per-host subdirectories, and prior runs are never deleted. A typical tuning run creates the following artifacts; a standalone reset creates its own audit state/log/summary/CSV/JSON but intentionally does not manufacture a tuning `.conf` or candidate logs.

```text
target-20260823-010000-a1b2c3d4e5f60708.log
target-20260823-010000-a1b2c3d4e5f60708.csv
target-20260823-010000-a1b2c3d4e5f60708.json
target-20260823-010000-a1b2c3d4e5f60708.state
target-20260823-010000-a1b2c3d4e5f60708.conf
target-20260823-010000-a1b2c3d4e5f60708.jsonl
target-20260823-010000-a1b2c3d4e5f60708-discovery.txt
target-20260823-010000-a1b2c3d4e5f60708-summary.txt
target-20260823-010000-a1b2c3d4e5f60708-cpu-CLOCK_gpu-CLOCK-candidate.log
target-latest.log
target-latest-summary.txt
target-latest.state
target-latest.json
```

The atomic `.state`, log, event stream, and summary are written during a run. The finalized `.json` array is generated when the controller exits through its cleanup handler, so its target can be absent while a run is active or after an uncatchable kill; that does not mean the saved state was lost. See [the output reference](docs/output.md) for artifact fields and failure classifications.

A completed automatic result must show `Status: PASS`, `Phase: COMPLETE`, `Validated: 1`, and—after the normal `overclock` flow finishes—`APPLY_STATUS=APPLIED`.

A successful apply adds a small managed block and leaves unrelated boot settings intact:

```ini
# BEGIN AUTOPIOVERCLOCK MANAGED CLOCKS
# Run: RUN_ID
[all]
arm_freq=3100
v3d_freq=1175
# END AUTOPIOVERCLOCK MANAGED CLOCKS
```

Those clocks are only an example. When the tested voltage delta is the firmware default, it remains part of the retained evidence without adding a redundant setting to the boot config. Leave the managed markers intact so `autopioverclock reset TARGET` can remove the block safely.

Before sharing, generate `autopioverclock report TARGET --redact` and still review the report for private hostnames, addresses, or other context.

AutoPiOverclock is licensed under the [Apache License 2.0](LICENSE). See [Contributing](CONTRIBUTING.md) and [Security](SECURITY.md).

