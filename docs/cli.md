# Command-line interface

## Normal workflow

```bash
autopioverclock prepare TARGET
autopioverclock overclock TARGET
autopioverclock reset TARGET
```

Run every command on the separate Linux controller. The controller may be any supported Linux computer; it does not need to be a Raspberry Pi. Debian/Ubuntu with GNU tools is the tested controller path, and building the Batocera graphical payload requires an ARM64 Debian-family controller. `TARGET` always names a different Raspberry Pi target and may be a hostname, IP address, `username@host`, or `username@IP`. Self-hosted tuning is rejected by comparing the local and remote running-kernel boot IDs because a target crash or reboot would also terminate the controller and remove independent recovery observation. If the username is omitted, the controller uses its current `id -un` username. AutoPiOverclock never guesses, prompts for, or remembers a target, so separate terminal tabs cannot silently redirect one another.

The transport does not read `~/.ssh/config`. Use a real hostname or IP plus an explicit `username@` when needed; pass `--identity-file FILE` or `--ssh-port PORT` for a nondefault key or port.

| Controller command | Complete behavior |
|---|---|
| `prepare TARGET` | Detect the supported Pi 5 platform and mode, install missing stress dependencies, install or repair watchdog recovery when required, and reboot for activation when needed. An already tuned host needs `reset` only for a fresh full search; an eligible retained applied result can be extended directly with `--cpu-only` or `--gpu-only`. |
| `overclock TARGET [--cpu-only | --gpu-only] [--cpu-start-at MHZ] [--gpu-start-at MHZ]` | Rediscover the baseline, prove tryboot recovery, tune both domains by default, retain/display the exact permanent diff, apply the validated result, reboot, and verify it. Optional domain/start flags narrow where the automatic search runs without selecting a final clock. |
| `test TARGET` | Test one exact CPU/GPU pair for a requested number of minutes through the same tryboot, watchdog, maximum-cooling, health, boot-cycle, protected-hash, and normal-recovery gates. It retains evidence but never validates or applies the clocks. |
| `reset TARGET` | Preserve a verified boot-config backup, safely handle project-owned tryboot evidence, remove explicit permanent tuning, reboot, and verify stock clocks. All prior artifacts remain. |

The final sequence is automatic:

```bash
autopioverclock overclock TARGET
```

Full automatic tuning searches CPU in 100 MHz coarse steps and GPU in 50 MHz coarse steps, then refines a proved failure gap in 25 MHz steps. After the required domain qualifications, the selected pair runs one saved-duration combined CPU/GPU/I/O validation, defaulting to 24 hours. CPU-specific evidence lowers only CPU; GPU-specific evidence lowers only GPU. If a full-mode clock failure is genuinely ambiguous after complete recovery, the failed pair becomes an anchor. AutoPiOverclock tries CPU 25 MHz lower first. Only if that attempt also fails ambiguously does it restore CPU and try GPU 25 MHz lower; only another ambiguous failure advances to both domains 25 MHz lower and, if necessary, a new anchor. Exact CPU or GPU evidence from any isolation trial immediately switches to the corresponding exact-domain rule. Each changed domain is requalified before another final attempt. This avoids reducing a stable domain. One-domain mode can lower and requalify only its selected domain; exact evidence against the held domain stops. Every attempt starts a fresh full `--final-hours` run; even a late failure earns no time credit. Transient evidence receives the retry/recovery policy below; exhausted harness uncertainty or unproved recovery still stops.

`overclock TARGET --cpu-only` holds GPU/V3D at the clock from the target's latest eligible applied AutoPiOverclock result and sweeps and qualifies only CPU; `--gpu-only` does the converse. The flags are mutually exclusive and require that retained applied result, whose live clock and configuration are freshly re-proved before use. The held clock is a verified baseline, not a claim that its domain is already maximized or the selected-domain boundary. Each mode runs the resulting pair through the same combined final validation, apply, reboot, verification, maximum-cooling, retry, and recovery pipeline.

