# Batocera backend

Batocera is Buildroot-based and does not provide a normal package manager. AutoPiOverclock stages each run's isolated worker and the optional compatibility payload under `/userdata/system/autopioverclock`, and remounts `/boot` read-write only for the shortest possible `tryboot.txt` or explicitly confirmed permanent-config operation.

## GPU harness

Before any GPU sweep, the controller runs a 20-second smoke test at normal clocks. In graphical mode the worker:

1. Captures the known-good connector/mode/frontend baseline.
2. Stops EmulationStation and waits for compositor ownership to clear.
3. asks `openvt -s` for a free VT when available, without forcing the already-active frontend VT;
4. runs `glmark2-es2-drm` on a real DRM scanout surface while retaining its renderer and score output in the run log; the launcher requests a positive size different from the connected mode to avoid glmark2 2023.01's pre-window fullscreen short circuit, while the DRM backend still creates the surface at the kernel-reported connected mode;
5. requires `GL_RENDERER` and `glmark2 Score` output;
6. switches back to the original VT, releases the temporary VT, restarts the frontend, and waits for the original baseline.

Canvas initialization, missing runtime files, or lost DRM master is a `HARNESS_FAILURE`, not evidence that the clock itself is unstable. Failed frontend restoration is a `RECOVERY_FAILURE`; the controller may attempt one verified normal-config reboot only when the live and saved tryboot state is clear and the permanent config hash is unchanged.

Graphical discovery also captures the current default audio-sink identity automatically. Every graphical candidate, recovery boot, and apply health gate requires that sink to remain available and unchanged; `audio_sink_pattern`, when configured, is an additional constraint rather than the baseline mechanism.

## Portable payload

`tools/build-batocera-bundle.sh` extracts ARM64 Debian packages without installing them. It includes glmark2, its data, and a private libjpeg compatibility library. It deliberately excludes glibc, Mesa, DRM, and kernel components. Every file is verified from `MANIFEST.sha256` after upload.

The supported `--install-missing` builder path uses an ARM64 Debian-family controller with `apt-get`, `dpkg-deb`, access to the configured Debian package repositories, `sha256sum`, and `tar`. Building the payload is a controller-side prerequisite; Batocera itself remains package-manager-free. Run read-only `prepare` first and use `--install-missing` only when its dependency evidence shows that the portable payload is required.

Batocera follows the same token-bound tryboot ownership rules as the Debian backend. A live run refuses any pre-existing `tryboot.txt`. AutoPiOverclock records the fresh random token, completed and reservation hashes, and token-specific quarantine path before remounting `/boot`; creates with no-clobber semantics; restores and verifies the read-only mount; and re-verifies the exact completed file immediately before trigger. After verified normal recovery it briefly remounts read-write, moves only matching project evidence to the no-clobber quarantine path, revalidates it, removes it, and proves `/boot` read-only again. Changed or foreign evidence is preserved and stops the run.
