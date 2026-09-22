# AutoPiOverclock

**Recoverable, controller-driven Raspberry Pi 5 overclocking over SSH.**

[![CI](https://github.com/p1r473/AutoPiOverclock/actions/workflows/ci.yml/badge.svg)](https://github.com/p1r473/AutoPiOverclock/actions/workflows/ci.yml)

AutoPiOverclock searches for CPU and GPU clocks, stress-validates the result for 48 hours by default, and applies it without replacing the rest of your boot configuration. Candidate clocks use Raspberry Pi `tryboot.txt`, while a separate Linux controller watches reboots and verifies recovery. Timed stress runs as a fixed-deadline job on the target, so a lost SSH session does not stop the workload.

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
TARGET=pi@hostname
ssh "$TARGET" true
ssh -o BatchMode=yes "$TARGET" true
```

Then use the two everyday commands:

```bash
autopioverclock prepare pi@hostname
autopioverclock overclock pi@hostname
```

- `prepare` installs missing workload dependencies and verifies the target's existing hardware-watchdog recovery chain. It does not change any watchdog.
- `overclock` starts a new search, uses compatible past failures to choose safe search ceilings, validates the result, applies it, reboots, and verifies it. After confirmation, it adds only the proof component needed for target network-loss attribution: a passive observer for a supported native Debian network watchdog, or a temporary gateway watcher when no recognized network watcher exists. On resume, a run-owned component migrates between those roles if the native service was started or stopped, after exact ownership verification. On the controller, each active run leases either its supported native Debian network watchdog or one shared temporary gateway companion. AutoPiOverclock never edits an existing native watchdog's configuration, repair command, or timeouts. On Batocera only, a stopped registered project keeper may be replaced temporarily by a hash-bound run companion as the sole userspace hardware owner; its unchanged files and service registration are restored after successful cleanup.

If a previous controller run was interrupted, use `autopioverclock resume pi@hostname` instead. In plain terms: use `overclock` when you want a new tuning decision; use `resume` when you want the same saved job to pick up where it stopped. If the controller reboots or loses its terminal during stress, run `resume` after it returns; the target-side deadline and retained result continue independently. Completed applied runs retain their immutable search baseline, so a later resume validates the original search and retained-history isolation evidence even though the applied clocks are now the target's normal clocks. `Ctrl-C` is different: it deliberately stops the active controller run and returns the target to normal clocks.

Every operational command requires a target. AutoPiOverclock intentionally ignores `~/.ssh/config`; use `--identity-file FILE` or `--ssh-port PORT` when needed.

> [!IMPORTANT]
> Batocera may require `prepare` to build its graphical payload on an ARM64 Debian-family controller. Its hardware-watchdog recovery chain must already be configured independently. AutoPiOverclock uses a recognized active permanent keeper directly. With an unrelated hardware owner, a temporary companion remains network-only. If a registered project permanent keeper is intentionally stopped and the device is unowned, a confirmed run may install a self companion that temporarily owns the hardware device, reuses the permanent keeper's target and timing values, and is the only network decision maker. The permanent files are never edited and their original service registration is restored after successful completion. Review [the Batocera notes](docs/batocera.md).

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

As of 2026-09-20, `prepare` and `overclock` are the two everyday commands, with `complete` available after a successfully applied overclock and `reset` available when a user wants to return to stock. A fresh public overclock uses compatible retained failure evidence by default, searches and qualifies CPU first, then GPU, and runs one 48-hour combined final validation. A domain with no useful retained limit uses the normal forward sweep. A clear retained ceiling starts a complete reverse sweep at the highest resolution-aligned clock strictly below that failed boundary. For a full run, the newest nondominated ambiguous failed pair automatically becomes the reverse-search anchor, and AutoPiOverclock begins with the CPU-lowered isolation branch instead of asking the user to repeat that pair through `--cpu-max` and `--gpu-max`. CPU coarse movement is normally 100 MHz and GPU coarse movement is normally 50 MHz; if a chosen resolution is larger, it also becomes that domain's coarse step. Ambiguous failed pairs use ordered CPU-only, GPU-only, then paired isolation rather than pretending either domain failed alone. Timed stress survives controller transport loss under a target-enforced deadline. A strictly proved chain of one or more consecutive network-watchdog reboots keeps only target-reported completed stress and runs the remaining duration at the same clocks. An unproved reboot earns no new time from its interrupted segment, retains only earlier proof-bound credit for the identical gate, and receives one conservative same-clock replay of the uncredited remainder before it can become stability evidence. Detached-job launch and result verification accept a contradictory child status only when the exact expected output is complete and structurally valid; every disagreement is diagnosed, while missing or malformed evidence still fails closed. The long-lived follow coprocess directly becomes its SSH transport, so controller shutdown terminates the exact local observer without orphaning a child. Target startup allows a bounded 15-second ownership handshake before declaring a loaded job orphaned. Raspberry Pi OS/Debian headless operation is automatic and does not require display or audio hardware.

| Evidence | Current status |
| --- | --- |
| Bash fixture suite | 28 scripted suites cover the normal/manual-test interface, retained-history planning and durable ledger, isolation scheduling, durable target stress jobs, live observers, progress calculations/rendering, installed entry point, state, classification, workers, tryboot, target and controller watchdog ownership and reboot proof, selection, resume, apply, complete, restore, reset, packaging, and public-safety contracts. |
| GitHub CI and ShellCheck | The workflow runs all fixture suites and ShellCheck; see the live badge for the current published `main` result. |
| Debian-family Raspberry Pi 5 run | One Debian 13 Pi 5 completed and applied a retained **alpha.39** result at **CPU 3100 MHz and V3D 1175 MHz with the firmware-default voltage state**. Each domain qualification ran for two hours; combined CPU/GPU/I/O validation ran for 24 hours; three additional candidate/normal boot cycles passed; maximum recorded temperature was 59.3 C with `throttled=0x0`; and the apply verification reboot passed. This proves that retained result, not the current history/search paths. |
| Batocera Raspberry Pi 5 run | Recovery and existing-watchdog observation have been exercised, but complete current-version end-to-end validation remains pending. |
| Default 48-hour combined final validation | Current-version hardware validation remains pending. The retained Debian result above proves its 24-hour run only; it does not prove the new 48-hour path. |

Do not infer a general production recommendation from one board, a candidate pass, an active run, or this table. Only a run that reaches `COMPLETE`, records `Validated: 1` under the current validation schema, and finishes `overclock` with `APPLY_STATUS=APPLIED` is installed by the normal workflow. The standalone expert `apply` command retains its separate confirmation.

## How automatic overclocking works

Every `autopioverclock overclock TARGET` invocation creates a fresh run. It never silently resumes or changes an older run. Before building the new plan, it strictly validates the target's durable machine-ledger v2 `history/failures.txt` and current-schema run states, then reuses proved CPU, GPU, and failed-pair boundaries. Unrelated audits and abandoned runs with no committed failure evidence are ignored. After `complete`, the sealed applied result in that ledger becomes the protected floor and every retained failure remains a hard exclusive ceiling. A failure at or below the sealed floor is contradictory and fails closed. If no manual maxima are supplied, the newest nondominated ambiguous failed pair can become the automatic full-run anchor only after every clear scalar ceiling is applied. The planning notice prints that anchor, its source run, the first isolated pair, retained ceilings, search directions, evidence, and ledger path. Explicit `--cpu-max` and `--gpu-max` values remain authoritative manual overrides after a warning. A fresh `--no-history` run skips the history scan and ledger update without deleting prior artifacts.

1. **Prove the installed baseline and recovery path.** Before any new search candidate, the controller temporarily boots the protected installed clocks, then returns to the same permanent config and verifies its hash, watchdog chain, normal boot, and owned `tryboot` cleanup. In a fresh full run this is the stock pair; in a one-domain run it is the retained applied pair.
2. **Search CPU first, by itself.** With no useful retained limit or explicit CPU ceiling, the normal forward sweep starts at 2500 MHz and rises in 100 MHz coarse steps. A clear CPU boundary, an automatically selected ambiguous-pair anchor, or `--cpu-max` starts a reverse search; the reverse sweep tests that exact ceiling first and descends until it finds a pass. It then refines the proved pass/fail gap at `--cpu-resolution` granularity, 25 MHz by default, to find the highest actual pass. GPU remains at the protected baseline throughout this CPU search.
3. **Qualify CPU.** The highest passing CPU is qualified for two hours by default with GPU still held at the protected baseline. A fully recovered CPU boot/stability failure lowers CPU by its configured resolution and repeats the complete qualification. It never crosses `--cpu-min`; if no CPU at or above that hard floor passes, the run fails with the rejected floor reported.
4. **Search and qualify GPU, by itself.** Only after CPU qualification passes, GPU/V3D uses the same policy while holding CPU at its qualified clock: forward in 50 MHz coarse steps with no clear GPU ceiling, or downward from a clear retained or explicit ceiling. An automatically selected ambiguous-pair anchor also starts the downward search at its GPU clock. It refines at `--gpu-resolution` granularity, 25 MHz by default, then runs the complete GPU qualification. A proved GPU failure lowers only GPU and never crosses `--gpu-min`.
5. **Validate one final result.** The selected pair runs one fresh 48-hour combined CPU/GPU/I/O validation by default. Exact CPU evidence lowers only CPU by `--cpu-resolution`; exact GPU evidence lowers only GPU by `--gpu-resolution`. If the domain is ambiguous, the pair becomes the anchor and a CPU-only reduction is tried first. If that also fails ambiguously, CPU is restored and a GPU-only reduction is tried; another ambiguous failure tries both reductions together. Exact evidence from any trial immediately follows the exact-domain rule instead. Each changed domain is requalified before a fresh full final run; if all three trials fail ambiguously, the paired reduction becomes the next anchor and isolation repeats. A required reduction below either hard minimum fails clearly instead of silently changing the requested range. One-domain mode can lower and requalify only its selected domain; exact evidence against the held domain stops. The controller never lowers below an inherited applied pair or changes its held domain. Every adjusted pair restarts the complete requested final duration from zero. Genuine clock, health, or workload failures receive no time credit; only the strictly proved network-watchdog reboot path below can retain conservative target-reported work at unchanged clocks.
6. **Keep stress running through controller outages.** Each timed stress gate is a uniquely owned detached job on the target with a fixed deadline and retained result. The controller reconnects indefinitely when SSH disappears and reattaches only to the exact saved job on the same boot. The progress line changes to one in-place reconnect spinner, then resumes its second-by-second countdown after SSH returns. If the controller itself restarts, `resume TARGET` performs the same ownership-checked reattachment. A reboot is called network-caused only when the hash-bound proof provider selected for that run supplies complete fresh evidence. AutoPiOverclock then keeps only the latest target-reported completed workload time and runs the exact remaining duration at identical clocks. During the replacement candidate boot, the ETA retains that validated credit before new stress telemetry begins. Without complete proof, the reboot is never called network-caused: the interrupted segment earns no new time, an earlier proof-bound checkpoint for the identical gate remains valid, and one conservative same-clock replay runs only the uncredited remainder. Another unattributed reboot enters the normal stability and domain-isolation policy. Other safely recovered harness failures retain their five complete-gate retries. Recovery uncertainty still stops.
7. **Apply only completed evidence.** The exact permanent diff is retained and shown, then the validated result is applied, rebooted, and re-proved. Maximum PWM fan cooling is temporary during candidate boots; the user's original fan policy returns on normal boots and after application.

`--cpu-only` and `--gpu-only` are mutually exclusive one-domain modes. They require and extend the target's latest eligible applied AutoPiOverclock result. CPU-only holds GPU/V3D at that retained, freshly re-proved clock; GPU-only holds CPU at that retained, freshly re-proved clock. Only the selected domain is swept and qualified, but the resulting pair still receives the complete combined final validation, apply, reboot, cooling, watchdog, retry, and recovery pipeline. `--cpu-min MHZ` and `--gpu-min MHZ` are hard floors: AutoPiOverclock never tunes below them and fails clearly if no permitted clock passes. `--cpu-max MHZ` and `--gpu-max MHZ` are optional manual overrides, not required history hints. They set inclusive ceilings and make their domains start in reverse; an explicit maximum remains authoritative even when it exceeds a retained history ceiling. `--cpu-resolution MHZ` and `--gpu-resolution MHZ` independently set refinement and automatic reduction granularity; each defaults to 25 and accepts a positive whole number from 1 through 1000 MHz. Coarse search uses `max(100, CPU resolution)` MHz for CPU and `max(50, GPU resolution)` MHz for GPU, so a deliberately larger resolution also creates a faster, more conservative coarse search. The baseline pair is always booted first for recovery proof. CPU-only accepts only CPU bounds/resolution, GPU-only accepts only GPU bounds/resolution, and the built-in maxima remain CPU 3200 MHz and GPU 1200 MHz.

The recommended public policy is two hours for each applicable qualification and one 48-hour final validation. `--qualification-hours HOURS` and `--final-hours HOURS` accept positive whole-hour values up to the portable timeout limit of 596523 hours; shorter tests reduce confidence and are recorded as custom policy. This high numeric ceiling is not a recommendation; it lets the hardware owner choose multi-week or month-long validation.

Maximum Pi PWM fan cooling is temporary during testing; the target's normal fan settings return afterward. Use `--no-max-fan` only when passive/external cooling or the normal fan policy is intentionally part of the test. Reduced cooling can reduce sustained performance or stability. Headless Debian-family targets require neither a display nor audio hardware.

The saved test lengths can be changed with positive whole-hour values:

```bash
autopioverclock overclock pi@hostname --qualification-hours 3 --final-hours 72
autopioverclock overclock pi@hostname --final-hours 720
```

## Commands

Every operational command requires a target such as `pi@hostname`.

| Command | What it does | Use it when... |
| --- | --- | --- |
| `prepare TARGET` | Installs missing workload dependencies and verifies the existing hardware-watchdog recovery chain without changing watchdog configuration. | Setting up a target, checking prerequisites, or checking readiness with `--dry-run`. |
| `overclock TARGET [OPTIONS]` | Starts a **new** history-guided tuning run, validates, applies, reboots, and verifies. | You want a new tuning decision. It never silently resumes an older run. |
| `test TARGET --cpu MHZ --gpu MHZ --final-hours HOURS` | Tests one exact pair for the requested whole-hour duration, then recovers normally; it never tunes or applies. | You already know the exact clocks and only want pass/fail evidence. |
| `reset TARGET` | Backs up the boot config, removes tuning, reboots, and verifies stock clocks. | You want to return the Pi to stock; it preserves run history. |
| `run TARGET [OPTIONS]` | Runs the expert interface with an optional strict configuration file. | Developing, supporting, or supplying an explicit custom plan. |
| `resume TARGET [OPTIONS]` | Continues a selected saved run and recovers first when necessary. | A controller was interrupted or you deliberately want to repeat a saved checkpoint. |
| `status TARGET` | Shows live clocks, quick health, tryboot/controller state, and a plain verdict. After `complete` deletes run state, an exact live match to the strict sealed ledger still reports `OVERCLOCKED / VALIDATED`. | You want a current snapshot without changing the run. |
| `summary TARGET` | Explains the newest tuning decisions, boundaries, retries, result, and next action. | You want the story of what happened rather than raw logs. |
| `recover TARGET` | Returns a selected run from temporary `tryboot` state to its protected permanent config. | A run stopped mid-candidate and the target needs safe normalization. |
| `restore TARGET` | Restores a retained, fully validated applied config after an outside edit. | The boot config was manually changed and you want AutoPiOverclock's validated bytes back. |
| `apply TARGET` | Applies a selected fully validated result after an exact diff and typed confirmation. | Using the expert `run` workflow; normal `overclock` applies its own result automatically. |
| `complete TARGET` | Seals the applied result and failure history, simplifies the permanent clock config, and removes that target's disposable run artifacts. | The selected overclock is fully validated, applied, and no longer needs to be resumable. |
| `report TARGET` | Generates a concise saved-run report. | Reviewing or sharing results; add `--redact` before sharing. |

### Options

| Option | Accepted by | Plain-language purpose |
| --- | --- | --- |
| `--qualification-hours HOURS` | `overclock`, `resume` | Change each applicable CPU/GPU qualification from the 2-hour default. |
| `--final-hours HOURS` | `overclock`, `resume`, `test` | Change final combined validation from the 48-hour default, or set an exact test's duration. |
| `--cpu-only` / `--gpu-only` | `overclock` | Start a new one-domain run from an eligible applied result while holding the other clock fixed. |
| `--cpu-min MHZ` / `--gpu-min MHZ` | `overclock` | Set a hard floor. The run never tunes below it and fails clearly if no permitted clock passes. |
| `--cpu-max MHZ` / `--gpu-max MHZ` | `overclock` | Optionally override history with an inclusive authoritative ceiling and start that domain in reverse. Built-in maxima are CPU 3200 and GPU 1200 MHz. |
| `--cpu-resolution MHZ` / `--gpu-resolution MHZ` | `overclock` | Set each domain's refinement and automatic reduction granularity. Default `25`; accepted range `1`–`1000` whole MHz. |
| `--no-history` | `overclock` | Ignore retained failures for this new run. Explicit maxima still select reverse search; other domains use their normal forward sweep. It deletes nothing. |
| `--no-max-fan` | `overclock`, `test`, `run` | Test with the target's ordinary cooling instead of temporary maximum Pi PWM fan cooling. |
| `--cpu MHZ` / `--gpu MHZ` | `test` | Select the exact CPU/GPU pair to test. Both are required. |
| `--restart-from POINT` | `resume` | Keep the saved position with `current`, or deliberately repeat `cpu-qualification`, `gpu-qualification`, or `final` in a saved full two-domain run. |
| `--run-id RUN_ID` | `resume`, `status`, `summary`, `recover`, `restore`, `apply`, `complete`, `report` | Select an older saved operation instead of the command's normal latest choice. |
| `--redact` | `status`, `summary`, `report` | Hide known target/controller identifiers from displayed or generated output. |
| `--output-dir DIR` | operational commands | Use `DIR` as this target's custom state directory, with disposable run artifacts in `DIR` and durable history in `DIR/history`. |
| `--ssh-port PORT` | operational commands | Connect to a nonstandard SSH port. |
| `--identity-file FILE` | operational commands | Use one explicit SSH private key. |
| `--config FILE` | `run` | Load a strict, data-only expert tuning plan. |
| `--mode MODE` | `run` | Force an expert run's validation mode to `auto`, `graphical`, or `headless`. |
| `--install-missing` | `run` | Authorize an expert run to install missing workload dependencies. |
| `--dry-run` | `prepare`, `run` | Perform read-only discovery and plan generation. |
| `--yes` | `run` | Skip the ordinary expert-run confirmation; it never bypasses `apply` confirmation. |
| `--help` / `--version` | global | Show CLI help or the installed version. |

Common examples:

```bash
# Start a new normal run. History automatically selects known clear or ambiguous limits.
autopioverclock overclock pi@hostname

# Let history choose the starting limits and require a fresh 100-hour final pass.
autopioverclock overclock pi@hostname --final-hours 100

# Manually override history only when you intentionally want different ceilings.
autopioverclock overclock pi@hostname --cpu-max 3075 --gpu-max 1200

# Use hard floors and finer 5 MHz refinement/backoff within the permitted range.
autopioverclock overclock pi@hostname --cpu-min 2900 --cpu-max 3075 --cpu-resolution 5 --gpu-min 1100 --gpu-max 1200 --gpu-resolution 5

# Tune only GPU from the latest eligible applied result.
autopioverclock overclock pi@hostname --gpu-only --gpu-min 1150 --gpu-max 1200

# Continue the latest interrupted saved run; do not start a new search.
autopioverclock resume pi@hostname

# Redo only the saved pair's final sequence, for a longer duration.
autopioverclock resume pi@hostname --restart-from final --final-hours 100

# Get evidence for one exact pair without tuning or applying it.
autopioverclock test pi@hostname --cpu 3100 --gpu 1150 --final-hours 72

# After a successful applied run, seal its history and remove disposable artifacts.
autopioverclock complete pi@hostname

# Later, verify readiness and continue tuning above the sealed applied clocks.
autopioverclock prepare pi@hostname
autopioverclock overclock pi@hostname
```

The inspection and recovery commands follow the same target-first form:

```bash
autopioverclock prepare pi@hostname --dry-run
autopioverclock status pi@hostname
autopioverclock summary pi@hostname
autopioverclock report pi@hostname --redact
autopioverclock recover pi@hostname
autopioverclock restore pi@hostname --run-id RUN_ID
autopioverclock apply pi@hostname --run-id RUN_ID
autopioverclock complete pi@hostname --run-id RUN_ID
autopioverclock reset pi@hostname
autopioverclock run pi@hostname --config plan.conf --mode headless --yes
```

An exact-pair `test` requires `--final-hours HOURS` (1–596523). `--restart-from` is resume-only and full two-domain only. See [the CLI reference](docs/cli.md) for exact recovery rules.

## Configuration

Configuration files are strict, data-only `KEY=VALUE` files. They are parsed, never sourced.

```ini
cpu_candidates_mhz=
gpu_candidates_mhz=
voltage_delta_uv=existing
candidate_duration_seconds=600
final_duration_seconds=172800
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

`voltage_delta_uv=existing` preserves the target's existing value; AutoPiOverclock never silently raises voltage. `final_duration_seconds` accepts 3,600–2,147,482,800 seconds for the advanced explicit plan, candidate boots cannot be lower than two, and final boot/recovery cycles cannot be lower than three. The simple hour options are preferred for automatic tuning because they bind qualification and final timing visibly in one command.

| Key | Meaning and accepted values |
| --- | --- |
| `cpu_candidates_mhz` | Strictly increasing comma-separated CPU clocks; each value 600–4000 MHz. Empty skips CPU tuning. |
| `gpu_candidates_mhz` | Strictly increasing comma-separated V3D clocks; each value 200–3000 MHz. Empty skips GPU tuning. |
| `voltage_delta_uv` | `existing`, or an explicit 0–100000 microvolt delta. |
| `candidate_duration_seconds` | Stress duration for each short search candidate; 10–86400 seconds. |
| `final_duration_seconds` | Combined endurance duration for an advanced explicit plan; 3600–2147482800 seconds. |
| `max_temp_c` | Exclusive temperature ceiling; 40–95 °C. Reaching the ceiling fails the candidate. |
| `telemetry_interval_seconds` | Temperature, clocks, throttle, and kernel-error sampling cadence; 1–60 seconds. Workload supervision still runs every second. |
| `conservative_backoff_steps` | Explicit-plan positions to step down from the maximum observed pass; 0–10. Automatic tuning instead refines to the highest pass and uses its saved per-domain resolutions for qualification backoff or final-pair isolation. |
| `candidate_boots` | Candidate/normal recovery cycles before candidate stress; 2–10. |
| `final_boots` | Post-endurance candidate/normal recovery cycles; 3–10. |
| `required_services` | Optional comma-separated service names that must remain active. |
| `frontend_process` | Optional single process name that must remain present. |
| `audio_sink_pattern` | Optional literal substring that, when set, the current default sink must match. |

## What every candidate must prove

- SSH returns after the expected boot.
- The firmware reports an active `tryboot` candidate.
- Requested clocks are observed under load within tolerance.
- With the default cooling policy, any detected Pi 5 PWM fan remains at setting 255 (100%) with a live tachometer when exposed; losing that test condition aborts without being labeled a CPU/GPU boundary. `--no-max-fan` uses the target's ordinary policy and does not claim or require PWM 255.
- Current/new throttle and undervoltage evidence remains clean.
- Temperature remains below the configured ceiling.
- No new filesystem, storage, USB-reset, GPU, kernel panic/internal error/Oops, RCU-stall, hung-task, or watchdog fault appears.
- The stress process exits successfully and within its hard deadline.
- Graphical runs preserve the required display/process/service baseline. The automatically discovered audio identity is recorded and compared after reboot, but a missing or changed inferred sink warns and continues when `audio_sink_pattern` is unset. If `audio_sink_pattern` is configured, its literal match is a strict harness requirement.
- Required services and processes remain healthy.
- Permanent configuration retains its original SHA-256 hash.
- The following recovery boot clears `tryboot` and passes normal health checks.

GPU harness failures are kept separate from clock-stability failures. A required graphical or headless backend that cannot launch, bind the hardware V3D renderer, complete with its required success evidence, preserve its display baseline, or satisfy an explicitly configured audio pattern is a `HARNESS_FAILURE`, not proof that the tested GPU clock is unstable. Missing or changed inferred audio alone produces one warning, consumes no retry, and never creates a CPU or GPU boundary. A positive score is required when glmark2 is the selected workload. Batocera graphical testing uses an off-screen Wayland workload on the live EmulationStation compositor; it does not take DRM master or stop and restore the frontend.

Stress timing is fail-closed. A token-bound detached supervisor on the target owns the fixed gate deadline using the target's boot-monotonic clock and retains the result, so disconnecting the controller or changing wall-clock time cannot shorten or extend the workload. Long CPU and GPU tools run in bounded one-hour subprocess segments beneath that one uninterrupted deadline; a clean segment immediately relaunches for the exact remaining time and never receives validation credit by itself. Batocera CPU load uses a 1 MiB SHA-256 benchmark measured in elapsed time. Because each workload and its Bash supervisor use independent whole-second clocks, a clean segment exit within 0.1% of that segment's expected duration is accepted only inside a 3-30 second bound; an earlier clean exit or any nonzero exit is still rejected. The target enforces a bounded 300-second shutdown grace after the requested duration, and the controller accepts completed output only after exact size and SHA-256 verification.

Read [Safety](docs/safety.md), [Architecture](docs/architecture.md), and [Output](docs/output.md) for the complete contracts and failure classes.

## Recovery and resume

The controller records a bounded timestamped history of distinct target workload samples while detached stress runs. If a recognized network watchdog is later proved to have requested one or more consecutive reboots, continuation credits the newest sample first observed at or before the final proved request. Heartbeats or telemetry received during a watchdog's reset delay cannot erase that safe sample or add post-request time. Malformed, inconsistent, or late-only history receives no credit.

Each candidate and final-validation substage is checkpointed atomically. The random tryboot ownership token, completed-file hash, reservation hash, token-specific quarantine path, and cooling policy are saved before remote creation can begin. Timed stress additionally saves a distinct job ID, 256-bit token, specification hash, source boot ID, phase, duration, and target start time before launch. Once that exact identity is committed, recurring progress checkpoints are advisory: a failed save is diagnosed and retried no sooner than one minute later without stopping the target job. If a different controller state save becomes fatal, cleanup preserves the job only when the last committed state still matches every in-memory ownership field exactly. An orderly controller exit still attempts normal recovery. An abrupt controller loss leaves the fixed-deadline target job running; `resume` reattaches to it instead of rebooting or starting a duplicate. Unknown or changed ownership evidence is preserved and fails closed.

Recurring checkpoint key ordering, timestamps, Base64 encoding, and collision-safe temporary creation use Bash built-ins rather than launching an encoder process for every state field. Filesystem sync, atomic replacement, exact post-write verification, and bounded I/O retries remain explicit. Internal descriptor cleanup and tryboot-open error suppression are scoped to the individual descriptor operation, so they cannot redirect the controller or worker's later standard error output.

An SSH transport timeout is not by itself a clock boundary. During timed stress, the target job continues while the controller retries indefinitely on one in-place reconnect spinner; a same-boot return reattaches by exact ownership and collects the retained result. During candidate boot or required post-stress health, individual validated reads still receive 30 attempts with 10-second spacing and safe read-only/idempotent worker gates receive up to five same-boot attempts. The controller records the exact candidate boot before transient worker redeployment. A changed boot during stress is excused as network-caused only when the run's recognized proof provider supplies a complete ordered chain from the saved source boot to the current boot. Every edge binds its boot IDs, configured liveness target, unchanged installed hashes, timestamp, active service, and matching prepared, committed, and next-boot-accepted durable records. On Debian, a supported native network watchdog is left unchanged and observed by a passive run-owned service; if no native network watcher exists, AutoPiOverclock installs an isolated temporary gateway watcher. Batocera uses a recognized active permanent keeper directly. A run-owned companion is network-only while a foreign process retains hardware ownership, or becomes the sole hardware/network provider when a registered project keeper is stopped; the chosen mode is saved and verified explicitly. Run-owned proof components are retained across interruptions and failures for safe resume, then removed after a successful run; native watchdogs, backups, logs, and evidence remain. Controller protection uses an unchanged supported native Debian watcher or one shared temporary companion protected by per-run leases. Only target-reported completed workload time observed before the final proved request is retained, and the unchanged pair runs the exact remaining duration. Wall-clock time and the SSH outage receive no credit. Missing, stale, late, or contradictory proof grants no time from the interrupted segment, retains only a valid earlier proof-bound checkpoint for the identical gate, and permits one conservative same-clock replay of the uncredited remainder; a second unattributed reboot of the identical gate is handled as stability evidence only after complete normal recovery. Protected-hash, tryboot ownership, or recovery uncertainty still stops.

All live mutating/recovery commands allow a full five-minute SSH/reboot budget, then continue read-only polling every 10 seconds without treating the timeout as a clock result; a status notice is emitted every five minutes. During connected active stress the countdown visibly changes every second. During an outage it changes to the reconnect spinner and does not invent target telemetry. The target stops stress at its hard deadline even if SSH has not returned, retains completion evidence, and does not keep stressing indefinitely. A controller reboot or lost terminal leaves the exact saved target job resumable; `Ctrl-C` deliberately stops and recovers it. If upgraded controller code resumes an older active job, watchdog setup uses a current sidecar worker and never replaces the exact worker owned by that job. After every expected or observed target reboot, the controller re-uploads the run-isolated worker and helper before collecting health evidence, so volatile `/tmp` cleanup is handled automatically. Terminal success clears the active SSH-recovery status and context while retaining the cumulative extended-wait count as historical evidence.

```bash
autopioverclock status pi@hostname --run-id RUN_ID
autopioverclock report pi@hostname --run-id RUN_ID
autopioverclock resume pi@hostname --run-id RUN_ID
autopioverclock recover pi@hostname --run-id RUN_ID
```

Without `--run-id`, `resume`, `recover`, `status`, and `report` select the target's latest retained operation. `summary` instead selects the newest actual tuning or manual-test run, ignoring newer prepare, reset, or restore audits; `restore` finds the newest eligible fully validated applied result. Use an explicit run ID when you intentionally want an older result. Only `resume` continues saved tuning progress. A new `overclock` always creates a new history-guided plan and never silently adopts an interrupted run.

For a current full two-domain automatic overclock, `resume` can deliberately repeat a retained checkpoint while taking all clocks from saved evidence:

```bash
autopioverclock resume pi@hostname --restart-from cpu-qualification --qualification-hours 2 --final-hours 48
autopioverclock resume pi@hostname --restart-from gpu-qualification --qualification-hours 2 --final-hours 48
autopioverclock resume pi@hostname --restart-from final --final-hours 48
```

The accepted checkpoints are `current`, `cpu-qualification`, `gpu-qualification`, and `final`. In layman's terms, `current` keeps the saved position; use it before final validation has started when you want to change the remaining test lengths without replaying completed sweep work. `cpu-qualification` rechecks CPU and everything after it; `gpu-qualification` keeps the saved qualified CPU but rechecks GPU and final validation; and `final` keeps the saved qualified pair and reruns its combined final sequence. The command line changes only allowed durations and the restart point; it never supplies replacement result clocks, and any omitted duration retains its saved value. The option is accepted only by `resume` for full two-domain runs. Prerequisite qualifications must already match the retained selected pair. An active final sequence can restart from `final` only after verified normal recovery, with no saved target job or tryboot ownership, and only when it was interrupted without a classified failure or stopped solely on a recovery failure. A clock, boot, stability, or harness result cannot be erased by restart.

The common reason to use `--restart-from final` is simple: the sweep already found and qualified a pair, but you want a longer burn-in without searching again. Unlike `test`, this stays inside the automatic tuning workflow, so a proved clock failure can trigger its saved per-domain isolation/backoff resolution and a passing result can be applied.

For a completed applied result, only `--restart-from final` is allowed; a longer requested final creates a linked fresh validation using the retained clocks and verified pre-apply stock backup. A fully recovered ambiguous full-mode boot/stability failure keeps stock active and follows the CPU-only, GPU-only, then paired isolation sequence at the saved per-domain resolutions only while evidence remains ambiguous; exact evidence switches immediately to its identified domain. A one-domain run reduces and requalifies only its selected domain and stops on exact evidence against the held domain. If that reduction reaches the inherited source pair, the rejected boundary remains recorded and the source pair receives a fresh selected-domain qualification and complete final; the held clock is never changed. Every adjusted pair runs the complete saved final duration from zero. Plain `resume TARGET` also adopts exact safely recovered unstructured worker-loss or clean-early-exit checkpoints for bounded automatic retry. Exhausted harness retries or recovery uncertainty remaining after bounded fallback still stops, and a primary recovery timeout alone never enters clock backoff or isolation. An older safety schema cannot bypass newer gates.

### Reset a target to verified stock defaults

Reset is command-first:

```bash
autopioverclock reset pi@hostname
```

No postfix reset spelling is accepted. Reset is noninteractive, so it neither needs nor accepts `--yes`. It also rejects run-selection, tuning, dependency, watchdog, dry-run, duration, fan-policy, mode, and redaction flags; only transport/output selectors may accompany it.

Before changing the permanent root boot config, reset requires a regular non-symlink config, a stable expected hash, no active `include` directive, and no foreign or ambiguous `tryboot.txt`/quarantine path. It writes a hash-verified, no-clobber backup under `/var/lib/autopioverclock/backups/` on Debian-family systems or `/userdata/system/autopioverclock/backups/` on Batocera. Standalone boost, fixed-clock, `*_freq`/`*_freq_min`, and `over_voltage*` lines are retained as comments prefixed with `# AUTOPIOVERCLOCK-STOCK-DISABLED`. The clock directives and markers in one structurally valid AutoPiOverclock managed block are removed, then global section headers are canonicalized without changing meaningful conditional scope. The verified backup keeps the complete original bytes.

An attributable AutoPiOverclock tryboot artifact is backed up before removal, while unknown paths are preserved and reset fails closed. If the running firmware reports a tryboot boot but no live or quarantined path exists, reset does not claim ownership of that boot; it safely prepares the backed-up permanent stock config, forces a normal reboot, and requires the post-reboot tryboot flag to be clear. Batocera must also restore and verify `/boot` read-only.

Reset then forces a permanent-config reboot and accepts success only after a new boot ID, an exact expected config hash, an absent/cleared tryboot state, and active Raspberry Pi 5 stock clocks are all verified: CPU 2400 MHz, firmware-default V3D 800 or 960 MHz, and the firmware-default voltage state. The same verification checks current throttle/power state and the active watchdog chain; reset does not claim the broader display, audio, service, or workload health gates used by tuning. A reset creates its own audit state/log and reports the remote backup path; it never deletes prior run artifacts or retained failure history, so a later fresh overclock can still avoid proved-bad clocks.

Reset does not run `tmux`, Byobu, job-control, or process-wide kill commands. If another controller still owns the per-target lock, reset fails without signaling that process or its terminal session; stop that one foreground controller yourself and repeat `autopioverclock reset TARGET`.

`recover` abandons or cleans up a selected run's temporary `tryboot` candidate and proves the permanent config already protected by that run; it does not restore an overwritten permanent file. `restore` backs up the current permanent config, reinstalls a retained fully validated applied config, reboots, and verifies it. `reset` removes permanent tuning and verifies firmware-stock clocks. These commands retain prior run artifacts. Only the separately confirmed `complete` command deletes them.

## Complete a finished overclock

`autopioverclock complete TARGET [--run-id RUN_ID]` accepts only a current-schema tuning run that passed full validation, was permanently applied, and owns no live target stress job. It holds the exclusive per-target controller lock while checking every retained state. A retained controller-only `RUNNING` or `PREPARING` checkpoint is identified as abandoned and included in the displayed cleanup plan, while retained target-side stress ownership still refuses cleanup. The command shows the exact permanent-config diff, lists the run IDs to be removed, and requires the typed confirmation `COMPLETE TARGET_SLUG RUN_ID`. It then verifies the simplified config and live health before deleting anything.

After the applied result is sealed and its original state has been removed, `complete TARGET` is repeatable without `--run-id`. It reconnects to the exact sealed target and verifies its hardware identity, boot paths, applied clocks, voltage, watchdog readiness, normal boot, clear throttle state, and current config hash. If the completed config still has redundant global headers or empty section labels, or its bytes were manually canonicalized without changing the sealed clock tuple, the command shows the exact current-to-canonical diff and requires `COMPLETE TARGET_SLUG SEALED_RUN_ID`. It installs only that hash-bound canonical proposal, verifies the installed bytes, and atomically rebinds the durable ledger to the new config hash. With no config or ledger repair and no later runs, it reports that completion is already finished. Strictly validated later successful `prepare` audits, history-planning preflight failures, or successful no-headroom results with no stress, watchdog lease, or tryboot ownership can still be listed and removed after confirmation.

Successful completion preserves the target's permanent native Debian watchdog or permanent Batocera watchdog and preserves unrelated boot settings and pre-existing comments. It removes only AutoPiOverclock's managed clock comments, watchdog boundary comments, completion hash marker, temporary candidate fan override, run-owned target/controller watchdog helpers, harness directories, backups, logs, reports, evidence, and state for that target. The native watchdog directive and timeout remain ordinary settings. A global-only final boot config is canonicalized to exactly one `[all]` before its first active directive. If the file has a meaningful model, serial, or other conditional section, that section and the `[all]` reset it requires are preserved while redundant global headers and empty section labels are removed. The validated `over_voltage_delta`, `arm_freq`, and detected GPU clock key remain ordinary global settings, and the user's original fan settings remain.

Completion is intentionally destructive and makes those deleted runs non-resumable. Before cleanup, it atomically consolidates their human-readable failures, strict encoded machine history, and the validated applied clock/config binding into `history/failures.txt`. That file is retained permanently so a later `prepare` followed by `overclock` can prove the applied clocks as its protected floor and continue upward without retesting from stock.

## Results

By default, controller state is separated by target below `${XDG_STATE_HOME:-$HOME/.local/state}/autopioverclock/targets/`. Each target has disposable `runs/` and permanent `history/` directories. A typical layout is:

```text
~/.local/state/autopioverclock/targets/target/
|-- runs/
|   |-- target-20260823-010000-a1b2c3d4e5f60708.log
|   |-- target-20260823-010000-a1b2c3d4e5f60708.state
|   |-- target-20260823-010000-a1b2c3d4e5f60708-summary.txt
|   `-- target-latest.state
`-- history/
    `-- failures.txt
```

The atomic `.state`, log, event stream, and summary are written during a run. The finalized `.json` array is generated when the controller exits through its cleanup handler, so its target can be absent while a run is active or after an uncatchable kill; that does not mean the saved state was lost. See [the output reference](docs/output.md) for artifact fields and failure classifications.

`history/failures.txt` is both a readable failure ledger and strict machine scheduling input. Every fresh history-enabled public overclock validates the encoded section, combines it with compatible current run states, and atomically replaces the ledger only when the materially derived content changes. `complete` also seals the applied clock tuple, permanent-config hash, run schema, and validation schema into it before deleting run state. With unchanged evidence, its bytes, inode, `Generated:` time, and filesystem timestamp stay untouched. `resume` always uses the selected run's immutable saved plan and never rescans mutable history. A fresh `--no-history` run does not scan or modify the ledger.

For each clear failed boundary `F`, applied floor `P`, and configured resolution `R`, automatic history planning uses `P + floor((F - P - 1) / R) * R` as the highest legal candidate. A failure at or below the validated floor is contradictory and stops before any reboot or clock change. A positive gap no larger than one resolution step has no legal candidate, so that domain is skipped while the other domain may continue. If neither domain has a legal resolution-sized step outside every retained failed-pair frontier, the new run completes successfully as a no-op without confirmation, reboot, clock change, stress, or apply. A failed pair is an exclusive northeast boundary, and a pair containing the applied floor is contradictory. Explicit `--cpu-max` or `--gpu-max` remains the only intentional override of the corresponding retained ceiling and is announced before testing.

A completed automatic result must show `Status: PASS`, `Phase: COMPLETE`, `Validated: 1`, and, after the normal `overclock` flow finishes, `APPLY_STATUS=APPLIED`.

A successful apply adds a small managed block and leaves unrelated boot settings intact:

```ini
# BEGIN AUTOPIOVERCLOCK MANAGED CLOCKS
# Run: RUN_ID
[all]
arm_freq=3100
v3d_freq=1175
# END AUTOPIOVERCLOCK MANAGED CLOCKS
```

Those clocks are only an example. Before `complete`, leave the managed markers intact so `autopioverclock reset TARGET` can remove the block safely. After `complete`, the same validated values remain as simple settings without AutoPiOverclock comments; the sealed ledger becomes the binding evidence for future tuning.

Before sharing, generate `autopioverclock report TARGET --redact` and still review the report for private hostnames, addresses, or other context.

AutoPiOverclock is licensed under the [Apache License 2.0](LICENSE). See [Contributing](CONTRIBUTING.md) and [Security](SECURITY.md).
