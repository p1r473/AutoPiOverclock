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

Then use the three everyday commands:

```bash
autopioverclock prepare pi@pi-host
autopioverclock overclock pi@pi-host
autopioverclock reset pi@pi-host
```

- `prepare` installs and verifies target prerequisites and recovery safeguards, and may update watchdog files and reboot the target.
- `overclock` searches, validates, applies, reboots, and verifies. Repeating it continues the latest eligible interrupted run.
- `reset` backs up the boot config, disables explicit permanent clock/voltage overrides, reboots, and verifies stock clocks.

Every operational command requires a target. AutoPiOverclock intentionally ignores `~/.ssh/config`; use `--identity-file FILE` or `--ssh-port PORT` when needed.

> [!IMPORTANT]
> Batocera may require `prepare` to install a bounded network-loss watchdog. Review [the Batocera preparation notes](docs/batocera.md#watchdog-preparation) before approving that change.

## Overclock strategy

By default, AutoPiOverclock:

1. verifies stock clocks, cooling, watchdog recovery, boot configuration, and `tryboot` cleanup;
2. searches CPU first at the stock GPU clock and refines the first proven boundary;
3. backs off conservatively and qualifies CPU for two hours;
4. searches GPU at the qualified CPU clock, backs off, and qualifies the pair for two hours;
5. tests one final CPU edge 25 MHz higher for 24 hours by default under combined CPU, GPU, and I/O load; and
6. accepts a passing edge as final, or—if that edge is known unsafe or safely rejected—runs one fresh 24-hour guarded-pair validation instead.

Bad candidates return to the protected normal configuration. Recoverable instability causes automatic backoff; transient harness failures repeat the complete affected test up to five times. Unknown ownership, changed boot configuration, or unproved recovery stops safely instead of guessing.

To change the test lengths:

```bash
autopioverclock overclock pi@pi-host --qualification-hours 3 --final-hours 36 --edge-hours 18
```

Shorter tests reduce confidence and are recorded as a custom policy. See [the CLI reference](docs/cli.md) for every option and exact resume behavior.

## Cooling and headless use

Maximum Pi PWM fan cooling is enabled temporarily during overclock tests. Existing fan settings remain in the protected boot config and return after testing. Use `--no-max-fan` only when passive/external cooling or the normal fan policy is intentionally part of the test; reduced cooling can reduce performance or stability.

Headless Debian-family targets work without a display or audio device. Graphical targets preserve and verify the detected display and audio baseline.

## Commands

| Command | Purpose |
| --- | --- |
| `prepare TARGET` | Install and verify prerequisites and recovery safeguards. |
| `overclock TARGET` | Automatically tune, validate, apply, reboot, and verify. |
| `reset TARGET` | Remove permanent tuning and verify stock clocks. |
| `test TARGET` | Test one exact CPU/GPU pair without applying it. |
| `run TARGET` | Run an advanced explicit tuning plan. |
| `resume TARGET` | Recover if needed and continue a saved run. |
| `status TARGET` | Show selected or latest local run state. |
| `recover TARGET` | Return a saved run to its protected normal config and stop. |
| `apply TARGET` | Apply an eligible completed, unapplied run. |
| `report TARGET` | Generate a selected or latest run report. |

`resume`, `recover`, `status`, and `report` select the target's latest retained state unless `--run-id` is supplied. `recover` returns to the saved normal config; `reset` removes permanent tuning and returns to firmware stock clocks. Reset preserves previous run artifacts.

To test clocks you already have in mind:

```bash
autopioverclock test pi@pi-host --cpu 3100 --gpu 1150 --minutes 90
```

This retains evidence and uses the normal recovery safeguards, but it never applies the clocks or counts as automatic validation.

## Safety model

- Candidate clocks exist only in owned, hash-bound `tryboot.txt` data.
- The permanent boot config stays protected throughout testing.
- Candidate files are removed only after attributable evidence and verified normal recovery.
- Watchdog, temperature, throttle, power, storage, GPU, and service evidence are checked throughout the run.
- The controller waits through reboots, retries transient reads, and preserves resumable state.
- Existing artifacts are retained; controller and target mutations are locked per target.

Read [Safety](docs/safety.md), [Architecture](docs/architecture.md), and [Output](docs/output.md) for the full contracts and failure classifications.

## Supported targets

AutoPiOverclock currently has alpha support for 64-bit Raspberry Pi 5 installations running Raspberry Pi OS, Debian, Ubuntu Raspberry Pi boot layouts, or Batocera. Graphical and headless paths are supported. Support means an implemented, fixture-tested path; it does not guarantee that every OS image, cooler, power supply, or Pi will behave identically.

## Verified result

One Debian 13 Raspberry Pi 5 completed and applied a retained default-policy run at **CPU 3100 MHz, V3D 1175 MHz, voltage delta 0**:

- CPU 3100 MHz qualified for two hours at stock GPU 960 MHz;
- GPU 1175 MHz qualified for two hours at CPU 3100 MHz, then 3100/1175 passed a fresh 24-hour combined validation;
- three additional candidate/normal boot cycles passed;
- maximum recorded temperature was 59.3 C with `throttled=0x0`; and
- the permanent apply and verification reboot passed.

That is evidence for one board and cooling setup, not a clock recommendation. Batocera end-to-end validation is still pending, so AutoPiOverclock remains alpha software.

## Applied configuration

A successful apply adds one small managed block and leaves unrelated boot settings intact:

```ini
# BEGIN AUTOPIOVERCLOCK MANAGED CLOCKS
# Run: RUN_ID
[all]
over_voltage_delta=0
arm_freq=3100
v3d_freq=1175
# END AUTOPIOVERCLOCK MANAGED CLOCKS
```

Those clocks are only an example. Firmware already defaults the voltage delta to zero, so `over_voltage_delta=0` is not electrically required. AutoPiOverclock writes it to record the exact tested condition and preserve managed configuration evidence. Leave the managed markers intact and use `autopioverclock reset TARGET` to remove the block safely.

## Results

Run artifacts are stored under `$HOME/overclock-results`. Before sharing, generate `autopioverclock report TARGET --redact` and still review the file for private hostnames, addresses, or other context.

AutoPiOverclock is licensed under the [Apache License 2.0](LICENSE). See [Contributing](CONTRIBUTING.md) and [Security](SECURITY.md).
