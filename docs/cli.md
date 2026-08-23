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
| `--mode auto\|graphical\|headless` | `auto` | `auto` stores the detected semantics once for resume. |
| `--output-dir DIR` | `$HOME/overclock-results` | One flat artifact directory. |
| `--ssh-port PORT` | `22` | SSH destination port. |
| `--identity-file FILE` | normal SSH keys | Explicit identity. |
| `--run-id ID` | target's latest run | Select state for resume/status/recover/apply/report. |
| `--install-missing` | off | Permit `apt` installation or Batocera payload staging. |
| `--repair-watchdogs` | off | Enter a separately confirmed remediation path. |
| `--dry-run` | off | Read-only discovery and plan rendering. |
| `--yes` | off | Accept ordinary prompts only. |
| `--redact` | off | Redact reports. |
| `--help` | n/a | Show command help. |
| `--version` | n/a | Show the version. |

`final_duration_seconds` in the approved configuration format must be between 28,800 and 604,800 seconds. `candidate_boots` must be between 2 and 10, and `final_boots` must be between 3 and 10. `apply` independently checks the saved final duration; editing only the completion flags in a state file does not satisfy the duration and validation-schema gates.

`status` and `report` remain local and usable for a run interrupted before discovery produced a complete profile. `resume`, `recover`, and `apply` refuse that incomplete context instead of guessing at a target layout or permanent hash.
