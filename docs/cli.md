# Command-line interface

## Normal workflow

```bash
autopioverclock prepare TARGET
autopioverclock overclock TARGET
autopioverclock reset TARGET
```

Run every command on the separate Linux controller. The controller may be any supported Linux computer; it does not need to be a Raspberry Pi. Debian/Ubuntu with GNU tools is the tested controller path, and building the Batocera graphical payload requires an ARM64 Debian-family controller. `TARGET` always names a different Raspberry Pi target and may be a hostname, IP address, `username@host`, or `username@IP`. Self-hosted tuning is rejected by comparing the local and remote running-kernel boot IDs because a target crash or reboot would also terminate the controller and remove independent recovery observation. If the username is omitted, the controller uses its current `id -un` username. AutoPiOverclock never guesses, prompts for, or remembers a target, so separate terminal tabs cannot silently redirect one another.

The transport does not read `~/.ssh/config`. Use a real hostname or IP plus an explicit `username@` when needed; pass `--identity-file FILE` or `--ssh-port PORT` for a nondefault key or port.

| Controller command | Complete behavior | When to use it |
|---|---|---|
| `prepare TARGET` | Detect the supported Pi 5 platform and mode, install missing stress dependencies, install or repair watchdog recovery and strict network-reboot evidence components when required, and reboot for activation when needed. | Before a first run, after target software changes, or with `--dry-run` for a read-only readiness check. |
| `overclock TARGET [OPTIONS]` | Create a new history-guided plan, prove the baseline, tune, validate, retain/display the exact permanent diff, apply, reboot, and verify. It never silently resumes a saved run. | Whenever you want a new tuning decision, new bounds, or a new duration policy. |
| `test TARGET` | Test one exact CPU/GPU pair through the tryboot, watchdog, cooling, health, boot-cycle, hash, and recovery gates. It never tunes or applies. | When you know the exact pair and want pass/fail evidence only. |
| `reset TARGET` | Preserve a verified boot-config backup, safely handle project-owned tryboot evidence, remove explicit permanent tuning, reboot, and verify stock clocks. All prior artifacts remain. | When you want to return to stock; not as routine cleanup. |
| `run TARGET [OPTIONS]` | Execute the advanced engine with optional strict-plan controls. | For development, support, or a custom `--config` plan. |
| `resume TARGET [OPTIONS]` | Select a saved run, recover if required, and continue its immutable plan. | When a controller stopped or you deliberately want to repeat a saved checkpoint. |
| `status TARGET` | Read live clocks, health, tryboot/controller state, and the selected saved operation. | For a quick read-only snapshot. |
| `summary TARGET` | Explain sweep boundaries, choices, retries, validation, and the next action. | For a human-readable account of the tuning run. |
| `recover TARGET` | Return a selected run from temporary tryboot state to its protected permanent config and verify health. | When a run stopped mid-candidate and safe normalization is needed. |
| `restore TARGET` | Restore the newest retained fully validated applied config after an out-of-band edit. | When the permanent boot config was manually changed after a successful apply. |
| `apply TARGET` | Apply a selected fully validated advanced result after an exact diff and typed confirmation. | For an advanced `run`; public `overclock` applies its own result. |
| `report TARGET` | Generate a concise selected-run report. | For review or sharing, normally with `--redact`. |

The final sequence is automatic:

```bash
autopioverclock overclock TARGET
```

Every `overclock TARGET` invocation is a new run. Before building its plan, AutoPiOverclock ignores and preserves older or missing schemas, then strictly validates every compatible current-schema evidence-bearing automatic-run state for the exact target, profile, hardware identity, GPU key, stock baseline, and voltage policy. Unrelated audits and runs with no committed failure evidence are ignored. A read-only semantic adapter recognizes schema-10 states where legacy `START_AT` fields were search seeds, not hard floors; it does not rewrite those artifacts or relax malformed-evidence checks. Retained clear-domain failures supply advisory domain ceilings. When neither manual maximum is supplied for a full run, the newest nondominated ambiguous failed pair becomes the automatic reverse-search anchor and the controller derives its first CPU-lowered isolation pair. Explicit `--cpu-max` and `--gpu-max` values remain authoritative manual overrides. The failure ledger is created when missing and atomically replaced only if its derived content changed.

