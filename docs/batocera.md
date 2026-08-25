# Batocera backend

Batocera is Buildroot-based and does not provide a normal package manager. AutoPiOverclock stages each run's isolated worker and the optional compatibility payload under `/userdata/system/autopioverclock`, and remounts `/boot` read-write only for the shortest possible `tryboot.txt` or explicitly confirmed permanent-config operation.

## GPU harness

Before any GPU sweep, the controller runs a 20-second smoke test at normal clocks. In graphical mode the worker:

1. Retains the known-good connector/mode/frontend and audio baselines.
2. Binds the running EmulationStation process to one verified `XDG_RUNTIME_DIR` and `WAYLAND_DISPLAY`; missing, unsafe, or ambiguous socket evidence fails closed.
3. Leaves EmulationStation and its compositor running and launches `glmark2-es2-wayland --off-screen --size=1280x720` through that live session, without taking DRM master or switching VTs.
4. Requires a hardware V3D `GL_RENDERER`, a positive `glmark2 Score`, zero exit, requested-clock attainment, and clean temperature, throttle, and current-boot kernel-log evidence.
5. Re-runs the ordinary graphical/audio health gate after the smoke test before accepting the harness.

Wayland connection, canvas initialization, or missing runtime files are a `HARNESS_FAILURE`, not evidence that the clock itself is unstable. The frontend is never stopped for graphical stress, so there is no KMS/VT teardown or frontend-restart recovery boundary. Headless mode remains isolated and uses off-screen `glmark2-es2-drm` without a graphical-session requirement.

Graphical discovery also captures the current default audio-sink identity automatically. Every graphical candidate, recovery boot, and apply health gate requires that sink to remain available and unchanged; `audio_sink_pattern`, when configured, is an additional constraint rather than the baseline mechanism.

## Portable payload

`tools/build-batocera-bundle.sh` extracts ARM64 Debian packages without installing them. It includes the Wayland and DRM glmark2 executables, their shared data, and a private libjpeg compatibility library. It deliberately excludes glibc, Mesa, Wayland, DRM, and kernel components supplied by Batocera. Every file is verified from `MANIFEST.sha256` after upload, and a cached payload that lacks either executable is rebuilt.

The supported `--install-missing` builder path uses an ARM64 Debian-family controller with `apt-get`, `dpkg-deb`, access to the configured Debian package repositories, `sha256sum`, and `tar`. Building the payload is a controller-side prerequisite; Batocera itself remains package-manager-free. Run read-only `prepare` first and use `--install-missing` only when its dependency evidence shows that the portable payload is required.

Batocera follows the same token-bound tryboot ownership rules as the Debian backend. A live run refuses any pre-existing `tryboot.txt`. AutoPiOverclock records the fresh random token, completed and reservation hashes, and token-specific quarantine path before remounting `/boot`; creates with no-clobber semantics; restores and verifies the read-only mount; and re-verifies the exact completed file immediately before trigger. After verified normal recovery it briefly remounts read-write, moves only matching project evidence to the no-clobber quarantine path, revalidates it, removes it, and proves `/boot` read-only again. Changed or foreign evidence is preserved and stops the run.
