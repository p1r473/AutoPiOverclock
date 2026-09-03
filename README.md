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
- key-based SSH access from the controller to the target; and
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
> Batocera may require `prepare` to install a bounded network-loss watchdog. Review [the Batocera preparation notes](docs/batocera.md#watchdog-preparation) before approving that change.

## Supported targets

AutoPiOverclock supports 64-bit Raspberry Pi 5 targets running Raspberry Pi OS, Debian, Ubuntu with a Raspberry Pi boot layout, or Batocera. Graphical and headless operation are supported. The controller must be a separate Linux machine; Debian or Ubuntu with GNU tools is the tested controller path.

“Supported” means an implemented, fixture-tested alpha path—not a guarantee for every OS image, cooler, power supply, or board. Arch Linux and generic Linux layouts are outside the current scope.

## Current validation status

AutoPiOverclock is alpha software. The live CI badge reports the current commit's automated status; fixtures are not hardware validation.

One Debian 13 Raspberry Pi 5 completed and applied a retained default-policy run at **CPU 3100 MHz and V3D 1175 MHz with the firmware-default voltage delta**. CPU and GPU qualification each ran for two hours, the final combined CPU/GPU/I/O validation ran for 24 hours, three additional candidate/normal boot cycles passed, maximum recorded temperature was 59.3 C with `throttled=0x0`, and the apply verification reboot passed.

That proves one board and cooling setup only; it is not a clock recommendation. Complete Batocera end-to-end validation is still pending.

## How automatic overclocking works

`autopioverclock overclock TARGET`:

1. Proves firmware-stock clocks, the protected permanent-config hash, watchdog recovery, normal boot health, cooling, and the owned `tryboot` lifecycle.
2. Searches CPU from 2500 through 3200 MHz in 100 MHz steps, refines a proved boundary in 25 MHz steps, backs off 50 MHz, and qualifies CPU for two hours with GPU held at stock.
3. Searches GPU/V3D through 1200 MHz, refines a proved boundary in 25 MHz steps, backs off 25 MHz, and qualifies the CPU/GPU pair for two hours.
4. Tests CPU exactly 25 MHz above the guarded result for 24 hours under combined CPU, GPU, and I/O load. A full pass becomes the final result. If the edge is known unsafe or safely rejected, the guarded pair receives one fresh 24-hour validation instead; the two long tests are alternatives.
5. Shows and retains the exact permanent diff, applies only completed evidence, reboots, and verifies the result.

Recoverable instability backs off automatically. Safely recovered transient harness failures repeat the complete affected gate up to five times. A guarded-pair failure reduces every still-overclocked domain by its guard, repeats both qualifications, and starts a fresh final sequence. Voltage remains at the discovered stock delta.

Maximum Pi PWM fan cooling is temporary during testing; the target's normal fan settings return afterward. Use `--no-max-fan` only when passive/external cooling or the normal fan policy is intentionally part of the test. Reduced cooling can reduce sustained performance or stability. Headless Debian-family targets require neither a display nor audio hardware.

The saved test lengths can be changed with whole-hour values from 1 through 168:

```bash
autopioverclock overclock pi@pi-host --qualification-hours 3 --final-hours 36 --edge-hours 18
```

Shorter tests reduce confidence and are recorded as a custom policy.

## Commands

| Command | Purpose |
| --- | --- |
| `prepare TARGET` | Install and verify dependencies and recovery safeguards; `--dry-run` performs read-only discovery. |
| `overclock TARGET` | Automatically tune, validate, apply, reboot, and verify. |
| `test TARGET --cpu MHZ --gpu MHZ --minutes MINUTES` | Test one exact pair without validating or applying it. |
| `reset TARGET` | Back up the boot config, remove permanent tuning, reboot, and verify stock clocks. |
| `run TARGET [OPTIONS]` | Run the advanced interface with an explicit plan or controls. |
| `resume TARGET [--run-id RUN_ID]` | Recover if needed and continue retained progress. |
| `status TARGET [--run-id RUN_ID] [--redact]` | Show retained state without touching the target. |
| `recover TARGET [--run-id RUN_ID]` | Return a saved run to its protected normal config and stop. |
| `apply TARGET [--run-id RUN_ID]` | Apply an eligible completed run after an exact diff and typed confirmation. |
| `report TARGET [--run-id RUN_ID] [--redact]` | Generate a retained-run report. |

Every operational command requires `TARGET`. Common transport options are `--identity-file FILE`, `--ssh-port PORT`, and `--output-dir DIR`. Advanced `run` options include `--config FILE`, `--mode auto|graphical|headless`, `--install-missing`, `--repair-watchdogs`, `--dry-run`, `--yes`, and `--no-max-fan`. See [the complete CLI reference](docs/cli.md) for examples, option/command validity, and strict plan syntax.

## What every candidate must prove

- The expected `tryboot` boot is active and the requested clocks are observed under load.
- The required CPU, GPU, and/or I/O workload completes for its full duration with structured success evidence.
- Temperature stays below the configured ceiling, and no new throttle, undervoltage, power, kernel, GPU, USB, storage, or filesystem fault appears.
- The selected graphical or headless GPU path works; graphical display/audio and required service baselines remain healthy.
- With default cooling, any detected Pi PWM fan remains at PWM 255 with live tachometer evidence.
- The permanent boot config retains its protected SHA-256 hash.
- Configured candidate/normal boot cycles pass, owned `tryboot` evidence is cleared, and normal clocks and watchdog health are re-proved.

A workload or backend that fails to prove it ran is a `HARNESS_FAILURE`, not automatically a clock boundary. Unknown ownership, real hash drift, or uncertain normal recovery stops safely. Read [Safety](docs/safety.md), [Architecture](docs/architecture.md), and [Output](docs/output.md) for the complete contracts and failure classes.

## Recovery and resume

Rerunning `autopioverclock overclock TARGET` continues that target's latest eligible interrupted automatic run. `resume`, `recover`, `status`, and `report` also select the target's latest retained state unless `--run-id RUN_ID` is supplied. Use an explicit ID when a later prepare/reset audit owns the `*-latest` links.

```bash
autopioverclock resume pi@pi-host
autopioverclock resume pi@pi-host --run-id RUN_ID
autopioverclock resume pi@pi-host --restart-from cpu-qualification
autopioverclock resume pi@pi-host --restart-from gpu-qualification
autopioverclock resume pi@pi-host --restart-from final --final-hours 36
```

`--restart-from` accepts `current`, `cpu-qualification`, `gpu-qualification`, or `final`. Clocks always come from retained evidence; omitted durations keep their saved values. Prerequisite qualifications must exist, an active final sequence cannot be rewound, and a completed applied result can repeat only `final` with a duration longer than its retained validation.

Transient reads receive a multi-minute retry window, safe same-boot gates are retried, and a safely recovered failed gate can repeat up to five times. Extended SSH loss enters read-only polling instead of issuing repeated reboots. Recovery must prove boot identity, clear `tryboot`, exact owned-file cleanup, the protected hash, normal clocks, and watchdog health before work continues.

`recover` returns one retained run to its saved protected normal config and stops. `reset` removes permanent tuning and verifies firmware-stock clocks. Neither deletes prior run artifacts.

## Results

Artifacts are retained under `$HOME/overclock-results`. Each run records an atomic `.state`, `.log`, `.csv`, `.jsonl`, effective `.conf`, discovery output, summary, and candidate logs; `*-latest.*` links point to the latest retained operation. The finalized `.json` is created when the controller exits through normal cleanup, so it can be absent while a run is active or after an uncatchable kill.

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