Search direction is selected independently for each domain. With no useful retained limit and no explicit maximum, CPU uses a forward coarse sweep and GPU does the same. A clear retained ceiling, an automatically selected ambiguous-pair anchor, or an explicit maximum reverses the affected domain: the exact ceiling is tested in isolation, coarse candidates descend until one passes, and the bracket between that pass and the nearest failure is refined toward the ceiling. CPU's coarse step is `max(100, CPU resolution)` MHz and GPU's is `max(50, GPU resolution)` MHz. `--cpu-resolution` and `--gpu-resolution` control those refinements independently; each defaults to 25 MHz and accepts whole-MHz values from 1 through 1000. This means the defaults retain 100/50 MHz coarse movement, while a larger requested resolution intentionally makes the coarse search faster and more conservative. In a full run these remain isolated, complete domain searches: CPU is searched and qualified first while GPU stays at the protected baseline, then GPU is searched and qualified while CPU stays at its qualified clock. The retained failed pair itself is never sent directly to final validation; its saved CPU-only, GPU-only, then paired isolation plan chooses the first safe combined pair.

After the required domain qualifications, the selected pair runs one saved-duration combined CPU/GPU/I/O validation, defaulting to 48 hours. CPU-specific evidence lowers only CPU by the CPU resolution; GPU-specific evidence lowers only GPU by the GPU resolution. If a full-mode clock failure is genuinely ambiguous after complete recovery, the failed pair becomes an anchor. AutoPiOverclock tries a CPU-only reduction first, then restores CPU and tries a GPU-only reduction, then tries both reductions while evidence remains ambiguous. Exact evidence immediately follows its identified domain. Each changed domain is requalified before another full final attempt, and each adjusted pair restarts the complete requested `--final-hours` duration from zero. A hard minimum is never crossed; when the next required search, qualification, or isolation point would be below it, the run fails and reports the limiting domain and floor.

`overclock TARGET --cpu-only` holds GPU/V3D at the clock from the target's latest eligible applied AutoPiOverclock result and sweeps and qualifies only CPU; `--gpu-only` does the converse. The flags are mutually exclusive and require that retained applied result, whose live clock and configuration are freshly re-proved before use. The held clock is a verified baseline, not a claim that its domain is already maximized or the selected-domain boundary. Each mode runs the resulting pair through the same combined final validation, apply, reboot, verification, maximum-cooling, retry, and recovery pipeline.

`--cpu-min MHZ` and `--gpu-min MHZ` are hard lower limits above the protected current clock. They do not merely choose a starting candidate: no automatic search, qualification backoff, or final isolation may cross them. `--cpu-max MHZ` and `--gpu-max MHZ` are optional manual overrides. They set inclusive ceilings, make their domains use reverse search, and are tested exactly in isolation even when they fall between normal coarse positions. Explicit maxima override lower retained-history advice after a warning; they do not force a final result or count skipped clocks as passes. `--cpu-resolution MHZ` and `--gpu-resolution MHZ` set positive whole-MHz refinement/backoff increments and default independently to 25. Before the first new candidate, the baseline safety proof intentionally boots and recovers the current pair. Full mode accepts both domains' controls from stock; an applied target uses the matching one-domain mode. CPU-only rejects GPU bounds/resolution and GPU-only rejects CPU bounds/resolution. Built-in maxima are CPU 3200 MHz and GPU 1200 MHz.

```bash
autopioverclock overclock pi@hostname --cpu-only --cpu-min 2900 --cpu-max 3100
autopioverclock overclock pi@hostname --gpu-only --gpu-min 1050 --gpu-max 1175
autopioverclock overclock pi@hostname --final-hours 100
autopioverclock overclock pi@hostname --cpu-max 3075 --gpu-max 1200
autopioverclock overclock pi@hostname --cpu-min 2900 --cpu-max 3075 --cpu-resolution 5 --gpu-min 1100 --gpu-max 1200 --gpu-resolution 5
autopioverclock overclock pi@hostname --no-history
```

Maximum cooling is automatic and temporary. Each candidate/final tryboot overrides the Pi 5 fan levels to PWM 255 from the first thermal level, verifies any detected Linux `pwmfan` device before and during load, and records its PWM/RPM telemetry. The protected permanent config and all of its existing fan directives remain unchanged; normal recovery and permanent apply therefore restore the user's ordinary curve automatically. A target with passive cooling or an externally controlled fan is reported as `not-detected` rather than falsely claimed as software-controlled; temperature and throttle limits remain mandatory. `--no-max-fan` opts a new run out of the temporary override. A continuation always uses its saved cooling policy.

