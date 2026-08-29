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
| `overclock TARGET` | Rediscover the stock baseline, prove tryboot recovery, run every candidate with maximum Pi 5 PWM fan cooling by default, sweep and refine candidates, select guarded clocks, adapt downward after a recovered domain-specific or combined-endurance final-stress boundary, validate for at least eight hours, retain/display the exact permanent diff, apply the validated result, reboot, and verify it. |
| `test TARGET` | Test one exact CPU/GPU pair for a requested number of minutes through the same tryboot, watchdog, maximum-cooling, health, boot-cycle, protected-hash, and normal-recovery gates. It retains evidence but never validates or applies the clocks. |
| `reset TARGET` | Preserve a verified boot-config backup, safely handle project-owned tryboot evidence, remove explicit permanent tuning, reboot, and verify stock clocks. All prior artifacts remain. |

The optional edge test is:

```bash
autopioverclock overclock TARGET --edge-cpu-24h
```

On a fresh run it validates the ordinary production floor first, then tests CPU exactly 25 MHz higher through a fresh validation whose endurance phase lasts 24 hours. If a normal `overclock TARGET` run has already completed and applied its current-schema eight-hour floor, running the flagged command later creates a separate linked edge run, re-proves the live floor, and starts directly at the edge validation. The eight-hour endurance phase is not repeated. The source run's automatically selected graphical or headless mode is retained exactly, so a target with no screen remains fully supported. A safely recovered edge boot/stability rejection keeps the validated floor; harness or recovery uncertainty remains fatal.

Maximum cooling is automatic and temporary. Each candidate/final tryboot overrides the Pi 5 fan levels to PWM 255 from the first thermal level, verifies any detected Linux `pwmfan` device before and during load, and records its PWM/RPM telemetry. The protected permanent config and all of its existing fan directives remain unchanged; normal recovery and permanent apply therefore restore the user's ordinary curve automatically. A target with passive cooling or an externally controlled fan is reported as `not-detected` rather than falsely claimed as software-controlled; temperature and throttle limits remain mandatory. `--no-max-fan` opts a new run out of the temporary override. A continuation always uses its saved cooling policy.

## Exact-clock stability test

```bash
autopioverclock test TARGET --cpu 3100 --gpu 1150 --minutes 90
```

All three values are required. CPU accepts 600–4000 MHz, GPU/V3D accepts 200–3000 MHz, and duration accepts 1–1440 minutes. Both requested clocks must be at least the protected normal clocks and at least one must be higher; underclock/undervolt testing is outside this command. The requested minutes are the combined timed stress duration, while recovery proof, a GPU harness smoke check, repeated candidate/normal boot cycles, post-stress health, and final normal recovery add wall time. Run `prepare TARGET` first if dependencies or watchdog recovery are not ready.

The command is intentionally not a shortcut to permanent configuration. It uses the existing voltage delta, sets `VALIDATED=0` and `APPLY_STATUS=NOT_APPLIED`, never creates a recommendation, and `apply` explicitly refuses its run ID. A timed pass means that exact workload and safety sequence passed for the requested duration; it does not claim eight-hour/24-hour production validation. Rerunning an identical command safely continues a current-schema interruption. Different clocks cannot silently replace an interrupted manual plan; recover or finish the retained run first. `--no-max-fan` is accepted only when that cooling condition is intentional and cannot be changed during continuation.

## Interactive progress

On a real terminal, tuning and manual tests display one in-place controller-side progress line with the target, visual whole-job bar, approximate total percentage/ETA, approximate tests remaining, current clocks, current and run-maximum temperature, throttle state, and activity. During a timed workload it also displays the worker-reported countdown for that current stress phase.

The total estimate is dynamic rather than a promise: a newly discovered failure boundary can add 25 MHz refinement/guard tests or remove higher candidates, so the bar, ETA, and `tests left` count re-plan. Reboot/SSH work uses bounded historical estimates and is not shown as an exact countdown. On `Ctrl-C`, `TERM`, or `HUP`, the controller clears and suppresses the display before its exit-trap normal recovery begins. Non-TTY/redirected execution prints ordinary raw telemetry, and candidate/main artifacts retain the raw worker lines in both modes.

