# AutoPiOverclock

**Recoverable, controller-driven Raspberry Pi 5 overclocking over SSH.**

[![CI](https://github.com/p1r473/AutoPiOverclock/actions/workflows/ci.yml/badge.svg)](https://github.com/p1r473/AutoPiOverclock/actions/workflows/ci.yml)

AutoPiOverclock searches for CPU and GPU clocks, stress-validates the result for 48 hours by default, and applies it without replacing the rest of your boot configuration. Candidate clocks use Raspberry Pi `tryboot.txt`, while a separate Linux controller watches reboots and verifies recovery.

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

- `prepare` installs and verifies target prerequisites and recovery safeguards, and may update watchdog files and reboot the target.
- `overclock` starts a new search, uses compatible past failures to avoid known-bad clocks, validates the result, applies it, reboots, and verifies it.

If a previous controller run was interrupted, use `autopioverclock resume pi@hostname` instead. In plain terms: use `overclock` when you want a new tuning decision; use `resume` when you want the same saved job to pick up where it stopped.

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

As of 2026-09-08, `alpha.53` keeps `prepare` and `overclock` as the two everyday commands, with `reset` available when a user wants to return to stock and start over. A fresh public overclock uses compatible retained failure evidence by default, searches and qualifies CPU first, then GPU, and runs one 48-hour combined final validation. Clear one-domain failures cap that domain below its proved boundary; ambiguous failed pairs use ordered CPU-only, GPU-only, then paired 25 MHz isolation. Transient reads, safely recovered harness failures, and fully proven stalled Batocera normal-return requests receive bounded complete-gate retries, while real active config drift, ownership ambiguity, and uncertain recovery still stop. Raspberry Pi OS/Debian headless operation is automatic and does not require display or audio hardware.

| Evidence | Current status |
| --- | --- |
| Bash fixture suite | 23 scripted suites cover the normal/manual-test interface, retained-history planning, isolation scheduling, live observers, progress calculations/rendering, installed entry point, state, classification, workers, tryboot, watchdog installation, selection, resume, apply, restore, reset, packaging, and public-safety contracts. |
| GitHub CI and ShellCheck | The workflow runs all fixture suites and ShellCheck; see the live badge for the current published `main` result. |
| Debian-family Raspberry Pi 5 run | One Debian 13 Pi 5 completed and applied a retained **alpha.39** result at **CPU 3100 MHz and V3D 1175 MHz with the firmware-default voltage state**. Each domain qualification ran for two hours; combined CPU/GPU/I/O validation ran for 24 hours; three additional candidate/normal boot cycles passed; maximum recorded temperature was 59.3 C with `throttled=0x0`; and the apply verification reboot passed. This proves that retained result, not alpha.53's current history/search paths. |
| Batocera Raspberry Pi 5 run | Recovery and watchdog preparation have been exercised, but complete `alpha.53` end-to-end validation remains pending. |
| Default 48-hour combined final validation | Current-version hardware validation remains pending. The retained Debian result above proves its 24-hour run only; it does not prove the new 48-hour path. |

Do not infer a general production recommendation from one board, a candidate pass, an active run, or this table. Only a run that reaches `COMPLETE`, records `Validated: 1` under the current validation schema, and finishes `overclock` with `APPLY_STATUS=APPLIED` is installed by the normal workflow. The standalone expert `apply` command retains its separate confirmation.

## How automatic overclocking works

Every `autopioverclock overclock TARGET` invocation creates a fresh run. It never silently resumes or changes an older run. Before building the new plan, it screens retained state metadata, ignores and preserves older or missing schemas, strictly validates compatible current-schema evidence-bearing automatic runs, and reuses proved CPU, GPU, and failed-pair boundaries. Unrelated audits and abandoned runs with no committed failure evidence are ignored. It prints `History ceilings: CPU=...; GPU=...` with the requested maxima, retained evidence, and `target-failures.txt` path. Unless explicit `--cpu-min` or `--gpu-min` values are supplied, a history-guided run approaches each retained ceiling from one normal coarse step below it—100 MHz for CPU and 50 MHz for GPU—so it re-proves a nearby lower clock without repeating the entire low-end ladder. The ordinary CPU-first/GPU-second separation still prevents one domain from being guessed from the other. A fresh `--no-history` run skips the state scan and ledger update without deleting prior artifacts.

1. **Prove the installed baseline and recovery path.** Before any new search candidate, the controller temporarily boots the protected installed clocks, then returns to the same permanent config and verifies its hash, watchdog chain, normal boot, and owned `tryboot` cleanup. In a fresh full run this is the stock pair; in a one-domain run it is the retained applied pair.
2. **Search CPU first.** Without useful history, CPU starts at 2500 MHz and searches through 3200 MHz in 100 MHz steps with 10-minute candidates. With compatible history, it starts near the retained ceiling as described above. Either path refines a proved failure gap in 25 MHz steps to the highest actual pass.
3. **Qualify CPU.** The highest passing CPU is qualified for two hours by default with GPU held at the protected baseline (stock in a normal full run). A fully recovered CPU boot/stability failure steps CPU down 25 MHz and repeats the complete qualification.
4. **Search and qualify GPU.** Searches GPU/V3D through 1200 MHz in 50 MHz steps only after CPU qualification passes, starting near a compatible history ceiling when available, then refines in 25 MHz steps to the highest actual pass. GPU is qualified at the selected CPU; a fully recovered GPU boot/stability failure steps GPU down 25 MHz and repeats the complete qualification.
5. **Validate one final result.** The selected pair runs one fresh 48-hour combined CPU/GPU/I/O validation by default. Exact CPU evidence lowers only CPU; exact GPU evidence lowers only GPU. If the domain is ambiguous, the pair becomes the anchor and CPU 25 MHz lower is tried first. If that attempt also fails ambiguously, CPU is restored and GPU 25 MHz lower is tried; another ambiguous failure tries both 25 MHz lower. Exact evidence from any trial immediately follows the exact-domain rule instead. Each changed domain is requalified before a fresh full final run; if all three trials fail ambiguously, the paired reduction becomes the next anchor and isolation repeats. One-domain mode can lower and requalify only its selected domain; exact evidence against the held domain stops. If the last 25 MHz above the inherited source fails, the rejected boundary is retained, the selected domain is requalified exactly at that source pair, and a fresh complete final starts from zero. The controller never lowers below the inherited pair or changes the held domain. This avoids sacrificing a stable domain. Even a failure near the end invalidates that attempt, so elapsed time is never credited.
6. **Recover and retry automatically.** A safely recovered structured or unstructured harness failure repeats the complete affected boot, stress, or health gate up to five times. A primary normal-return handshake timeout is provisional: only a bounded fallback that fully proves the protected permanent-normal configuration and clocks, clear tryboot state and owned-file cleanup, watchdog chain, and normal health may replay the complete affected gate under that same persisted five-retry budget. Incomplete fallback proof remains `RECOVERY_FAILURE`. A timeout alone never lowers either clock or starts domain isolation.
7. **Apply only completed evidence.** The exact permanent diff is retained and shown, then the validated result is applied, rebooted, and re-proved. Maximum PWM fan cooling is temporary during candidate boots; the user's original fan policy returns on normal boots and after application.

`--cpu-only` and `--gpu-only` are mutually exclusive one-domain modes. They require and extend the target's latest eligible applied AutoPiOverclock result. CPU-only holds GPU/V3D at that retained, freshly re-proved clock; GPU-only holds CPU at that retained, freshly re-proved clock. Only the selected domain is swept and qualified, but the resulting pair still receives the complete combined final validation, apply, reboot, cooling, watchdog, retry, and recovery pipeline. `--cpu-min MHZ` and `--gpu-min MHZ` set 25 MHz-aligned lower bounds for new candidates; `--cpu-max MHZ` and `--gpu-max MHZ` set inclusive ceilings, so a ceiling between coarse steps is still tested. The baseline pair is always booted first for recovery proof. CPU-only accepts only CPU bounds, GPU-only accepts only GPU bounds, and the built-in ceilings remain CPU 3200 MHz and GPU 1200 MHz.

The recommended public policy is two hours for each applicable qualification and one 48-hour final validation. `--qualification-hours HOURS` and `--final-hours HOURS` accept positive whole-hour values up to the portable timeout limit of 596523 hours; shorter tests reduce confidence and are recorded as custom policy. This high numeric ceiling is not a recommendation—it lets the hardware owner choose multi-week or month-long validation.

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
| `prepare TARGET` | Installs and verifies dependencies and watchdog recovery. | Setting up a target, repairing prerequisites, or checking readiness with `--dry-run`. |
| `overclock TARGET [OPTIONS]` | Starts a **new** history-guided tuning run, validates, applies, reboots, and verifies. | You want a new tuning decision. It never silently resumes an older run. |
| `test TARGET --cpu MHZ --gpu MHZ DURATION` | Tests one exact pair, then recovers normally; it never tunes or applies. | You already know the exact clocks and only want pass/fail evidence. |
| `reset TARGET` | Backs up the boot config, removes tuning, reboots, and verifies stock clocks. | You want to return the Pi to stock; it preserves run history. |
| `run TARGET [OPTIONS]` | Runs the expert interface with an optional strict configuration file. | Developing, supporting, or supplying an explicit custom plan. |
| `resume TARGET [OPTIONS]` | Continues a selected saved run and recovers first when necessary. | A controller was interrupted or you deliberately want to repeat a saved checkpoint. |
| `status TARGET` | Shows live clocks, quick health, tryboot/controller state, and a plain verdict. | You want a current snapshot without changing the run. |
| `summary TARGET` | Explains the newest tuning decisions, boundaries, retries, result, and next action. | You want the story of what happened rather than raw logs. |
| `recover TARGET` | Returns a selected run from temporary `tryboot` state to its protected permanent config. | A run stopped mid-candidate and the target needs safe normalization. |
| `restore TARGET` | Restores a retained, fully validated applied config after an outside edit. | The boot config was manually changed and you want AutoPiOverclock's validated bytes back. |
| `apply TARGET` | Applies a selected fully validated result after an exact diff and typed confirmation. | Using the expert `run` workflow; normal `overclock` applies its own result automatically. |
| `report TARGET` | Generates a concise saved-run report. | Reviewing or sharing results; add `--redact` before sharing. |

### Options

| Option | Accepted by | Plain-language purpose |
| --- | --- | --- |
| `--qualification-hours HOURS` | `overclock`, `resume` | Change each applicable CPU/GPU qualification from the 2-hour default. |
| `--final-hours HOURS` | `overclock`, `resume`, `test` | Change final combined validation from the 48-hour default, or set an exact test's duration. |
| `--cpu-only` / `--gpu-only` | `overclock` | Start a new one-domain run from an eligible applied result while holding the other clock fixed. |
| `--cpu-min MHZ` / `--gpu-min MHZ` | `overclock` | Explicitly choose the first new candidate instead of the history-guided starting point. Values are 25 MHz aligned. |
| `--cpu-max MHZ` / `--gpu-max MHZ` | `overclock` | Set an inclusive 25 MHz-aligned ceiling; built-in maxima are CPU 3200 and GPU 1200 MHz. |
| `--no-history` | `overclock` | Ignore retained failures for this new run and build a full fresh ladder. It deletes nothing. |
| `--no-max-fan` | `overclock`, `test`, `run` | Test with the target's ordinary cooling instead of temporary maximum Pi PWM fan cooling. |
| `--cpu MHZ` / `--gpu MHZ` | `test` | Select the exact CPU/GPU pair to test. Both are required. |
| `--minutes MINUTES` | `test` | Legacy exact-test duration; use this or `--final-hours`, never both. |
| `--restart-from POINT` | `resume` | Keep the saved position with `current`, or deliberately repeat `cpu-qualification`, `gpu-qualification`, or `final` in a saved full two-domain run. |
| `--run-id RUN_ID` | `resume`, `status`, `summary`, `recover`, `restore`, `apply`, `report` | Select an older saved operation instead of the command's normal latest choice. |
| `--redact` | `status`, `summary`, `report` | Hide known target/controller identifiers from displayed or generated output. |
| `--output-dir DIR` | operational commands | Store/read flat artifacts somewhere other than `$HOME/overclock-results`. |
| `--ssh-port PORT` | operational commands | Connect to a nonstandard SSH port. |
| `--identity-file FILE` | operational commands | Use one explicit SSH private key. |
| `--config FILE` | `run` | Load a strict, data-only expert tuning plan. |
| `--mode MODE` | `run` | Force an expert run's validation mode to `auto`, `graphical`, or `headless`. |
| `--install-missing` | `run` | Authorize an expert run to install missing workload dependencies. |
| `--repair-watchdogs` | `run` | Authorize an expert run to repair a planned watchdog deficiency. |
| `--dry-run` | `prepare`, `run` | Perform read-only discovery and plan generation. |
| `--yes` | `run` | Skip the ordinary expert-run confirmation; it never bypasses `apply` confirmation. |
| `--help` / `--version` | global | Show CLI help or the installed version. |

Common examples:

```bash
# Start a new normal run. Compatible history supplies safe ceilings and a near-ceiling start.
autopioverclock overclock pi@hostname

# Start a new 72-hour final policy with explicit search bounds.
autopioverclock overclock pi@hostname --cpu-min 2900 --cpu-max 3100 --gpu-min 1100 --gpu-max 1200 --final-hours 72

# Tune only GPU from the latest eligible applied result.
autopioverclock overclock pi@hostname --gpu-only --gpu-min 1150 --gpu-max 1200

# Continue the latest interrupted saved run; do not start a new search.
autopioverclock resume pi@hostname

# Redo only the saved pair's final sequence, for a longer duration.
autopioverclock resume pi@hostname --restart-from final --final-hours 100

# Get evidence for one exact pair without tuning or applying it.
autopioverclock test pi@hostname --cpu 3100 --gpu 1150 --final-hours 72
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
autopioverclock reset pi@hostname
autopioverclock run pi@hostname --config plan.conf --mode headless --yes
```

An exact-pair `test` requires exactly one duration option: `--final-hours HOURS` (1–596523) or legacy `--minutes MINUTES` (1–35791380). `--restart-from` is resume-only and full two-domain only. See [the CLI reference](docs/cli.md) for exact compatibility and recovery rules.

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
| `conservative_backoff_steps` | Explicit-plan positions to step down from the maximum observed pass; 0–10. Automatic tuning instead refines to the highest pass and uses 25 MHz qualification backoff or final-pair isolation. |
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

Stress timing is fail-closed. Long CPU and GPU tools run in bounded one-hour subprocess segments beneath one uninterrupted shared gate deadline; a clean segment immediately relaunches for the exact remaining wall time and never receives validation credit by itself. Batocera CPU load uses a 1 MiB SHA-256 benchmark measured in elapsed time. Because each workload and its Bash supervisor use independent whole-second clocks, a clean segment exit within 0.1% of that segment's expected duration is accepted only inside a 3–30 second bound; an earlier clean exit or any nonzero exit is still rejected. Workloads retain a separate 60-second shutdown deadline after the full requested duration, and controller SSH/reboot budgets include wall time spent inside connection attempts instead of silently stretching a nominal recovery timeout.

Read [Safety](docs/safety.md), [Architecture](docs/architecture.md), and [Output](docs/output.md) for the complete contracts and failure classes.

## Recovery and resume

Each candidate and final-validation substage is checkpointed atomically. The random ownership token, completed-file hash, reservation hash, token-specific quarantine path, and cooling policy are saved before remote creation can begin. If the controller exits while `tryboot` may be active, its exit trap attempts normal recovery. `resume` repeats recovery first whenever saved or live evidence says the target may still be in `tryboot`, verifies normal recovery, and cleans only token/hash-matching project evidence; an unknown or changed path is preserved and fails closed. A resumed run keeps its saved cooling policy rather than changing test conditions halfway through.

An SSH transport timeout is not by itself a clock boundary. Before classifying missing controller evidence, individual validated reads receive 30 attempts with 10-second spacing and safe read-only/idempotent worker gates receive up to five same-boot attempts. During candidate boot, active stress, or required post-stress health, the controller records the exact candidate boot as soon as it appears—even before transient worker redeployment. Only complete normal recovery proving a later boot ID, clear tryboot flag, owned-file cleanup, protected hash, protected permanent-normal clocks, and watchdog health can promote an unstructured loss to the appropriate `BOOT_FAILURE` or `STABILITY_FAILURE`. A primary normal-return handshake timeout is instead provisional. Bounded fallback may turn that episode into retryable `HARNESS_FAILURE` only after freshly proving the protected permanent-normal configuration and clocks, clear tryboot state and owned cleanup, watchdog chain, and normal health. The complete affected gate then restarts from zero under the existing persisted five-retry budget; fallback is not a second retry pool. If proof remains incomplete, the result remains `RECOVERY_FAILURE`, and the timeout never enters clock backoff or domain isolation. The exact older controller-only “permanent config hash is unavailable” state is adopted only after protected normal health and the exact hash are freshly re-proved.

All live mutating/recovery commands allow a full five-minute SSH/reboot budget, then continue read-only polling every 10 seconds without treating the timeout as a clock result; a status notice is emitted every five minutes. Any normal-return fallback remains bounded and uses the existing ownership-checked recovery protocol rather than creating another retry pool. `Ctrl-C` leaves the saved run resumable. After every expected or observed reboot, the controller re-uploads the run-isolated worker before collecting health evidence, so volatile `/tmp` cleanup is handled automatically.

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

The accepted checkpoints are `current`, `cpu-qualification`, `gpu-qualification`, and `final`. In layman's terms, `current` keeps the saved position; use it before final validation has started when you want to change the remaining test lengths without replaying completed sweep work. `cpu-qualification` rechecks CPU and everything after it; `gpu-qualification` keeps the saved qualified CPU but rechecks GPU and final validation; and `final` keeps the saved qualified pair and reruns its combined final sequence. The command line changes only allowed durations and the restart point; it never supplies replacement result clocks, and any omitted duration retains its saved value. The option is accepted only by `resume` for full two-domain runs. Prerequisite qualifications must already match the retained selected pair, and an active final sequence cannot be rewound or relabeled.

The common reason to use `--restart-from final` is simple: the sweep already found and qualified a pair, but you want a longer burn-in without searching from the bottom again. Unlike `test`, this stays inside the automatic tuning workflow, so a proved clock failure can trigger its normal 25 MHz isolation/backoff and a passing result can be applied.

For a completed applied result, only `--restart-from final` is allowed; a longer requested final creates a linked fresh validation using the retained clocks and verified pre-apply stock backup. A fully recovered ambiguous full-mode boot/stability failure keeps stock active and follows the CPU-only, GPU-only, then paired 25 MHz isolation sequence only while evidence remains ambiguous; exact evidence switches immediately to its identified domain. A one-domain run reduces and requalifies only its selected domain and stops on exact evidence against the held domain. If that reduction reaches the inherited source pair, the rejected boundary remains recorded and the source pair receives a fresh selected-domain qualification and complete final; the held clock is never changed. Every attempt runs the complete saved final duration from zero. Plain `resume TARGET` also adopts exact safely recovered unstructured worker-loss or clean-early-exit checkpoints for bounded automatic retry. Exhausted harness retries or recovery uncertainty remaining after bounded fallback still stops, and a primary recovery timeout alone never enters clock backoff or isolation. An older safety schema cannot bypass newer gates.

### Reset a target to verified stock defaults

Reset is command-first:

```bash
autopioverclock reset pi@hostname
```

No postfix reset spelling is accepted. Reset is noninteractive, so it neither needs nor accepts `--yes`. It also rejects run-selection, tuning, dependency, watchdog, dry-run, duration, fan-policy, mode, and redaction flags; only transport/output selectors may accompany it.

Before changing the permanent root boot config, reset requires a regular non-symlink config, a stable expected hash, no active `include` directive, and no foreign or ambiguous `tryboot.txt`/quarantine path. It writes a hash-verified, no-clobber backup under `/var/lib/autopioverclock/backups/` on Debian-family systems or `/userdata/system/autopioverclock/backups/` on Batocera. Standalone boost, fixed-clock, `*_freq`/`*_freq_min`, and `over_voltage*` lines are retained as comments prefixed with `# AUTOPIOVERCLOCK-STOCK-DISABLED`; the clock directives and markers in one structurally valid AutoPiOverclock managed block are removed while its `[all]` section boundary is retained, with the complete original bytes in the verified backup.

An attributable AutoPiOverclock tryboot artifact is backed up before removal, while unknown paths are preserved and reset fails closed. If the running firmware reports a tryboot boot but no live or quarantined path exists, reset does not claim ownership of that boot; it safely prepares the backed-up permanent stock config, forces a normal reboot, and requires the post-reboot tryboot flag to be clear. Batocera must also restore and verify `/boot` read-only.

Reset then forces a permanent-config reboot and accepts success only after a new boot ID, an exact expected config hash, an absent/cleared tryboot state, and active Raspberry Pi 5 stock clocks are all verified: CPU 2400 MHz, firmware-default V3D 800 or 960 MHz, and the firmware-default voltage state. The same verification checks current throttle/power state and the active watchdog chain; reset does not claim the broader display, audio, service, or workload health gates used by tuning. A reset creates its own audit state/log and reports the remote backup path; it never deletes prior run artifacts or retained failure history, so a later fresh overclock can still avoid proved-bad clocks.

Reset does not run `tmux`, Byobu, job-control, or process-wide kill commands. If another controller still owns the per-target lock, reset fails without signaling that process or its terminal session; stop that one foreground controller yourself and repeat `autopioverclock reset TARGET`.

`recover` abandons or cleans up a selected run's temporary `tryboot` candidate and proves the permanent config already protected by that run; it does not restore an overwritten permanent file. `restore` backs up the current permanent config, reinstalls a retained fully validated applied config, reboots, and verifies it. `reset` removes permanent tuning and verifies firmware-stock clocks. None deletes prior run artifacts.

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
target-failures.txt
target-latest.log
target-latest-summary.txt
target-latest.state
target-latest.json
```

The atomic `.state`, log, event stream, and summary are written during a run. The finalized `.json` array is generated when the controller exits through its cleanup handler, so its target can be absent while a run is active or after an uncatchable kill; that does not mean the saved state was lost. See [the output reference](docs/output.md) for artifact fields and failure classifications.

`target-failures.txt` is a human-readable audit derived from the authoritative `.state` files, not scheduling input. Every fresh history-enabled public overclock rescans those states, creates the ledger if missing, and atomically replaces it only when the materially derived content changes. With unchanged evidence, its bytes, inode, `Generated:` time, and filesystem timestamp stay untouched. `resume` uses the selected run's saved plan without rescanning; a fresh `--no-history` run does not scan or modify the ledger.

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