## Exact-clock stability test

```bash
autopioverclock test pi@hostname --cpu 3100 --gpu 1150 --final-hours 48
```

Both clocks and exactly one duration form are required. CPU accepts 600-4000 MHz, GPU/V3D accepts 200-3000 MHz, preferred `--final-hours` accepts 1-596523 whole hours, and legacy `--minutes` accepts 1-35791380 minutes. The two duration options cannot be combined. Both requested clocks must be at least the protected normal clocks and at least one must be higher; underclock/undervolt testing is outside this command. The requested duration is the combined timed stress duration, while recovery proof, a GPU harness smoke check, repeated candidate/normal boot cycles, post-stress health, and final normal recovery add wall time. The timed workload runs as a detached fixed-deadline job on the target and retains its result across controller SSH loss. Run `prepare TARGET` first if dependencies or watchdog recovery are not ready.

The command is intentionally not a shortcut to permanent configuration. It uses the existing voltage delta, sets `VALIDATED=0` and `APPLY_STATUS=NOT_APPLIED`, never creates a recommendation, and `apply` explicitly refuses its run ID. A timed pass means that exact workload and safety sequence passed for the requested duration; it does not satisfy an automatic run's qualification or final-validation plan. Rerunning the same clocks, canonical duration, and cooling policy safely continues a current-schema interruption, so equivalent forms such as `--final-hours 1` and `--minutes 60` identify the same saved duration. Different clocks or duration cannot silently replace an interrupted manual plan; recover or finish the retained run first. `--no-max-fan` is accepted only when that cooling condition is intentional and cannot be changed during continuation.

## Interactive progress

On a real terminal, tuning and manual tests display one in-place controller-side progress line with the target, visual whole-job bar, approximate total percentage/ETA, approximate tests remaining, current clocks, current and run-maximum temperature, throttle state, and activity. During a timed workload its countdown changes every second. Target heartbeats supply fresh time and telemetry while connected; the saved target start time keeps the countdown moving during an SSH interruption. The renderer is designed to erase and replace only the current logical row, park at column one, and emit no newline or vertical cursor movement. Inside tmux, it also sizes the line to the narrowest attached client. Arbitrary client-side reflow or a detached client resized between paints can still preserve an older row; this cosmetic behavior does not alter retained evidence.

The total estimate is dynamic rather than a promise: a newly discovered failure boundary can add per-domain refinement tests or shorten a coarse sweep, so the bar, ETA, and `tests left` count re-plan. Reboot/SSH work uses bounded historical estimates and is not shown as an exact countdown. `Ctrl-C` clears and suppresses the display before deliberate normal recovery begins. A controller `TERM`, `HUP`, crash, or reboot instead leaves exact detached-job ownership saved so `resume TARGET` can reattach without stopping the target workload. Non-TTY/redirected execution prints ordinary raw telemetry, and candidate/main artifacts retain the raw worker lines in both modes.

`prepare` and `overclock` are explicit authorization for the operations named by those commands. `prepare` may modify dependency/watchdog files and reboot. `overclock` may apply only the final result after current-schema validation and displays and retains the exact diff before applying it. Neither command overwrites unknown tryboot evidence or bypasses protected-hash checks.

Only `resume TARGET` continues an interrupted saved tuning plan. It uses the latest retained operation unless `--run-id` selects another one, keeps that run's clocks, hard floors, ceilings, per-domain resolutions, search direction, history decision, cooling policy, and timing, and does not rescan history or touch the failure ledger. During timed stress, the target owns a unique job with a fixed deadline, so ordinary SSH loss or a controller crash does not stop the workload. The live controller reconnects indefinitely without launching a duplicate. If the controller itself reboots, run `resume TARGET`; it validates the saved job ID, token, specification hash, source boot ID, duration, helper identity, and worker path before reattaching. A fresh `overclock TARGET`, even with identical options, creates a new history-guided run instead of adopting the old checkpoint.

