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

## Existing watchdog observation

AutoPiOverclock requires a working hardware-watchdog recovery chain before tuning, but it never installs, enables, updates, or configures a hardware or network watchdog. `prepare` reads the active EEPROM timeout, kernel handoff, watchdog device, runtime timeout, and userspace owner. A missing hardware-watchdog condition stops before any candidate boot and must be configured separately from AutoPiOverclock.

A network watcher is optional. When a recognized watcher already exists, discovery records its kind, arbitrary configured liveness target, active service state, and installed config, keeper, and service hashes. Those observations are used only to evaluate a later reboot. AutoPiOverclock does not choose or change the liveness target and does not replace the installed files.

Strict network attribution requires a fresh durable event that binds the source and current boot IDs, the exact liveness target, unchanged installed hashes, event identity and time, the active service, and matching prepared, committed, and next-boot-accepted records. Batocera must additionally prove the committed hardware-watchdog starvation action. Missing, stale, late, changed, or contradictory evidence makes the reboot unattributed.

When that proof is complete, only workload seconds explicitly reported by the target before the watcher request are retained. AutoPiOverclock restarts the same clocks for the exact remaining duration. SSH-outage time and controller estimates receive no credit. An unattributed reboot discards partial time and receives one complete same-clock replay before a repeated identical event may enter ordinary stability isolation.

Batocera follows the same token-bound tryboot ownership rules as the Debian backend. A live run refuses any pre-existing `tryboot.txt`. AutoPiOverclock records the fresh random token, completed and reservation hashes, and token-specific quarantine path before remounting `/boot`; creates with no-clobber semantics; restores and verifies the read-only mount; and re-verifies the exact completed file immediately before trigger. After verified normal recovery it briefly remounts read-write, moves only matching project evidence to the no-clobber quarantine path, revalidates it, removes it, and proves `/boot` read-only again. Changed or foreign evidence is preserved and stops the run.
