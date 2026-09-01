# Command-line interface

## Normal workflow

```bash
autopioverclock prepare TARGET
autopioverclock overclock TARGET
autopioverclock reset TARGET
```

Run every command on the separate Linux controller. The controller may be any supported Linux computer; it does not need to be a Raspberry Pi. `TARGET` always names a different Raspberry Pi target and may be a hostname, IP address, `username@host`, or `username@IP`. Self-hosted tuning is unsupported because a target crash or reboot would also terminate the controller and remove independent recovery observation. If the username is omitted, the controller uses its current `id -un` username. AutoPiOverclock never guesses, prompts for, or remembers a target, so separate terminal tabs cannot silently redirect one another.

| Controller command | Complete behavior |
|---|---|
| `prepare TARGET` | Detect the supported Pi 5 platform and mode, install missing stress dependencies, install or repair watchdog recovery when required, and reboot for activation when needed. On an already tuned host it completes setup, then directs the one required reset. |
| `overclock TARGET` | Rediscover the stock baseline, prove tryboot recovery, search CPU first, qualify CPU at stock GPU, search and qualify GPU, try CPU +25 MHz under combined CPU/GPU/I/O load, fall back to a fresh guarded-floor validation only when needed, adapt downward after eligible recovered boot/stability failures, retain/display the exact permanent diff, apply the validated result, reboot, and verify it. Qualifications default to 2 hours; the edge and guarded-floor fallback each default to 24 hours, but only one successful long result is required. |
| `test TARGET` | Test one exact CPU/GPU pair for a requested number of minutes through the same tryboot, watchdog, maximum-cooling, health, boot-cycle, protected-hash, and normal-recovery gates. It retains evidence but never validates or applies the clocks. |
| `reset TARGET` | Preserve a verified boot-config backup, safely handle project-owned tryboot evidence, remove explicit permanent tuning, reboot, and verify stock clocks. All prior artifacts remain. |

The edge-first final sequence is automatic:

```bash
autopioverclock overclock TARGET
```

After both domain qualifications, a fresh run tests CPU exactly 25 MHz above the guarded target for the saved edge duration with combined CPU/GPU/I/O load and the qualified GPU. A full pass is the final result; the guarded floor is not also run. If that edge is at a known boundary or is safely rejected, the guarded pair begins one fresh saved final-duration validation. A guarded-pair failure triggers conservative pair backoff, repeats both qualifications, and starts a new final sequence. Harness or recovery uncertainty remains fatal. `--edge-hours HOURS` and `--final-hours HOURS` customize the two alternative paths; both default to 24. `--edge-cpu-24h` remains a compatibility spelling for `--edge-hours 24`.

Maximum cooling is automatic and temporary. Each candidate/final tryboot overrides the Pi 5 fan levels to PWM 255 from the first thermal level, verifies any detected Linux `pwmfan` device before and during load, and records its PWM/RPM telemetry. The protected permanent config and all of its existing fan directives remain unchanged; normal recovery and permanent apply therefore restore the user's ordinary curve automatically. A target with passive cooling or an externally controlled fan is reported as `not-detected` rather than falsely claimed as software-controlled; temperature and throttle limits remain mandatory. `--no-max-fan` opts a new run out of the temporary override. A continuation always uses its saved cooling policy.

## Exact-clock stability test

```bash
autopioverclock test TARGET --cpu 3100 --gpu 1150 --minutes 90
```

All three values are required. CPU accepts 600–4000 MHz, GPU/V3D accepts 200–3000 MHz, and duration accepts 1–1440 minutes. Both requested clocks must be at least the protected normal clocks and at least one must be higher; underclock/undervolt testing is outside this command. The requested minutes are the combined timed stress duration, while recovery proof, a GPU harness smoke check, repeated candidate/normal boot cycles, post-stress health, and final normal recovery add wall time. Run `prepare TARGET` first if dependencies or watchdog recovery are not ready.

The command is intentionally not a shortcut to permanent configuration. It uses the existing voltage delta, sets `VALIDATED=0` and `APPLY_STATUS=NOT_APPLIED`, never creates a recommendation, and `apply` explicitly refuses its run ID. A timed pass means that exact workload and safety sequence passed for the requested duration; it does not satisfy an automatic run's qualification, final-validation, or edge plan. Rerunning an identical command safely continues a current-schema interruption. Different clocks cannot silently replace an interrupted manual plan; recover or finish the retained run first. `--no-max-fan` is accepted only when that cooling condition is intentional and cannot be changed during continuation.