If the target reboots during stress, AutoPiOverclock never assumes the clocks caused it and never assumes the network caused it. A network-watchdog attribution requires one fresh project-owned event bound to the exact source and current boot IDs, configured liveness target, event identity and time, installed asset hashes, exact active service, and matching prepared, committed, and next-boot-accepted durable records. Debian's companion records this evidence without owning `/dev/watchdog`; systemd remains the hardware owner. Batocera's keeper also proves its committed hardware-watchdog starvation path. Complete proof repeats the entire gate at the same clocks without consuming the ordinary five-retry harness budget. Missing or conflicting proof permits one conservative full same-clock replay. A second unattributed reboot of that identical gate can enter normal stability and CPU/GPU isolation only after protected normal recovery is fully proved.

Scalar/file/hash evidence still receives 30 attempts with 10-second spacing, safe same-boot worker gates receive up to five attempts, and other safely recovered complete-gate harness failures retain their five retries. A primary normal-return handshake timeout is provisional. Incomplete recovery proof remains `RECOVERY_FAILURE`; a timeout alone never reduces clocks or starts domain isolation. Every mutating/recovery command that exceeds its ordinary 300-second SSH timeout enters read-only polling instead of treating expiration as result evidence. A missing or changed automatically inferred audio sink warns and continues; failure of an explicit `audio_sink_pattern` is a retryable `HARNESS_FAILURE`, never a CPU or GPU boundary. Protected-hash mismatch, foreign ownership, a required move below a hard floor, or unproved recovery stops.

`resume TARGET` selects the latest retained state when `--run-id` is omitted. It also supports an explicit, bounded checkpoint restart for an active current-schema automatic overclock that has not begun final validation:

```bash
autopioverclock resume pi@hostname --restart-from cpu-qualification --qualification-hours 2 --final-hours 48
autopioverclock resume pi@hostname --restart-from gpu-qualification --qualification-hours 2 --final-hours 48
autopioverclock resume pi@hostname --restart-from final --final-hours 48
```

`--restart-from` is accepted only by `resume` and only for full two-domain runs. In plain language: `current` keeps the saved checkpoint and is useful when you want to change future test lengths before final validation begins without replaying completed sweep work; `cpu-qualification` rechecks CPU and everything after it; `gpu-qualification` keeps the saved qualified CPU and rechecks GPU plus final validation; and `final` keeps the saved qualified pair and reruns the combined final sequence. Clocks come from retained evidence; the CLI supplies no replacement result clock, and each omitted duration retains its saved value. Each later checkpoint requires its exact prerequisite qualifications. An active final sequence cannot be rewound or relabeled. Continue a one-domain run with plain `resume TARGET`, without `--restart-from`. A completed applied full-mode run may use only `--restart-from final`, and only with a final duration longer than its retained validation; AutoPiOverclock creates a linked run, restores the verified pre-apply stock backup, validates the retained clocks fresh, and reapplies only a PASS. A fully recovered ambiguous full-mode final failure uses the saved pair as the anchor for CPU-only, GPU-only, then paired trials at the saved per-domain resolutions only while failures remain ambiguous; exact evidence immediately selects that domain. Each trial performs required requalification and restarts a fresh complete final validation. Safely recovered harness failures repeat their complete gate within the same five-retry budget. Exhausted retries, a hard-floor conflict, or uncertain recovery stop with the protected permanent-normal configuration active. Eligible older schemas are migrated conservatively; failed preflight, foreign, or ambiguous state is never silently adopted.

Use `--restart-from final` when the saved run already found and qualified the clocks and you only want a longer automatic burn-in. It avoids repeating the sweep. Unlike `test`, it remains a tuning run: proved instability can invoke the saved per-domain isolation/backoff resolutions, and a complete PASS can be applied.

`reset TARGET` is the only stock-reset command order. It is noninteractive and rejects `--yes`, run selection, tuning-plan, dependency, watchdog, dry-run, duration, domain, fan-policy, mode, and redaction flags.

## Normal options

