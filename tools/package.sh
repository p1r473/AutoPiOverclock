#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
ROOT_PARENT=$(dirname -- "$ROOT")
ROOT_NAME=$(basename -- "$ROOT")
VERSION=$(<"$ROOT/VERSION")
DESTINATION=${1:-"$ROOT/dist"}
mkdir -p "$DESTINATION"
DESTINATION=$(cd -- "$DESTINATION" && pwd -P)
SOURCE_ARCHIVE="$DESTINATION/AutoPiOverclock-${VERSION}-source.tar.gz"
ZIP_ARCHIVE="$DESTINATION/AutoPiOverclock-${VERSION}-source.zip"
CHECKSUM_FILE="$DESTINATION/AutoPiOverclock-${VERSION}-source-SHA256SUMS.txt"

for required_command in tar zip sha256sum; do
    command -v "$required_command" >/dev/null 2>&1 || { printf 'Missing packaging command: %s\n' "$required_command" >&2; exit 1; }
done

if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if [[ -n $(git -C "$ROOT" status --porcelain --untracked-files=normal) ]]; then
        printf 'Refusing to package a Git worktree with tracked or untracked changes. Commit or stash them first.\n' >&2
        exit 1
    fi
    rm -f -- "$SOURCE_ARCHIVE" "$ZIP_ARCHIVE" "$CHECKSUM_FILE"
    git -C "$ROOT" archive --format=tar.gz --prefix="$ROOT_NAME/" -o "$SOURCE_ARCHIVE" HEAD
    git -C "$ROOT" archive --format=zip --prefix="$ROOT_NAME/" -o "$ZIP_ARCHIVE" HEAD
else
    rm -f -- "$SOURCE_ARCHIVE" "$ZIP_ARCHIVE" "$CHECKSUM_FILE"
    tar \
        --exclude="$ROOT_NAME/.git" \
        --exclude="$ROOT_NAME/dist" \
        -C "$ROOT_PARENT" \
        -czf "$SOURCE_ARCHIVE" \
        "$ROOT_NAME"
    (
        cd "$ROOT_PARENT"
        zip -qr "$ZIP_ARCHIVE" "$ROOT_NAME" \
            -x "$ROOT_NAME/.git/*" "$ROOT_NAME/dist/*"
    )
fi
sha256sum "$SOURCE_ARCHIVE" "$ZIP_ARCHIVE" > "$CHECKSUM_FILE"
printf '%s\n%s\n%s\n' "$SOURCE_ARCHIVE" "$ZIP_ARCHIVE" "$CHECKSUM_FILE"