## Interactive progress

On a real terminal, tuning and manual tests display one in-place controller-side progress line with the target, visual whole-job bar, approximate total percentage/ETA, approximate tests remaining, current clocks, current and run-maximum temperature, throttle state, and activity. During a timed workload it also displays the worker-reported countdown for that current stress phase. One blank terminal row is reserved beneath the display as a stable cursor anchor; the bar repaints above it and does not consume a new historical line on each update.

The total estimate is dynamic rather than a promise: a newly discovered failure boundary can add 25 MHz refinement/guard tests or remove higher candidates, so the bar, ETA, and `tests left` count re-plan. Reboot/SSH work uses bounded historical estimates and is not shown as an exact countdown. On `Ctrl-C`, `TERM`, or `HUP`, the controller clears and suppresses the display before its exit-trap normal recovery begins. Non-TTY/redirected execution prints ordinary raw telemetry, and candidate/main artifacts retain the raw worker lines in both modes.

`prepare` and `overclock` are explicit authorization for the operations named by those commands. `prepare` may modify dependency/watchdog files and reboot. `overclock` may apply only the final result after current-schema validation and displays and retains the exact diff before applying it. Neither command overwrites unknown tryboot evidence or bypasses protected-hash checks.

If its latest state is an eligible `overclock` interrupted after preflight, rerunning the same `autopioverclock overclock TARGET` command safely recovers and continues that run with its recorded cooling and duration policies. An interrupted workload is repeated at the same clocks because user interruption is not clock evidence. The same command also completes a validated application interrupted before or during reboot. During an unattended public overclock, exceeding the ordinary SSH timeout enters read-only polling instead of exiting or issuing another reboot; when SSH returns, the saved boot ID, tryboot ownership, normal clocks, and health are reconciled before tuning continues. A fully recovered `BOOT_FAILURE` or `STABILITY_FAILURE` during CPU/GPU qualification lowers only that domain. An ambiguous guarded-pair failure lowers every still-overclocked domain, repeats both qualifications, and restarts a complete final sequence without attributing cause. Harness and recovery uncertainty still stop.

`resume TARGET` selects the latest retained state when `--run-id` is omitted. It also supports an explicit, bounded checkpoint restart for an active current-schema automatic overclock that has not begun final validation:

```bash
autopioverclock resume TARGET --restart-from cpu-qualification --qualification-hours 2 --final-hours 24 --edge-hours 24
autopioverclock resume TARGET --restart-from gpu-qualification --qualification-hours 2 --final-hours 24 --edge-hours 24
autopioverclock resume TARGET --restart-from final --final-hours 24 --edge-hours 24
```

`--restart-from` accepts `current`, `cpu-qualification`, `gpu-qualification`, or `final`. Clocks always come from the retained guarded state; the CLI supplies no host-specific clock override, and each omitted duration keeps its saved value. Each later checkpoint requires its exact prerequisite qualifications. An active final sequence cannot be rewound or relabeled. Direct resume of an overclock retains unattended extended-SSH monitoring and automatic final application. A completed applied run may use only `--restart-from final`, and only with a final duration longer than its retained validation; AutoPiOverclock creates a linked run, restores the verified pre-apply stock backup, validates the retained clocks fresh, and reapplies only a PASS. If a fully recovered boot/stability failure rejects that combined pair, stock stays active while automatic pair backoff repeats both qualifications and starts a fresh edge-first sequence whose edge and floor alternatives each use the requested longer-final duration. Plain `resume TARGET` adopts that exact retained failure and any exact safely recovered unstructured worker-loss checkpoint. Ambiguous same-boot transport/worker loss automatically repeats its complete gate up to two times; a proved autonomous reboot backs off, while exhausted harness uncertainty or any recovery uncertainty stops with stock active. Ordinary continuation without `--restart-from` retains its immutable saved duration plan. Eligible older schemas are migrated conservatively; failed preflight, foreign, or ambiguous state is never silently adopted.

`reset TARGET` is the only stock-reset command order. It is noninteractive and rejects `--yes`, run selection, tuning-plan, dependency, watchdog, dry-run, edge, fan-policy, mode, and redaction flags.

## Normal options

