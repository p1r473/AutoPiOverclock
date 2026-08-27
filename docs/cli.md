# Command-line interface

## Normal workflow

```bash
autopioverclock prepare TARGET
autopioverclock overclock TARGET
autopioverclock reset TARGET
```

Run every command on the controller/master Pi. `TARGET` always names a different target/slave Pi and may be a hostname, IP address, `username@host`, or `username@IP`. Self-hosted tuning is unsupported because a target crash or reboot would also terminate the controller and remove independent recovery observation. If the username is omitted, the controller uses its current `id -un` username. AutoPiOverclock never guesses, prompts for, or remembers a target, so separate terminal tabs cannot silently redirect one another.

| Controller command | Complete behavior |
|---|---|
| `prepare TARGET` | Detect the supported Pi 5 platform and mode, install missing stress dependencies, install or repair watchdog recovery when required, and reboot for activation when needed. On an already tuned host it completes setup, then directs the one required reset. |
| `overclock TARGET` | Rediscover the stock baseline, prove tryboot recovery, sweep and refine candidates, select guarded clocks, validate for at least eight hours, retain/display the exact permanent diff, apply the validated result, reboot, and verify it. |
| `reset TARGET` | Preserve a verified boot-config backup, safely handle project-owned tryboot evidence, remove explicit permanent tuning, reboot, and verify stock clocks. All prior artifacts remain. |

The optional edge test is:

```bash
autopioverclock overclock TARGET --edge-cpu-24h
```

It validates the ordinary production floor first, then tests CPU exactly 25 MHz higher through a fresh validation whose endurance phase lasts 24 hours. A safely recovered edge boot/stability rejection keeps the validated floor; harness or recovery uncertainty remains fatal.

`prepare` and `overclock` are explicit authorization for the operations named by those commands. `prepare` may modify dependency/watchdog files and reboot. `overclock` may apply only the final result after current-schema validation and displays and retains the exact diff before applying it. Neither command overwrites unknown tryboot evidence or bypasses protected-hash checks.

If its latest state is a current-schema `overclock` interrupted after preflight, rerunning the same `autopioverclock overclock TARGET` command safely recovers and continues that run. It also completes a validated application interrupted before or during reboot. Failed, old-schema, preflight-only, foreign, or ambiguous state is never silently adopted.

`reset` is noninteractive and rejects `--yes`, run selection, tuning-plan, dependency, watchdog, dry-run, edge, mode, and redaction flags. The older `TARGET reset` order remains a compatibility alias; `reset TARGET` is the normal form.

## Normal options

| Option | Default | Meaning |
|---|---:|---|
| `--edge-cpu-24h` | off | Add the final CPU +25 MHz/24-hour validation to `overclock`. |
| `--output-dir DIR` | `$HOME/overclock-results` | Use another flat artifact directory. |
| `--ssh-port PORT` | `22` | Use another SSH destination port. |
| `--identity-file FILE` | normal SSH keys | Use one explicit SSH private key. |
| `--help` | n/a | Show help. |
| `--version` | n/a | Show the version. |

`overclock` is intentionally configuration-free and automatically chooses graphical or headless validation. It accepts no custom clock plan. Automatic tuning requires active firmware-stock clocks—CPU 2400 MHz, V3D 800 or 960 MHz, and zero voltage delta—and a stable permanent root config with no explicit clock/voltage controls or unbound `include`.

## Advanced support interface

The safety engine retains these commands so an interrupted or unusual run can be inspected and recovered without weakening ownership checks:

```bash
autopioverclock run TARGET [OPTIONS]
autopioverclock status TARGET --run-id RUN_ID
autopioverclock report TARGET --run-id RUN_ID
autopioverclock resume TARGET --run-id RUN_ID
autopioverclock recover TARGET --run-id RUN_ID
autopioverclock apply TARGET --run-id RUN_ID
autopioverclock TARGET reset
```

The `run TARGET` command and strict `--config FILE` plans remain for development and expert use. Advanced options include `--mode`, `--install-missing`, `--repair-watchdogs`, `--dry-run`, `--run-id`, `--redact`, and `--yes`. `prepare TARGET --dry-run` retains read-only discovery and plan generation. These are not required by the normal three-command workflow. The explicit public `overclock` command starts without a second ordinary prompt; all safety, validation, and recovery gates remain mandatory.

Standalone advanced `apply` still requires a current-schema `PASS`/`COMPLETE` result with at least 28,800 seconds of retained endurance evidence, displays the exact diff, and requires typed confirmation. `status` and `report` remain local; `resume`, `recover`, and `apply` fail closed when saved context is incomplete or stale.

## Reset guarantees

Reset succeeds only after a changed boot ID, the exact expected permanent-config hash, clear tryboot state, active Pi 5 stock clocks (2400 MHz CPU, V3D 800 or 960 MHz, zero voltage delta), clean current throttle/power evidence, and the active watchdog recovery chain. Batocera must also return `/boot` to read-only state.

It fails without rewriting unknown content when it finds an active `include`, config symlink, malformed managed markers, hash race, or foreign/ambiguous tryboot path. Project-owned tryboot evidence is backed up before removal. Debian backups live below `/var/lib/autopioverclock/backups/`; Batocera backups live below `/userdata/system/autopioverclock/backups/`.
