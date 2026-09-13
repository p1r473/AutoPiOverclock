#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
APO_ROOT=$ROOT
source "$ROOT/lib/common.sh"
source "$ROOT/lib/state.sh"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

assert_codec() {
    local value=$1 label=$2 encoded decoded oracle
    apo_state_encode "$value" encoded
    oracle=$(printf '%s' "$value" | base64 | tr -d '\n')
    [[ $encoded == "$oracle" ]] || {
        printf 'state codec differed from GNU base64 for %s\n' "$label" >&2
        exit 1
    }
    apo_state_decode "$encoded" decoded
    [[ $decoded == "$value" ]] || {
        printf 'state codec failed round trip for %s\n' "$label" >&2
        exit 1
    }
}

declare -a rfc_values=('' f fo foo foob fooba foobar)
declare -a rfc_encoded=('' Zg== Zm8= Zm9v Zm9vYg== Zm9vYmE= Zm9vYmFy)
for index in "${!rfc_values[@]}"; do
    apo_state_encode "${rfc_values[index]}" encoded
    [[ $encoded == "${rfc_encoded[index]}" ]]
    assert_codec "${rfc_values[index]}" "RFC vector $index"
done

assert_codec $'spaces\ttabs\r\nnewlines\n\n' 'ASCII controls and trailing newlines'
assert_codec 'quotes '\''" backslash \\ dollar $ percent % equals =' 'shell punctuation'
assert_codec 'café déjà vu π' 'UTF-8 text'

all_nonzero_bytes=''
for (( byte=1; byte<=255; byte++ )); do
    printf -v octal '%03o' "$byte"
    printf -v character '%b' "\\$octal"
    all_nonzero_bytes+=$character
done
assert_codec "$all_nonzero_bytes" 'all non-NUL byte values'

for (( sample=0; sample<64; sample++ )); do
    random_value=''
    random_length=$(((sample * 73) % 258))
    for (( offset=0; offset<random_length; offset++ )); do
        byte=$(((sample * 97 + offset * 151 + 31) % 255 + 1))
        printf -v octal '%03o' "$byte"
        printf -v character '%b' "\\$octal"
        random_value+=$character
    done
    assert_codec "$random_value" "deterministic byte sample $sample length $random_length"
done

long_value=$'checkpoint payload with UTF-8 café and newline\n'
while (( ${#long_value} < 65536 )); do long_value+=$long_value; done
long_value=${long_value:0:65536}
assert_codec "$long_value" '65536-byte state value'

for malformed in A AAA ==== A=== AA=A A=AA AAAA= 'AA==AAAA' AB== AAB= AA== $'Zm9v\n' 'Zm9v '; do
    if apo_state_decode "$malformed" decoded; then
        printf 'state codec accepted malformed or NUL Base64: %q\n' "$malformed" >&2
        exit 1
    fi
done

APO_STATE_FILE="$TEMP_DIR/codec.state"
APO_STATE=()
apo_state_set FORMAT_VERSION 1
apo_state_set TRAILING_NEWLINES $'line one\nline two\n\n'
apo_state_set NONZERO_BYTES "$all_nonzero_bytes"
apo_state_save
[[ $(stat -c '%a' "$APO_STATE_FILE") == 600 ]]
APO_STATE=()
apo_state_load "$APO_STATE_FILE"
[[ ${APO_STATE[TRAILING_NEWLINES]} == $'line one\nline two\n\n' ]]
[[ ${APO_STATE[NONZERO_BYTES]} == "$all_nonzero_bytes" ]]

# Recurring checkpoints must not launch the external encoder, decoder, temp
# creator, sorter, chmod, or date command. Atomic rename and durability sync
# remain explicit external filesystem operations.
EXTERNAL_MARKER=$TEMP_DIR/unexpected-external-command
(
    base64() { printf 'base64\n' >> "$EXTERNAL_MARKER"; return 99; }
    mktemp() { printf 'mktemp\n' >> "$EXTERNAL_MARKER"; return 99; }
    sort() { printf 'sort\n' >> "$EXTERNAL_MARKER"; return 99; }
    chmod() { printf 'chmod\n' >> "$EXTERNAL_MARKER"; return 99; }
    date() { printf 'date\n' >> "$EXTERNAL_MARKER"; return 99; }
    apo_state_set CHECKPOINT_PROBE changed
    apo_state_save
)
[[ ! -e $EXTERNAL_MARKER ]]

# A stale file at the first deterministic name is never truncated. Noclobber
# creation advances to the next name and restores the caller's shell option.
APO_STATE_TEMP_SEQUENCE=0
FIRST_COLLISION="${APO_STATE_FILE}.tmp.${BASHPID}.1"
printf 'preserve-collision\n' > "$FIRST_COLLISION"
noclobber_before=$(set -o | awk '$1 == "noclobber" {print $2}')
apo_state_create_temporary_file "$APO_STATE_FILE" CREATED_TEMP
noclobber_after=$(set -o | awk '$1 == "noclobber" {print $2}')
[[ $CREATED_TEMP == "${APO_STATE_FILE}.tmp.${BASHPID}.2" ]]
[[ $(<"$FIRST_COLLISION") == preserve-collision ]]
[[ $noclobber_after == "$noclobber_before" ]]
rm -f -- "$FIRST_COLLISION" "$CREATED_TEMP"

printf 'test_state_codec: PASS\n'