`--cpu-start-at MHZ` and `--gpu-start-at MHZ` accept 25 MHz increments above the protected current clock and begin the corresponding automatic ladder at a later candidate; they do not force a final clock or count skipped clocks as passes. CPU is capped at 3200 MHz and GPU at 1200 MHz. Full mode accepts either or both only from a stock target; an already applied target uses the matching one-domain mode. CPU-only rejects `--gpu-start-at`, and GPU-only rejects `--cpu-start-at`. If the first requested candidate fails, safe 25 MHz refinement may probe below that start to find the highest passing clock above the verified baseline. The domain ceiling is appended when an offset starting point does not land on it through the normal coarse step.

```bash
autopioverclock overclock TARGET --cpu-only --cpu-start-at 2900
autopioverclock overclock TARGET --gpu-only --gpu-start-at 1050
autopioverclock overclock TARGET --cpu-start-at 2900 --gpu-start-at 1050
```

Maximum cooling is automatic and temporary. Each candidate/final tryboot overrides the Pi 5 fan levels to PWM 255 from the first thermal level, verifies any detected Linux `pwmfan` device before and during load, and records its PWM/RPM telemetry. The protected permanent config and all of its existing fan directives remain unchanged; normal recovery and permanent apply therefore restore the user's ordinary curve automatically. A target with passive cooling or an externally controlled fan is reported as `not-detected` rather than falsely claimed as software-controlled; temperature and throttle limits remain mandatory. `--no-max-fan` opts a new run out of the temporary override. A continuation always uses its saved cooling policy.

## Exact-clock stability test

```bash
autopioverclock test TARGET --cpu 3100 --gpu 1150 --minutes 90
```

All three values are required. CPU accepts 600–4000 MHz, GPU/V3D accepts 200–3000 MHz, and duration accepts 1–1440 minutes. Both requested clocks must be at least the protected normal clocks and at least one must be higher; underclock/undervolt testing is outside this command. The requested minutes are the combined timed stress duration, while recovery proof, a GPU harness smoke check, repeated candidate/normal boot cycles, post-stress health, and final normal recovery add wall time. Run `prepare TARGET` first if dependencies or watchdog recovery are not ready.

The command is intentionally not a shortcut to permanent configuration. It uses the existing voltage delta, sets `VALIDATED=0` and `APPLY_STATUS=NOT_APPLIED`, never creates a recommendation, and `apply` explicitly refuses its run ID. A timed pass means that exact workload and safety sequence passed for the requested duration; it does not satisfy an automatic run's qualification or final-validation plan. Rerunning an identical command safely continues a current-schema interruption. Different clocks cannot silently replace an interrupted manual plan; recover or finish the retained run first. `--no-max-fan` is accepted only when that cooling condition is intentional and cannot be changed during continuation.

## Interactive progress

On a real terminal, tuning and manual tests display one in-place controller-side progress line with the target, visual whole-job bar, approximate total percentage/ETA, approximate tests remaining, current clocks, current and run-maximum temperature, throttle state, and activity. During a timed workload it also displays the worker-reported countdown for that current stress phase. The renderer is designed to erase and replace only the current logical row, park at column one, and emit no newline or vertical cursor movement. Inside tmux, it also sizes the line to the narrowest attached client. Arbitrary client-side reflow or a detached client resized between paints can still preserve an older row; this cosmetic behavior does not alter retained evidence.

The total estimate is dynamic rather than a promise: a newly discovered failure boundary can add 25 MHz refinement tests or remove higher candidates, so the bar, ETA, and `tests left` count re-plan. Reboot/SSH work uses bounded historical estimates and is not shown as an exact countdown. On `Ctrl-C`, `TERM`, or `HUP`, the controller clears and suppresses the display before its exit-trap normal recovery begins. Non-TTY/redirected execution prints ordinary raw telemetry, and candidate/main artifacts retain the raw worker lines in both modes.

`prepare` and `overclock` are explicit authorization for the operations named by those commands. `prepare` may modify dependency/watchdog files and reboot. `overclock` may apply only the final result after current-schema validation and displays and retains the exact diff before applying it. Neither command overwrites unknown tryboot evidence or bypasses protected-hash checks.

