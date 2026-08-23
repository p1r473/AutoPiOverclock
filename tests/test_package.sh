#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT
SOURCE_COPY="$TEMP_DIR/source"
OUTPUT_DIR="$TEMP_DIR/output"
mkdir -p "$OUTPUT_DIR"
cp -a "$ROOT" "$SOURCE_COPY"
rm -rf "$SOURCE_COPY/.git" "$SOURCE_COPY/dist"
git -C "$SOURCE_COPY" init -q
git -C "$SOURCE_COPY" config user.name AutoPiOverclock-Test
git -C "$SOURCE_COPY" config user.email test@example.invalid
git -C "$SOURCE_COPY" add --all
git -C "$SOURCE_COPY" commit -q -m 'fixture source tree'
"$SOURCE_COPY/tools/package.sh" "$OUTPUT_DIR" >/dev/null
VERSION=$(<"$SOURCE_COPY/VERSION")
TAR_FILE="$OUTPUT_DIR/AutoPiOverclock-${VERSION}-source.tar.gz"
ZIP_FILE="$OUTPUT_DIR/AutoPiOverclock-${VERSION}-source.zip"
CHECKSUM_FILE="$OUTPUT_DIR/AutoPiOverclock-${VERSION}-source-SHA256SUMS.txt"
[[ -f $TAR_FILE && -f $ZIP_FILE && -f $CHECKSUM_FILE ]]
tar -tzf "$TAR_FILE" > "$TEMP_DIR/tar.list"
unzip -Z1 "$ZIP_FILE" > "$TEMP_DIR/zip.list"
for required in \
    source/tests/fixtures/debian-pass.log \
    source/tests/fixtures/interrupted-tryboot.state; do
    grep -qx "$required" "$TEMP_DIR/tar.list"
    grep -qx "$required" "$TEMP_DIR/zip.list"
done
if grep -Eq '(^|/)\.git(/|$)|(^|/)dist(/|$)' "$TEMP_DIR/tar.list"; then
    echo 'tar package contains excluded repository data' >&2
    exit 1
fi
if grep -Eq '(^|/)\.git(/|$)|(^|/)dist(/|$)' "$TEMP_DIR/zip.list"; then
    echo 'ZIP package contains excluded repository data' >&2
    exit 1
fi
(
    cd "$OUTPUT_DIR"
    sha256sum -c "$(basename "$CHECKSUM_FILE")" >/dev/null
)
printf untracked > "$SOURCE_COPY/untracked-fixture"
if "$SOURCE_COPY/tools/package.sh" "$TEMP_DIR/dirty-output" >/dev/null 2>&1; then
    echo 'Git packaging path accepted an untracked source file' >&2
    exit 1
fi
printf 'test_package: PASS\n'