`prepare` and `overclock` are explicit authorization for the operations named by those commands. `prepare` may modify dependency/watchdog files and reboot. `overclock` may apply only the final result after current-schema validation and displays and retains the exact diff before applying it. Neither command overwrites unknown tryboot evidence or bypasses protected-hash checks.

If its latest state is a current-schema `overclock` interrupted after preflight, rerunning the same `autopioverclock overclock TARGET` command safely recovers and continues that run with its recorded cooling policy. An interrupted workload is repeated at the same clocks because user interruption is not clock evidence. The same command also completes a validated application interrupted before or during reboot. A current-schema automatic run may continue after ordinary final CPU-only, GPU-only, or combined-endurance stress recorded `STABILITY_FAILURE`, completed verified normal recovery, and cleared every owned tryboot field. A domain-specific failure lowers only that clock; a combined-endurance failure lowers every still-overclocked domain by its production guard without attributing cause. Complete final validation restarts at the reduced target. The legacy schema-7 bridge remains limited to its exact CPU-only/GPU-only case. Other failed, old-schema, preflight-only, foreign, or ambiguous state is never silently adopted.

`reset` is noninteractive and rejects `--yes`, run selection, tuning-plan, dependency, watchdog, dry-run, edge, fan-policy, mode, and redaction flags. The older `TARGET reset` order remains a compatibility alias; `reset TARGET` is the normal form.

## Normal options

| Option | Default | Meaning |
|---|---:|---|
| `--edge-cpu-24h` | off | Add the final CPU +25 MHz/24-hour validation to `overclock`. |
| `--no-max-fan` | off | Use the target's ordinary fan policy instead of the temporary maximum-cooling tryboot override. Valid only for a new `overclock`, `test`, or advanced `run`. |
| `--cpu MHZ` | required for `test` | Exact CPU clock for a manual stability test. |
| `--gpu MHZ` | required for `test` | Exact GPU/V3D clock for a manual stability test. |
| `--minutes MINUTES` | required for `test` | Combined timed stress duration, 1–1440 minutes. |
| `--output-dir DIR` | `$HOME/overclock-results` | Use another flat artifact directory. |
| `--ssh-port PORT` | `22` | Use another SSH destination port. |
| `--identity-file FILE` | normal SSH keys | Use one explicit SSH private key. |
| `--help` | n/a | Show help. |
| `--version` | n/a | Show the version. |

`overclock` is intentionally configuration-free and automatically chooses graphical validation for a healthy attached display/session or headless validation when no display is present. It accepts no custom clock plan. Automatic tuning requires active firmware-stock clocks—CPU 2400 MHz, V3D 800 or 960 MHz, and zero voltage delta—and a stable permanent root config with no explicit clock/voltage controls or unbound `include`. The one exception to stock discovery is the bounded later edge continuation above, which requires an exact retained applied-floor identity and does not rediscover arbitrary tuned clocks as a baseline.

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

The `run TARGET` command and strict `--config FILE` plans remain for development and expert use. Advanced options include `--mode`, `--install-missing`, `--repair-watchdogs`, `--dry-run`, `--run-id`, `--redact`, and `--yes`; a new advanced run may also use `--no-max-fan`. `prepare TARGET --dry-run` retains read-only discovery and plan generation. These are not required by the normal three-command workflow. The explicit public `overclock` command starts without a second ordinary prompt; all safety, validation, and recovery gates remain mandatory.

Standalone advanced `apply` still requires a current-schema `PASS`/`COMPLETE` result with at least 28,800 seconds of retained endurance evidence, displays the exact diff, and requires typed confirmation. Manual `test` records are ineligible regardless of their requested duration. `status` and `report` remain local; `resume`, `recover`, and `apply` fail closed when saved context is incomplete or stale.

## Reset guarantees

Reset succeeds only after a changed boot ID, the exact expected permanent-config hash, clear tryboot state, active Pi 5 stock clocks (2400 MHz CPU, V3D 800 or 960 MHz, zero voltage delta), clean current throttle/power evidence, and the active watchdog recovery chain. Batocera must also return `/boot` to read-only state.

It fails without rewriting unknown content when it finds an active `include`, config symlink, malformed managed markers, hash race, or foreign/ambiguous tryboot path. Project-owned tryboot evidence is backed up before removal. Debian backups live below `/var/lib/autopioverclock/backups/`; Batocera backups live below `/userdata/system/autopioverclock/backups/`.
