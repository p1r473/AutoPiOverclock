# Batocera backend

Batocera is Buildroot-based and does not provide a normal package manager. AutoPiOverclock stages each run's isolated worker and the optional compatibility payload under `/userdata/system/autopioverclock`, and remounts `/boot` read-write only for the shortest possible `tryboot.txt` or explicitly confirmed permanent-config operation.

## GPU harness

Before any GPU sweep, the controller runs a 20-second smoke test at normal clocks. In graphical mode the worker:

1. Retains the known-good connector/mode/frontend baseline and observes the current audio identity.
2. Binds the running EmulationStation process to one verified `XDG_RUNTIME_DIR` and `WAYLAND_DISPLAY`; missing, unsafe, or ambiguous socket evidence fails closed.
3. Leaves EmulationStation and its compositor running and launches `glmark2-es2-wayland --off-screen --size=1280x720` through that live session, without taking DRM master or switching VTs.
4. Requires a hardware V3D `GL_RENDERER`, a positive `glmark2 Score`, zero exit, requested-clock attainment, and clean temperature, throttle, and current-boot kernel-log evidence.
5. Re-runs the ordinary graphical health gate and any explicitly requested audio constraint after the smoke test before accepting the harness.

Wayland connection, canvas initialization, or missing runtime files are a `HARNESS_FAILURE`, not evidence that the clock itself is unstable. The frontend is never stopped for graphical stress, so there is no KMS/VT teardown or frontend-restart recovery boundary. Headless mode remains isolated and uses off-screen `glmark2-es2-drm` without a graphical-session requirement.

Graphical discovery captures the current default audio-sink identity automatically. Later candidate, recovery, and apply health gates compare that inferred identity for diagnostics, but a missing or changed sink warns and continues when `audio_sink_pattern` is unset. When `audio_sink_pattern` is configured, its literal match is an enforced `HARNESS_FAILURE` constraint. Neither case is CPU or GPU clock-boundary evidence.

## Portable payload

`tools/build-batocera-bundle.sh` extracts ARM64 Debian packages without installing them. It includes the Wayland and DRM glmark2 executables, their shared data, and a private libjpeg compatibility library. It deliberately excludes glibc, Mesa, Wayland, DRM, and kernel components supplied by Batocera. Every file is verified from `MANIFEST.sha256` after upload, and a cached payload that lacks either executable is rebuilt.

`prepare` automatically builds and stages this payload when it is missing. The builder requires an ARM64 Debian-family controller with `apt-get`, `dpkg-deb`, access to its configured Debian package repositories, `sha256sum`, and `tar`; Batocera itself remains package-manager-free.

## Watchdog integration

AutoPiOverclock requires a working hardware-watchdog recovery chain before tuning. `prepare` reads the active EEPROM timeout, kernel handoff, watchdog device, runtime timeout, and userspace owner. A missing hardware-watchdog condition stops before any candidate boot and must be configured separately from AutoPiOverclock. The existing hardware owner and its permanent configuration are never replaced or changed.

When a recognized permanent Batocera network/hardware keeper already exists, discovery records its configured liveness target, active service state, and installed hashes and uses it without changing it. If no recognized network watcher exists, a confirmed tuning run installs a separate temporary network-only companion aimed at the current IPv4 default gateway. That companion never opens or feeds the hardware-watchdog device, does not change EEPROM or kernel watchdog settings, and does not replace an existing keeper. If both project providers are present for explicit companion validation, the permanent keeper continues hardware feeds but yields network decisions only while the exact companion process, files, target, and run identity remain valid. It resumes built-in network supervision automatically when that proof disappears.

Strict network attribution requires a complete ordered chain of fresh durable events from the saved source boot to the current boot. Every edge binds its source and destination boot IDs, exact liveness target, unchanged installed hashes, event identity and time, active service, and matching prepared, committed, and next-boot-accepted records. A permanent hardware keeper must additionally prove every committed hardware-watchdog starvation action. The temporary network-only companion instead proves every accepted Batocera reboot request. Missing, stale, late, changed, or contradictory evidence makes the reboot unattributed. A run-owned companion is retained through interruption or failure for safe resume and removed after successful completion; backups, logs, evidence, and any permanent keeper remain.

When that proof is complete, only workload seconds explicitly reported by the target before the watcher request are retained. AutoPiOverclock restarts the same clocks for the exact remaining duration. SSH-outage time and controller estimates receive no credit. An unattributed reboot discards partial time and receives one complete same-clock replay before a repeated identical event may enter ordinary stability isolation.

Batocera follows the same token-bound tryboot ownership rules as the Debian backend. A live run refuses any pre-existing `tryboot.txt`. AutoPiOverclock records the fresh random token, completed and reservation hashes, and token-specific quarantine path before remounting `/boot`; creates with no-clobber semantics; restores and verifies the read-only mount; and re-verifies the exact completed file immediately before trigger. After verified normal recovery it briefly remounts read-write, moves only matching project evidence to the no-clobber quarantine path, revalidates it, removes it, and proves `/boot` read-only again. Changed or foreign evidence is preserved and stops the run.