If its latest state is an eligible `overclock` interrupted after preflight, rerunning the same command—including the same domain mode and starting-point flags—safely recovers and continues that matching run with its recorded cooling and duration policies. An interrupted workload is repeated at the same clocks because user interruption is not clock evidence. The same command also completes a validated application interrupted before or during reboot. Scalar/file/hash evidence receives 30 validated attempts with 10-second spacing; safe same-boot worker gates receive up to five attempts; a complete gate can be repeated five times after verified stock recovery. Every mutating/recovery command that exceeds its ordinary 240/300-second SSH timeout enters read-only polling instead of exiting or issuing another reboot; when SSH returns, the saved boot ID, tryboot ownership, normal clocks, and health are reconciled before work continues. A fully recovered CPU or GPU boot/stability failure during qualification lowers only that domain 25 MHz and retries. An ambiguous full-mode final failure runs the anchored CPU-only, GPU-only, then paired 25 MHz isolation sequence only while its evidence remains ambiguous; exact evidence immediately selects the corresponding domain. One-domain mode can lower only the selected domain and stops on exact evidence against the held domain. Each changed domain is requalified and every final attempt restarts for the complete saved duration. Audio readiness loss by itself is a retryable `HARNESS_FAILURE`, never a CPU or GPU boundary. Exhausted harness uncertainty, a real protected-hash mismatch, foreign ownership, or unproved recovery still stops.

`resume TARGET` selects the latest retained state when `--run-id` is omitted. It also supports an explicit, bounded checkpoint restart for an active current-schema automatic overclock that has not begun final validation:

```bash
autopioverclock resume TARGET --restart-from cpu-qualification --qualification-hours 2 --final-hours 24
autopioverclock resume TARGET --restart-from gpu-qualification --qualification-hours 2 --final-hours 24
autopioverclock resume TARGET --restart-from final --final-hours 24
```

`--restart-from` accepts `current`, `cpu-qualification`, `gpu-qualification`, or `final` for full-mode runs. It cannot be combined with `--cpu-only` or `--gpu-only`; repeat the exact one-domain `overclock` command to continue one-domain state. Clocks come from retained evidence; the CLI supplies no replacement result clock, and each omitted duration keeps its saved value. Each later checkpoint requires its exact prerequisite qualifications. An active final sequence cannot be rewound or relabeled. Direct resume retains unattended extended-SSH monitoring and automatic final application. A completed applied run may use only `--restart-from final`, and only with a final duration longer than its retained validation; AutoPiOverclock creates a linked run, restores the verified pre-apply stock backup, validates the retained clocks fresh, and reapplies only a PASS. A fully recovered ambiguous full-mode final failure uses the saved pair as the anchor for CPU-only, GPU-only, then paired 25 MHz trials only while failures remain ambiguous; exact evidence immediately selects that domain. One-domain mode reduces and requalifies only its selected domain and stops if exact evidence identifies the held domain. Each trial performs its required requalification and a fresh complete final validation. Plain `resume TARGET` also adopts exact safely recovered unstructured worker-loss or clean-early-exit checkpoints. Safely recovered harness failures repeat their complete gate up to five times; exhausted harness or recovery uncertainty stops with stock active. Eligible older schemas are migrated conservatively; failed preflight, foreign, or ambiguous state is never silently adopted.

`reset TARGET` is the only stock-reset command order. It is noninteractive and rejects `--yes`, run selection, tuning-plan, dependency, watchdog, dry-run, duration, domain, fan-policy, mode, and redaction flags.

## Normal options

