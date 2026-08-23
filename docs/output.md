# Output and classifications

All artifacts are flat under `--output-dir` (`$HOME/overclock-results` by default); no per-target directories are created and existing runs are never deleted. Each run records its effective `.conf`, read-only `-discovery.txt`, atomic `.state`, `.log`, `.csv`, `.jsonl`/`.json`, summary, and per-candidate logs. The `*-latest.log`, `*-latest-summary.txt`, `*-latest.state`, and `*-latest.json` links select the latest retained run for a target.

| Classification | Meaning |
|---|---|
| `PREFLIGHT_FAILURE` | Unsupported/missing prerequisite before tuning. |
| `HARNESS_FAILURE` | The intended test did not actually run or prove its workload. |
| `BOOT_FAILURE` | Candidate boot or required display/audio/service health failed. |
| `STABILITY_FAILURE` | Power, temperature, kernel, GPU, storage, filesystem, or stress failure. |
| `RECOVERY_FAILURE` | The target did not return to verified permanent normal configuration. |
| `APPLY_FAILURE` | Permanent application or rollback failed. |

The `.state` file is data-only: sorted uppercase keys with base64-encoded values. It is never sourced. The `.jsonl` event stream is finalized into a JSON array when the controller exits.

Clock results are intentionally separate: `PASSED_CPUS`/`PASSED_GPUS` record observed passes, `RECOMMENDED_CPU`/`RECOMMENDED_GPU` record the conservative backed-off choice, and `FINAL_CPU`/`FINAL_GPU` remain empty until the full final validation completes.

`RUN_SCHEMA` prevents an older interrupted state from bypassing newer resume gates. `CANDIDATE_LABEL`, candidate clocks, and `CANDIDATE_STAGE` identify the exact recoverable candidate substage. `FINAL_TARGET_CPU`, `FINAL_TARGET_GPU`, and `FINAL_STAGE` do the same for final validation. `VALIDATION_SCHEMA` is recorded only when final validation completes and is required by `apply`.

Graphical runs store `DISPLAY_BASELINE` and the discovered `AUDIO_BASELINE`. The display identity is always required on subsequent candidate, normal-recovery, and apply health checks. Debian preserves the default audio-sink identity when one was captured; a configured `audio_sink_pattern` still requires a matching sink. Batocera graphical runs require both identities. Watchdog discovery records the EEPROM timeout, active kernel handoff, device, live timeout, and owner. A Debian repair additionally records its status, old/expected/new hashes, and backup path so an interrupted `PREPARE` report does not conceal a partial change.

Interrupted apply state records `APPLY_OLD_HASH`, `APPLY_EXPECTED_HASH`, a deterministic `APPLY_BACKUP`, boot evidence, and the intended recovery action. Reconciliation accepts only the known old or proposed hash; an unknown permanent hash is left untouched for manual recovery.