| Option | Default | Meaning |
|---|---:|---|
| `--qualification-hours HOURS` | `2` | Hours for each isolated CPU and GPU qualification in `overclock`; whole numbers 1–168. |
| `--final-hours HOURS` | `24` | Hours for the guarded-floor fallback after an edge skip/rejection; whole numbers 1–168. |
| `--edge-hours HOURS` | `24` | Hours for the default CPU +25 MHz combined CPU/GPU/I/O attempt; whole numbers 1–168. |
| `--edge-cpu-24h` | n/a | Compatibility spelling for `--edge-hours 24`; do not combine both forms. |
| `--restart-from POINT` | normal continuation | With `overclock` or `resume`, deliberately repeat `current`, `cpu-qualification`, `gpu-qualification`, or `final` using retained clocks and the supplied duration plan. |
| `--no-max-fan` | off | Use the target's ordinary fan policy instead of the temporary maximum-cooling tryboot override. Valid only for a new `overclock`, `test`, or advanced `run`. |
| `--cpu MHZ` | required for `test` | Exact CPU clock for a manual stability test. |
| `--gpu MHZ` | required for `test` | Exact GPU/V3D clock for a manual stability test. |
| `--minutes MINUTES` | required for `test` | Combined timed stress duration, 1–1440 minutes. |
| `--output-dir DIR` | `$HOME/overclock-results` | Use another flat artifact directory. |
| `--ssh-port PORT` | `22` | Use another SSH destination port. |
| `--identity-file FILE` | normal SSH keys | Use one explicit SSH private key. |
| `--help` | n/a | Show help. |
| `--version` | n/a | Show the version. |

`overclock` is intentionally configuration-free and automatically chooses graphical validation for a healthy attached display/session or headless validation when no display is present. Headless Raspberry Pi OS/Debian requires neither a desktop nor audio hardware; `prepare` installs `stress-ng`, dynamically binds the V3D render node, and refuses ambiguous multi-render-node fallback. It accepts no custom clock plan. The three hour options adjust only the long evidence durations and are reported as `custom` unless they remain at 2 hours per qualification and 24 hours for both alternative final paths. Shortening a duration reduces confidence; it does not weaken tryboot ownership, recovery, health, temperature, throttle, workload, or apply checks. Automatic tuning requires active firmware-stock clocks—CPU 2400 MHz, V3D 800 or 960 MHz, and zero voltage delta—and a stable permanent root config with no explicit clock/voltage controls or unbound `include`.

## Advanced support interface

The safety engine retains these commands so an interrupted or unusual run can be inspected and recovered without weakening ownership checks:

```bash
autopioverclock run TARGET [OPTIONS]
autopioverclock status TARGET [--run-id RUN_ID]
autopioverclock report TARGET [--run-id RUN_ID]
autopioverclock resume TARGET [--run-id RUN_ID]
autopioverclock recover TARGET [--run-id RUN_ID]
autopioverclock apply TARGET [--run-id RUN_ID]
autopioverclock reset TARGET
```

The `run TARGET` command and strict `--config FILE` plans remain for development and expert use. Advanced options include `--mode`, `--install-missing`, `--repair-watchdogs`, `--dry-run`, `--run-id`, `--redact`, and `--yes`; a new advanced run may also use `--no-max-fan`. `prepare TARGET --dry-run` retains read-only discovery and plan generation. These are not required by the normal three-command workflow. The explicit public `overclock` command starts without a second ordinary prompt; all safety, validation, and recovery gates remain mandatory.

Standalone advanced `apply` still requires a current-schema `PASS`/`COMPLETE` result whose retained endurance evidence exactly matches its immutable saved final or accepted-edge duration, displays the exact diff, and requires typed confirmation. Manual `test` records are ineligible regardless of their requested duration. `status` and `report` remain local; `resume`, `recover`, and `apply` fail closed when saved context is incomplete or stale.

## Reset guarantees

Reset succeeds only after a changed boot ID, the exact expected permanent-config hash, clear tryboot state, active Pi 5 stock clocks (2400 MHz CPU, V3D 800 or 960 MHz, zero voltage delta), clean current throttle/power evidence, and the active watchdog recovery chain. Batocera must also return `/boot` to read-only state.

It fails without rewriting unknown content when it finds an active `include`, config symlink, malformed managed markers, hash race, or foreign/ambiguous tryboot path. Project-owned tryboot evidence is backed up before removal. Debian backups live below `/var/lib/autopioverclock/backups/`; Batocera backups live below `/userdata/system/autopioverclock/backups/`.
