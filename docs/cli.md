# Command-line interface

## Forms

```bash
./autopioverclock TARGET [OPTIONS]
./autopioverclock COMMAND TARGET [OPTIONS]
```

Omitting `COMMAND` selects `run`. `TARGET` can be a hostname, an IP address, or an explicit `username@host`. When `username@` is omitted, the controller's current username from `id -un` is used.

## Commands

| Command | Behavior |
|---|---|
| `run` | Preflight, recovery proof, candidate sweeps, conservative selection, and final validation. Never writes permanent clocks. |
| `prepare` | Read-only remote discovery. It streams the worker over SSH and does not upload a file or reboot. |
| `resume` | Loads current-schema atomic state, recovers an interrupted tryboot first, and continues from the saved safe substage. Interrupted `PREPARE` state is inspectable but not mutably resumable. |
| `status` | Reads local state only. |
| `recover` | Returns to permanent normal configuration and runs normal health. |
| `apply` | Requires a current-schema `PASS`/`COMPLETE` validation with at least 28,800 saved endurance seconds, displays an exact diff, and requires typed confirmation. |
| `report` | Writes a concise local report. `--redact` removes target/user/path values. |

## Options

| Option | Default | Meaning |
|---|---:|---|
| `--config FILE` | none | Strict tuning plan. |
| `--mode auto\|graphical\|headless` | `auto` | `auto` detects graphical/headless semantics and, without `--config`, derives bounded candidates after discovery without reading candidate parameters from stdin. Explicit configurations remain authoritative. |
| `--output-dir DIR` | `$HOME/overclock-results` | One flat artifact directory. |
| `--ssh-port PORT` | `22` | SSH destination port. |
| `--identity-file FILE` | normal SSH keys | Explicit identity. |
| `--run-id ID` | target's latest run | Select state for resume/status/recover/apply/report. |
| `--install-missing` | off | Permit `apt` installation or Batocera payload staging. |
| `--repair-watchdogs` | off | Enter a separately confirmed remediation path. |
| `--dry-run` | off | Read-only discovery and plan rendering. |
| `--edge-cpu-24h` | off | Configuration-free auto only: validate the ordinary 50 MHz-buffered CPU floor for eight hours, then try CPU 25 MHz higher through a fresh 24-hour validation. |
| `--yes` | off | Accept ordinary prompts only. |
| `--redact` | off | Redact reports. |
| `--help` | n/a | Show command help. |
| `--version` | n/a | Show the version. |

`final_duration_seconds` in the approved configuration format must be between 28,800 and 604,800 seconds. `candidate_boots` must be between 2 and 10, and `final_boots` must be between 3 and 10. `apply` independently checks completed endurance-duration evidence, not only the configured request; editing completion flags does not satisfy the duration and validation-schema gates.

Configuration-free automatic tuning requires active stock clocks—CPU 2400 MHz, firmware-default V3D 800 or 960 MHz, and zero voltage delta—plus a stable permanent-root-config snapshot with no explicit clock/voltage control or `include` directive. Clock/voltage controls include `arm_boost`, turbo/fixed-clock controls, every `*_freq`/`*_freq_min` family, and every `over_voltage*` family. It climbs in 100 MHz CPU and 50 MHz V3D steps, refines a discovered failure gap at 25 MHz, then candidate-tests a production target 50 MHz below the CPU boundary and 25 MHz below the GPU boundary. The ordinary live-run confirmation remains required unless `--yes` is supplied. `--edge-cpu-24h` cannot be combined with `--config` or a non-auto mode.

`status` and `report` remain local and usable for a run interrupted before discovery produced a complete profile. `resume`, `recover`, and `apply` refuse that incomplete context instead of guessing at a target layout or permanent hash.