| Option | Default | Meaning |
|---|---:|---|
| `--qualification-hours HOURS` | `2` | Hours for each domain qualification required by the selected `overclock` mode; whole numbers 1–168. |
| `--final-hours HOURS` | `24` | Hours for the one combined CPU/GPU/I/O final validation; whole numbers 1–168. |
| `--restart-from POINT` | normal continuation | In full mode, deliberately repeat `current`, `cpu-qualification`, `gpu-qualification`, or `final` using retained clocks and the supplied duration plan; incompatible with one-domain flags. |
| `--cpu-only` | off | Extend an eligible applied result by sweeping and qualifying only CPU while holding its retained GPU/V3D clock; mutually exclusive with `--gpu-only`. |
| `--gpu-only` | off | Extend an eligible applied result by sweeping and qualifying only GPU while holding its retained CPU clock; mutually exclusive with `--cpu-only`. |
| `--cpu-start-at MHZ` | normal CPU ladder start | Begin the CPU sweep at a 25 MHz multiple above the protected clock, up to 3200; valid alone or with `--cpu-only`, but rejected by `--gpu-only`. |
| `--gpu-start-at MHZ` | normal GPU ladder start | Begin the GPU sweep at a 25 MHz multiple above the protected clock, up to 1200; valid alone or with `--gpu-only`, but rejected by `--cpu-only`. |
| `--no-max-fan` | off | Use the target's ordinary fan policy instead of the temporary maximum-cooling tryboot override. Valid only for a new `overclock`, `test`, or advanced `run`. |
| `--cpu MHZ` | required for `test` | Exact CPU clock for a manual stability test. |
| `--gpu MHZ` | required for `test` | Exact GPU/V3D clock for a manual stability test. |
| `--minutes MINUTES` | required for `test` | Combined timed stress duration, 1–1440 minutes. |
| `--output-dir DIR` | `$HOME/overclock-results` | Use another flat artifact directory. |
| `--ssh-port PORT` | `22` | Use another SSH destination port. |
| `--identity-file FILE` | normal SSH keys | Use one explicit SSH private key. |
| `--help` | n/a | Show help. |
| `--version` | n/a | Show the version. |

`overclock` is intentionally configuration-free and automatically chooses graphical validation for a healthy attached display/session or headless validation when no display is present. Headless Raspberry Pi OS/Debian requires neither a desktop nor audio hardware; `prepare` installs `stress-ng`, dynamically binds the V3D render node, and refuses ambiguous multi-render-node fallback. Starting-point flags trim an automatic ladder but may refine below the start after an immediate failure; they are not a custom result plan. The duration options are reported as `custom` unless they remain at 2 hours per qualification and 24 hours for final validation. Shortening a duration reduces confidence; it does not weaken tryboot ownership, recovery, health, temperature, throttle, workload, or apply checks. Full two-domain tuning requires active firmware-stock clocks—CPU 2400 MHz, V3D 800 or 960 MHz, and zero voltage delta—and a stable permanent root config with no explicit clock/voltage controls or unbound `include`. A one-domain mode instead requires the latest eligible applied result and freshly verifies that its active clocks and permanent configuration still match the retained evidence.

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

The `run TARGET` command and strict `--config FILE` plans remain for development and expert use. Advanced options include `--mode`, `--install-missing`, `--repair-watchdogs`, `--dry-run`, `--run-id`, `--redact`, and `--yes`; a new advanced run may also use `--no-max-fan`. `prepare TARGET --dry-run` retains read-only discovery and plan generation. These are not required by the normal two-command workflow; `reset TARGET` remains available when a user wants to return to stock. The explicit public `overclock` command starts without a second ordinary prompt; all safety, validation, and recovery gates remain mandatory.

Standalone advanced `apply` still requires a current-schema `PASS`/`COMPLETE` result whose retained endurance evidence exactly matches its immutable saved final duration, displays the exact diff, and requires typed confirmation. Manual `test` records are ineligible regardless of their requested duration. `status` and `report` remain local; `resume`, `recover`, and `apply` fail closed when saved context is incomplete or stale.

## Reset guarantees

Reset succeeds only after a changed boot ID, the exact expected permanent-config hash, clear tryboot state, active Pi 5 stock clocks (2400 MHz CPU, V3D 800 or 960 MHz, zero voltage delta), clean current throttle/power evidence, and the active watchdog recovery chain. Batocera must also return `/boot` to read-only state.

It fails without rewriting unknown content when it finds an active `include`, config symlink, malformed managed markers, hash race, or foreign/ambiguous tryboot path. Project-owned tryboot evidence is backed up before removal. Debian backups live below `/var/lib/autopioverclock/backups/`; Batocera backups live below `/userdata/system/autopioverclock/backups/`.