| Option | Default | Meaning |
|---|---:|---|
| `--qualification-hours HOURS` | `2` | Hours for each domain qualification required by the selected `overclock` mode; whole numbers 1–596523. |
| `--final-hours HOURS` | `48` for `overclock`; required duration alternative for `test` | Whole hours for automatic final validation or an exact-pair test; 1–596523. A month-long test can use `--final-hours 720`. |
| `--restart-from POINT` | off | With `resume` only, keep the saved position with `current`, or deliberately repeat `cpu-qualification`, `gpu-qualification`, or `final` in a saved full two-domain run. |
| `--cpu-only` | off | Extend an eligible applied result by sweeping and qualifying only CPU while holding its retained GPU/V3D clock; mutually exclusive with `--gpu-only`. |
| `--gpu-only` | off | Extend an eligible applied result by sweeping and qualifying only GPU while holding its retained CPU clock; mutually exclusive with `--cpu-only`. |
| `--cpu-min MHZ` | protected CPU clock | Hard CPU floor. No search, qualification backoff, or final isolation may go lower; the run fails if no permitted CPU passes. Rejected by `--gpu-only`. |
| `--cpu-max MHZ` | automatic limit `3200` | Inclusive, authoritative CPU ceiling. Supplying it starts CPU in reverse and overrides conflicting history after a warning. Rejected by `--gpu-only`. |
| `--cpu-resolution MHZ` | `25` | CPU refinement and automatic reduction size; whole-MHz range `1`–`1000`. Rejected by `--gpu-only`. |
| `--gpu-min MHZ` | protected GPU/V3D clock | Hard GPU/V3D floor. No search, qualification backoff, or final isolation may go lower; the run fails if no permitted GPU passes. Rejected by `--cpu-only`. |
| `--gpu-max MHZ` | automatic limit `1200` | Inclusive, authoritative GPU/V3D ceiling. Supplying it starts GPU in reverse and overrides conflicting history after a warning. Rejected by `--cpu-only`. |
| `--gpu-resolution MHZ` | `25` | GPU/V3D refinement and automatic reduction size; whole-MHz range `1`–`1000`. Rejected by `--cpu-only`. |
| `--no-history` | off | Create a fresh plan without scanning retained failures or creating or refreshing `target-failures.txt`. It deletes nothing. |
| `--no-max-fan` | off | Use the target's ordinary fan policy instead of the temporary maximum-cooling tryboot override. Valid only for a new `overclock`, `test`, or advanced `run`. |
| `--cpu MHZ` | required for `test` | Exact CPU clock for a manual stability test. |
| `--gpu MHZ` | required for `test` | Exact GPU/V3D clock for a manual stability test. |
| `--minutes MINUTES` | legacy duration alternative for `test` | Combined timed stress duration, 1–35791380 minutes; cannot be combined with `--final-hours`. |
| `--output-dir DIR` | `$HOME/overclock-results` | Use another flat artifact directory. |
| `--ssh-port PORT` | `22` | Use another SSH destination port. |
| `--identity-file FILE` | normal SSH keys | Use one explicit SSH private key. |
| `--help` | n/a | Show help. |
| `--version` | n/a | Show the version. |

`overclock` is intentionally configuration-free and automatically chooses graphical validation for a healthy attached display/session or headless validation when no display is present. Headless Raspberry Pi OS/Debian requires neither a desktop nor audio hardware; `prepare` installs `stress-ng`, dynamically binds the V3D render node, and refuses ambiguous multi-render-node fallback. Bounds and resolutions constrain a fresh automatic search; they are not a custom result plan. Without a retained ceiling or explicit maximum, a domain follows its normal forward coarse sweep. Retained history turns that domain around at its derived ceiling. An explicit maximum also selects reverse search and remains authoritative when it conflicts with history, with the conflict reported before testing. Explicit minima are hard floors, not start hints, and resolution controls are immutable once the plan is saved. A fresh `--no-history` run skips both the retained-state scan and any ledger creation or refresh; an existing ledger remains an older audit and is never scheduling authority. The duration options are reported as `custom` unless they remain at 2 hours per qualification and 48 hours for final validation. Shortening a duration reduces confidence; it does not weaken tryboot ownership, recovery, health, temperature, throttle, workload, or apply checks. Full two-domain tuning requires active firmware-stock clocks—CPU 2400 MHz, V3D 800 or 960 MHz, and zero voltage delta—and a stable permanent root config with no explicit clock/voltage controls or unbound `include`. A one-domain mode instead requires an eligible applied result and freshly verifies that its active clocks and permanent configuration still match the retained evidence.

## Advanced support interface

The safety engine retains these commands so an interrupted or unusual run can be inspected and recovered without weakening ownership checks:

```bash
autopioverclock run TARGET [OPTIONS]
autopioverclock status TARGET [--run-id RUN_ID] [--redact]
autopioverclock summary TARGET [--run-id RUN_ID] [--redact]
autopioverclock report TARGET [--run-id RUN_ID] [--redact]
autopioverclock resume TARGET [--run-id RUN_ID]
autopioverclock recover TARGET [--run-id RUN_ID]
autopioverclock restore TARGET [--run-id RUN_ID]
autopioverclock apply TARGET [--run-id RUN_ID]
autopioverclock reset TARGET
```

The `run TARGET` command and strict `--config FILE` plans remain for development and expert use. These are not required by the normal two-command workflow; `reset TARGET` remains available when a user wants to return to stock. The explicit public `overclock` command starts without a second ordinary prompt; all safety, validation, and recovery gates remain mandatory.

| Advanced option | Accepted by | Purpose |
|---|---|---|
| `--config FILE` | `run` | Load a strict, data-only tuning plan. |
| `--mode MODE` | `run` | Select `auto`, `graphical`, or `headless` validation rather than using public automatic selection. |
| `--install-missing` | `run` | Permit installation of missing workload dependencies. `prepare` grants this for its normal job. |
| `--repair-watchdogs` | `run` | Permit repair of a planned watchdog deficiency. `prepare` grants this for its normal job. |
| `--dry-run` | `prepare`, `run` | Perform read-only discovery and plan generation. |
| `--run-id RUN_ID` | `resume`, `status`, `summary`, `recover`, `restore`, `apply`, `report` | Select an older retained operation instead of the command's normal latest choice. |
| `--yes` | `run` | Skip the ordinary run confirmation; never bypass standalone apply confirmation. |
| `--redact` | `status`, `summary`, `report` | Redact known controller/target identifiers. |

Standalone advanced `apply` still requires a current-schema `PASS`/`COMPLETE` result whose retained endurance evidence exactly matches its immutable saved final duration, displays the exact diff, and requires typed confirmation. Manual `test` records are ineligible regardless of their requested duration. `status` and `summary` perform a short read-only live query without acquiring the target's controller lock or changing boot configuration/project run artifacts; `report` remains local. `resume`, `recover`, `restore`, and `apply` fail closed when saved context is incomplete or stale.

`status TARGET` reports the target's live active and measured CPU/GPU clocks, quick throttle evidence, temperature, uptime, tryboot state, controller-lock state, and a plain verdict such as `IN PROGRESS`, `STOCK / RESET`, `OVERCLOCKED / VALIDATED`, `OVERCLOCKED / UNVERIFIED`, or `RECOVERY NEEDED`, followed by the selected saved operation when one exists. Without `--run-id`, it uses the latest operation.

`summary TARGET` gives the narrative view: sweep passes and boundaries, qualification decisions, selected pair, saved test lengths, final retries/isolation history, validation/application result, and the appropriate next action. Without `--run-id`, it selects the newest retained `overclock`, advanced `run`, or manual `test` state, so a later prepare, reset, or restore audit does not hide the tuning story. An explicit run ID selects that exact retained state.

`recover`, `restore`, and `reset` solve different problems. `recover` returns a selected run from temporary tryboot state to the permanent config that run already protects and verifies health; it does not rewrite an out-of-band permanent-config edit. `restore` selects the newest eligible fully validated applied result (or the exact `--run-id`), verifies its retained config artifact and clear tryboot ownership, displays the replacement diff, creates a new deterministic backup, restores the validated bytes, reboots, and verifies clocks, hash, watchdog, and health. A failed restore verification rolls back to the pre-restore backup. `reset` removes permanent tuning and verifies Raspberry Pi 5 stock clocks. Each retains its own audit and preserves every earlier artifact.

## Reset guarantees

Reset succeeds only after a changed boot ID, the exact expected permanent-config hash, clear tryboot state, active Pi 5 stock clocks (2400 MHz CPU, V3D 800 or 960 MHz, zero voltage delta), clean current throttle/power evidence, and the active watchdog recovery chain. Batocera must also return `/boot` to read-only state.

It fails without rewriting unknown content when it finds an active `include`, config symlink, malformed managed markers, hash race, or foreign/ambiguous tryboot path. Project-owned tryboot evidence is backed up before removal. Debian backups live below `/var/lib/autopioverclock/backups/`; Batocera backups live below `/userdata/system/autopioverclock/backups/`.
