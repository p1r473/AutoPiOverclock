#!/usr/bin/env bash
# Build the narrow portable glmark2 payload used by the Batocera profile.
# This deliberately does not bundle or replace glibc, Mesa, DRM, or kernel drivers.
set -Eeuo pipefail
umask 022

OUTPUT_ARGUMENT=${1:-dist}
ARCHITECTURE=${APO_BATO_ARCH:-arm64}
SOURCE_TREE=${APO_BATO_BUNDLE_SOURCE:-}
PACKAGE_NAME=autopioverclock-batocera-glmark2.tar.gz

if [[ $OUTPUT_ARGUMENT == *.tar.gz ]]; then
    OUTPUT_FILE=$OUTPUT_ARGUMENT
    OUTPUT_DIR=$(dirname "$OUTPUT_FILE")
else
    OUTPUT_DIR=$OUTPUT_ARGUMENT
    OUTPUT_FILE="${OUTPUT_DIR}/${PACKAGE_NAME}"
fi
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(cd "$OUTPUT_DIR" && pwd -P)
OUTPUT_FILE="${OUTPUT_DIR}/$(basename "$OUTPUT_FILE")"

WORK_DIR=$(mktemp -d /tmp/autopioverclock-batocera-bundle.XXXXXX)
trap 'rm -rf "$WORK_DIR"' EXIT
STAGE="$WORK_DIR/stage"
mkdir -p "$STAGE"

if [[ -n $SOURCE_TREE ]]; then
    [[ -d $SOURCE_TREE ]] || { printf 'APO_BATO_BUNDLE_SOURCE is not a directory: %s\n' "$SOURCE_TREE" >&2; exit 1; }
    cp -a "$SOURCE_TREE"/. "$STAGE"/
    SOURCE_DESCRIPTION="pre-staged source tree: $SOURCE_TREE"
else
    for command_name in apt-get dpkg-deb sha256sum tar; do
        command -v "$command_name" >/dev/null 2>&1 || { printf 'Required build command is missing: %s\n' "$command_name" >&2; exit 1; }
    done
    DOWNLOAD_DIR="$WORK_DIR/downloads"
    mkdir -p "$DOWNLOAD_DIR"
    cd "$DOWNLOAD_DIR"
    printf 'Downloading ARM64 packages without installing them...\n' >&2
    apt-get download "glmark2-es2-drm:${ARCHITECTURE}" "glmark2-es2-wayland:${ARCHITECTURE}" "glmark2-data:${ARCHITECTURE}" "libjpeg62-turbo:${ARCHITECTURE}"
    shopt -s nullglob
    GLMARK_PACKAGES=()
    while IFS= read -r -d '' package_file; do GLMARK_PACKAGES+=("${package_file#./}"); done < <(
        find . -maxdepth 1 -type f \( \
            -name "glmark2-es2-drm_*_${ARCHITECTURE}.deb" -o \
            -name "glmark2-es2-wayland_*_${ARCHITECTURE}.deb" -o \
            -name 'glmark2-data_*_all.deb' -o \
            -name "glmark2-data_*_${ARCHITECTURE}.deb" \
        \) -print0 | LC_ALL=C sort -z
    )
    JPEG_PACKAGES=()
    while IFS= read -r -d '' package_file; do JPEG_PACKAGES+=("${package_file#./}"); done < <(
        find . -maxdepth 1 -type f -name "libjpeg62-turbo_*_${ARCHITECTURE}.deb" -print0 | LC_ALL=C sort -z
    )
    (( ${#GLMARK_PACKAGES[@]} >= 3 )) || { printf 'Could not locate both downloaded glmark2 binaries and the data package.\n' >&2; exit 1; }
    (( ${#JPEG_PACKAGES[@]} == 1 )) || { printf 'Could not locate the downloaded libjpeg package.\n' >&2; exit 1; }
    for package_file in "${GLMARK_PACKAGES[@]}"; do dpkg-deb -x "$package_file" "$STAGE"; done
    mkdir -p "$STAGE/jpeg-package"
    dpkg-deb -x "${JPEG_PACKAGES[0]}" "$STAGE/jpeg-package"
    {
        printf 'Packages used:\n'
        for package_file in "${GLMARK_PACKAGES[@]}" "${JPEG_PACKAGES[@]}"; do
            printf '%s %s %s\n' "$(dpkg-deb -f "$package_file" Package)" "$(dpkg-deb -f "$package_file" Version)" "$(dpkg-deb -f "$package_file" Architecture)"
        done
    } > "$STAGE/PACKAGES.txt"
    SOURCE_DESCRIPTION="Debian package extraction for ${ARCHITECTURE}"
fi

[[ -x $STAGE/usr/bin/glmark2-es2-drm ]] || { printf 'Staged glmark2-es2-drm is missing or not executable.\n' >&2; exit 1; }
[[ -x $STAGE/usr/bin/glmark2-es2-wayland ]] || { printf 'Staged glmark2-es2-wayland is missing or not executable.\n' >&2; exit 1; }
[[ -d $STAGE/usr/share/glmark2 ]] || { printf 'Staged glmark2 data directory is missing.\n' >&2; exit 1; }
find "$STAGE/jpeg-package" -type f -name 'libjpeg.so.62*' -print -quit | grep -q . || { printf 'Staged libjpeg.so.62 is missing.\n' >&2; exit 1; }

cat > "$STAGE/BUNDLE-README.txt" <<EOF_README
AutoPiOverclock Batocera glmark2 compatibility payload
======================================================
Source: ${SOURCE_DESCRIPTION}
Architecture: ${ARCHITECTURE}

This archive contains the glmark2-es2-drm and glmark2-es2-wayland executables,
their data files, and a private libjpeg compatibility library. It does not
replace Batocera's glibc, Mesa, DRM stack, kernel, or system libraries.
AutoPiOverclock verifies this payload with a short renderer smoke test before
any candidate or endurance run.
EOF_README

(
    cd "$STAGE"
    find . -type f ! -name MANIFEST.sha256 -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > MANIFEST.sha256
)
TEMP_ARCHIVE="${OUTPUT_FILE}.tmp.$$"
tar -C "$STAGE" -czf "$TEMP_ARCHIVE" .
mv -f "$TEMP_ARCHIVE" "$OUTPUT_FILE"
sha256sum "$OUTPUT_FILE" > "${OUTPUT_FILE}.sha256"
printf 'Created %s\n' "$OUTPUT_FILE"
printf 'SHA-256: %s\n' "$(awk '{print $1}' "${OUTPUT_FILE}.sha256")"
