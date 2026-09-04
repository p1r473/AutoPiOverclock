#!/usr/bin/env bash
# Remote target discovery, profile selection, dependency and watchdog preflight.

declare -Ag APO_DISCOVERY=()
APO_PROFILE=''
APO_LOCAL_WORKER=''
APO_REMOTE_WORK_DIR=''
APO_REMOTE_WORKER=''
APO_BOOT_TIMEOUT=300
APO_BOOT_SETTLE_SECONDS=15
APO_MODE_EFFECTIVE=''
APO_BOOT_CONFIG=''
APO_TRYBOOT_CONFIG=''
APO_INITIAL_TRYBOOT_EXISTS=0
APO_INITIAL_TRYBOOT_TYPE=absent
APO_INITIAL_TRYBOOT_HASH=unavailable
APO_BOOT_MOUNT=''
APO_GPU_KEY=''
APO_NORMAL_CPU=''
APO_NORMAL_GPU=''
APO_NORMAL_VOLTAGE=''
APO_PERMANENT_TUNING_PROVENANCE=''
APO_PERMANENT_TUNING_EVIDENCE=''
APO_AUTO_BASELINE_CPU=''
APO_AUTO_BASELINE_GPU=''
APO_AUTO_BASELINE_VOLTAGE=''
APO_AUTO_BASELINE_PROVENANCE=''
APO_AUTO_BASELINE_EVIDENCE=''
APO_TEST_VOLTAGE=''
APO_PERMANENT_CONFIG_HASH=''
APO_THROTTLE_BASELINE=''
APO_THROTTLE_RUNTIME_BASELINE='throttled=0x0'
APO_THROTTLE_RECENT_SUPPORTED=0
APO_DISPLAY_BASELINE=''
APO_AUDIO_BASELINE=''
APO_STORAGE_LAYOUT=''
APO_NEED_GPU=0
APO_REQUIRE_GPU_STRESS=0
APO_WORKER_DEPLOYED=0
APO_GRAPHICAL_AUDIO_DISCOVERY_ATTEMPTS=5
APO_AUDIO_DISCOVERY_ATTEMPTS_USED=0

apo_probe_profile() {
    local detected
    detected=$(apo_ssh_read 'if [ -f /usr/share/batocera/batocera.version ] || command -v batocera-version >/dev/null 2>&1; then printf batocera; elif [ -r /etc/os-release ]; then . /etc/os-release; case "${ID:-}" in raspbian|debian|ubuntu) printf debian ;; *) printf unsupported ;; esac; else printf unsupported; fi' || true)
    case $detected in batocera|debian) printf '%s' "$detected" ;; *) apo_die "Unsupported target operating system: ${detected:-unknown}" "$APO_EXIT_PREFLIGHT" ;; esac
}

apo_load_profile() {
    local profile_name=$1 profile_file
    apo_is_safe_run_id "${APO_RUN_ID:-}" || apo_die 'Refusing to derive a target worker path from an unsafe run ID.' "$APO_EXIT_INTERNAL"
    case $profile_name in
        debian|batocera) ;;
        *) apo_die "Unsupported saved target profile: ${profile_name:-missing}" "$APO_EXIT_PREFLIGHT" ;;
    esac
    profile_file="${APO_ROOT}/profiles/${profile_name}.sh"
    [[ -r $profile_file ]] || apo_die "Missing local profile: $profile_file" "$APO_EXIT_INTERNAL"
    # shellcheck source=/dev/null
    source "$profile_file"
}

apo_deploy_worker() {
    [[ -r $APO_LOCAL_WORKER ]] || apo_die "Missing local worker: $APO_LOCAL_WORKER" "$APO_EXIT_INTERNAL"
    apo_remote_upload_root "$APO_LOCAL_WORKER" "$APO_REMOTE_WORKER" || apo_die 'Could not deploy the target worker.' "$APO_EXIT_PREFLIGHT"
    APO_WORKER_DEPLOYED=1
    APO_WORKER_BOOT_ID=$(apo_remote_boot_id || true)
}

apo_redeploy_worker_for_boot() {
    local boot_id=$1 context=${2:-post-reboot}
    [[ -n $boot_id ]] || {
        APO_LAST_CLASS=HARNESS_FAILURE
        APO_LAST_REASON="Could not identify the target boot before redeploying the transient worker for $context."
        return 1
    }
    [[ -r $APO_LOCAL_WORKER ]] || {
        APO_LAST_CLASS=HARNESS_FAILURE
        APO_LAST_REASON="The local target worker is missing before $context: $APO_LOCAL_WORKER"
        return 1
    }
    if ! apo_remote_upload_root "$APO_LOCAL_WORKER" "$APO_REMOTE_WORKER"; then
        APO_LAST_CLASS=HARNESS_FAILURE
        APO_LAST_REASON="The target returned after $context, but its run-isolated worker could not be redeployed."
        return 1
    fi
    APO_WORKER_DEPLOYED=1
    APO_WORKER_BOOT_ID=$boot_id
}

apo_ensure_worker_for_boot() {
    local boot_id=$1 context=${2:-current-boot}
    if [[ ${APO_WORKER_BOOT_ID:-} == "$boot_id" ]] &&
       apo_remote_root_read "test -x $(apo_sh_quote "$APO_REMOTE_WORKER")" >/dev/null 2>&1; then
        return 0
    fi
    apo_redeploy_worker_for_boot "$boot_id" "$context"
}

apo_post_reboot_handshake() {
    local old_boot_id=$1 timeout_seconds=$2 context=${3:-reboot}
    local new_boot_id
    APO_REBOOT_BOOT_ID=''
    APO_REBOOT_OBSERVED_BOOT_ID=''
    APO_REBOOT_HANDSHAKE_STAGE='wait'
    new_boot_id=$(apo_wait_for_new_boot "$old_boot_id" "$timeout_seconds" "$context" || true)
    [[ -n $new_boot_id && $new_boot_id != "$old_boot_id" ]] || {
        APO_LAST_CLASS=HARNESS_FAILURE
        APO_LAST_REASON="The target did not return with a new boot ID after $context."
        return 1
    }
    APO_REBOOT_OBSERVED_BOOT_ID=$new_boot_id
    APO_REBOOT_HANDSHAKE_STAGE='worker'
    apo_redeploy_worker_for_boot "$new_boot_id" "$context" || return 1
    APO_REBOOT_BOOT_ID=$new_boot_id
    APO_REBOOT_HANDSHAKE_STAGE='complete'
}

apo_normalize_initial_boot() {
    local tryboot_flag old_boot_id new_boot_id
    tryboot_flag=$(apo_remote_tryboot_flag || true)
    case $tryboot_flag in
        00000000)
            return 0
            ;;
        00000001)
            if (( APO_DRY_RUN == 1 )); then
                apo_die 'Target is currently booted through tryboot. Read-only discovery refuses to record candidate clocks as the normal baseline; reboot normally or start a run that can recover it first.' "$APO_EXIT_PREFLIGHT"
            fi
            old_boot_id=$(apo_remote_boot_id) || apo_die 'Could not read boot ID before initial tryboot normalization.' "$APO_EXIT_RECOVERY"
            apo_state_set TRYBOOT_EXPECTED 1
            apo_state_set MUTATIONS_STARTED 1
            apo_state_set LAST_BOOT_ID "$old_boot_id"
            apo_state_set SUBPHASE INITIAL_TRYBOOT_RECOVERY
            apo_state_save
            apo_event initial-recovery WARN '' 'Target entered the run already in tryboot; rebooting to permanent normal config before baseline discovery.'
            apo_remote_worker "$APO_REMOTE_WORKER" reboot-normal >/dev/null 2>&1 || true
            if ! apo_post_reboot_handshake "$old_boot_id" "$APO_BOOT_TIMEOUT" initial-tryboot-recovery; then
                if [[ ${APO_REBOOT_HANDSHAKE_STAGE:-wait} == worker ]]; then
                    apo_die "Initial tryboot recovery returned, but verification could not continue: $APO_LAST_REASON" "$APO_EXIT_RECOVERY"
                fi
                apo_die 'Initial tryboot recovery did not return to SSH before timeout.' "$APO_EXIT_RECOVERY"
            fi
            new_boot_id=$APO_REBOOT_BOOT_ID
            sleep "$APO_BOOT_SETTLE_SECONDS"
            tryboot_flag=$(apo_remote_tryboot_flag || true)
            [[ $tryboot_flag == 00000000 ]] || apo_die "Initial recovery still reports tryboot flag ${tryboot_flag:-missing}." "$APO_EXIT_RECOVERY"
            apo_state_set TRYBOOT_EXPECTED 0
            apo_state_set LAST_BOOT_ID "$new_boot_id"
            apo_state_set NORMAL_BOOT_ID "$new_boot_id"
            apo_state_set SUBPHASE INITIAL_NORMALIZED
            apo_state_save
            apo_event initial-recovery PASS '' 'Permanent normal boot was restored before discovery.'
            ;;
        *)
            apo_die "Could not determine the target tryboot state before discovery (${tryboot_flag:-missing})." "$APO_EXIT_PREFLIGHT"
            ;;
    esac
}

apo_discovery_capture() {
    local output_file=${APO_DISCOVERY_FILE:-/tmp/autopioverclock-discovery.$$} remote_rc attempt attempts_used=0 wrapper
    apo_transient_read_policy_normalize
    for (( attempt=1; attempt<=APO_TRANSIENT_READ_ATTEMPTS; attempt++ )); do
        attempts_used=$attempt
        : > "$output_file"
        set +e
        if (( APO_WORKER_DEPLOYED == 1 )); then
            apo_remote_worker "$APO_REMOTE_WORKER" discover 2>&1 | tee "$output_file" | tee -a "$APO_LOG_FILE"
            remote_rc=${PIPESTATUS[0]}
        else
            if (( APO_REMOTE_IS_ROOT == 1 )); then wrapper='/bin/bash -s -- discover';
            else wrapper='sudo -n /bin/bash -s -- discover'; fi
            command ssh "${APO_SSH_OPTIONS[@]}" -T "$APO_REMOTE_TARGET" "$wrapper" < "$APO_LOCAL_WORKER" 2>&1 | tee "$output_file" | tee -a "$APO_LOG_FILE"
            remote_rc=${PIPESTATUS[0]}
        fi
        set -e
        apo_classify_output "$output_file" discovery
        if (( remote_rc == 0 )) && [[ $APO_LAST_CLASS == PASS ]]; then
            apo_parse_data_file "$output_file" APO_DISCOVERY
            return 0
        fi
        if (( APO_LAST_RESULT_STRUCTURED == 1 )) && [[ $APO_LAST_CLASS != PASS ]]; then break; fi
        if [[ $APO_LAST_CLASS != HARNESS_FAILURE && $APO_LAST_CLASS != PASS ]]; then break; fi
        if (( attempt < APO_TRANSIENT_READ_ATTEMPTS )); then
            apo_event discovery-transport-retry WARN HARNESS_FAILURE "Discovery transport evidence was incomplete; repeating the read-only discovery capture (attempt $((attempt + 1))/$APO_TRANSIENT_READ_ATTEMPTS)."
            apo_transient_read_delay
        fi
    done
    [[ $APO_LAST_CLASS != PASS ]] || {
        APO_LAST_CLASS=HARNESS_FAILURE
        APO_LAST_REASON='Discovery returned PASS evidence through a failed SSH transport.'
    }
    apo_die "Discovery failed after $attempts_used attempts: $APO_LAST_REASON" "$(apo_class_exit_code "$APO_LAST_CLASS")"
}

apo_validate_pi5() {
    local model=${APO_DISCOVERY[MODEL]:-} compatible=${APO_DISCOVERY[COMPATIBLE]:-} arch=${APO_DISCOVERY[ARCH]:-}
    [[ $model == *'Raspberry Pi 5'* || $compatible == *bcm2712* ]] || apo_die "Target is not identified as Raspberry Pi 5/bcm2712: ${model:-unknown}" "$APO_EXIT_PREFLIGHT"
    [[ $arch == aarch64 || $arch == arm64 ]] || apo_die "Target architecture is not 64-bit ARM: ${arch:-unknown}" "$APO_EXIT_PREFLIGHT"
}

apo_choose_mode() {
    local connected=${APO_DISCOVERY[DISPLAY_CONNECTED]:-0} present=${APO_DISCOVERY[DISPLAY_PRESENT]:-${APO_DISCOVERY[DISPLAY_CONNECTED]:-0}}
    case $APO_MODE_REQUESTED in
        auto)
            if [[ $connected == 1 ]]; then
                APO_MODE_EFFECTIVE=graphical
            elif [[ $present == 1 ]]; then
                apo_die 'A display is physically connected, but a healthy graphical baseline could not be captured. Refusing to misclassify the target as headless.' "$APO_EXIT_HARNESS"
            else
                APO_MODE_EFFECTIVE=headless
            fi
            ;;
        graphical) [[ $connected == 1 ]] || apo_die 'Graphical mode was requested, but no healthy graphical baseline was captured.' "$APO_EXIT_PREFLIGHT"; APO_MODE_EFFECTIVE=graphical ;;
        headless) APO_MODE_EFFECTIVE=headless ;;
    esac
}

apo_retry_graphical_audio_baseline() {
    local attempt key discovered_audio
    local -a bound_keys=(
        PROFILE MODEL COMPATIBLE ARCH OS_ID OS_VERSION
        BOOT_CONFIG TRYBOOT_CONFIG TRYBOOT_EXISTS TRYBOOT_TYPE TRYBOOT_HASH BOOT_MOUNT
        GPU_KEY NORMAL_CPU NORMAL_GPU NORMAL_VOLTAGE NORMAL_VOLTAGE_SOURCE
        PERMANENT_TUNING_PROVENANCE PERMANENT_TUNING_EVIDENCE PERMANENT_HASH
        ROOT_SOURCE BOOT_SOURCE DISPLAY_BASELINE DISPLAY_PRESENT DISPLAY_CONNECTED
    )
    local -A initial_discovery=()

    APO_AUDIO_DISCOVERY_ATTEMPTS_USED=0
    [[ $APO_MODE_EFFECTIVE == graphical ]] || return 0
    APO_AUDIO_DISCOVERY_ATTEMPTS_USED=1
    [[ -z ${APO_DISCOVERY[AUDIO_BASELINE]:-} ]] || return 0

    for key in "${!APO_DISCOVERY[@]}"; do
        initial_discovery[$key]=${APO_DISCOVERY[$key]}
    done

    for (( attempt=2; attempt<=APO_GRAPHICAL_AUDIO_DISCOVERY_ATTEMPTS; attempt++ )); do
        apo_event discovery-audio-retry WARN HARNESS_FAILURE \
            "Graphical audio was not ready during discovery; repeating the complete read-only capture (attempt $attempt/$APO_GRAPHICAL_AUDIO_DISCOVERY_ATTEMPTS)."
        apo_transient_read_delay
        apo_discovery_capture
        APO_AUDIO_DISCOVERY_ATTEMPTS_USED=$attempt

        for key in "${bound_keys[@]}"; do
            [[ ${APO_DISCOVERY[$key]:-} == "${initial_discovery[$key]:-}" ]] ||
                apo_die "Target discovery field $key changed while waiting for the graphical audio baseline; refusing to combine evidence from different target/configuration states." "$APO_EXIT_PREFLIGHT"
        done
        discovered_audio=${APO_DISCOVERY[AUDIO_BASELINE]:-}

        # The retry exists only to recover the audio observation. Keep every
        # other field from the first internally consistent discovery capture.
        APO_DISCOVERY=()
        for key in "${!initial_discovery[@]}"; do
            APO_DISCOVERY[$key]=${initial_discovery[$key]}
        done
        if [[ -n $discovered_audio ]]; then
            APO_DISCOVERY[AUDIO_BASELINE]=$discovered_audio
            apo_event discovery-audio-retry PASS '' \
                "Graphical audio became available on read-only discovery attempt $attempt/$APO_GRAPHICAL_AUDIO_DISCOVERY_ATTEMPTS."
            return 0
        fi
    done
    return 0
}

apo_store_discovery_state() {
    local key
    apo_state_set PROFILE "$APO_PROFILE"
    apo_state_set MODE_EFFECTIVE "$APO_MODE_EFFECTIVE"
    apo_state_set BOOT_CONFIG "$APO_BOOT_CONFIG"
    apo_state_set TRYBOOT_CONFIG "$APO_TRYBOOT_CONFIG"
    apo_state_set INITIAL_TRYBOOT_EXISTS "$APO_INITIAL_TRYBOOT_EXISTS"
    apo_state_set INITIAL_TRYBOOT_TYPE "$APO_INITIAL_TRYBOOT_TYPE"
    apo_state_set INITIAL_TRYBOOT_HASH "$APO_INITIAL_TRYBOOT_HASH"
    apo_state_set BOOT_MOUNT "$APO_BOOT_MOUNT"
    apo_state_set GPU_KEY "$APO_GPU_KEY"
    apo_state_set NORMAL_CPU "$APO_NORMAL_CPU"
    apo_state_set NORMAL_GPU "$APO_NORMAL_GPU"
    apo_state_set NORMAL_VOLTAGE "$APO_NORMAL_VOLTAGE"
    apo_state_set PERMANENT_TUNING_PROVENANCE "$APO_PERMANENT_TUNING_PROVENANCE"
    apo_state_set PERMANENT_TUNING_EVIDENCE "$APO_PERMANENT_TUNING_EVIDENCE"
    apo_state_set AUTO_BASELINE_CPU "$APO_AUTO_BASELINE_CPU"
    apo_state_set AUTO_BASELINE_GPU "$APO_AUTO_BASELINE_GPU"
    apo_state_set AUTO_BASELINE_VOLTAGE "$APO_AUTO_BASELINE_VOLTAGE"
    apo_state_set AUTO_BASELINE_PROVENANCE "$APO_AUTO_BASELINE_PROVENANCE"
    apo_state_set AUTO_BASELINE_EVIDENCE "$APO_AUTO_BASELINE_EVIDENCE"
    apo_state_set SOURCE_APPLIED_RUN_ID "${APO_SOURCE_APPLIED_RUN_ID:-}"
    apo_state_set SOURCE_APPLIED_PERMANENT_HASH "${APO_SOURCE_APPLIED_PERMANENT_HASH:-}"
    apo_state_set SOURCE_APPLIED_LIVE_HASH "${APO_SOURCE_APPLIED_LIVE_HASH:-}"
    apo_state_set SOURCE_APPLIED_HASH_RELATION "${APO_SOURCE_APPLIED_HASH_RELATION:-}"
    apo_state_set SOURCE_APPLIED_HASH_EVIDENCE "${APO_SOURCE_APPLIED_HASH_EVIDENCE:-}"
    apo_state_set SOURCE_APPLIED_CPU "${APO_SOURCE_APPLIED_CPU:-}"
    apo_state_set SOURCE_APPLIED_GPU "${APO_SOURCE_APPLIED_GPU:-}"
    apo_state_set SOURCE_APPLIED_VOLTAGE "${APO_SOURCE_APPLIED_VOLTAGE:-}"
    apo_state_set SOURCE_APPLIED_PROFILE "${APO_SOURCE_APPLIED_PROFILE:-}"
    apo_state_set SOURCE_APPLIED_BOOT_CONFIG "${APO_SOURCE_APPLIED_BOOT_CONFIG:-}"
    apo_state_set SOURCE_APPLIED_TRYBOOT_CONFIG "${APO_SOURCE_APPLIED_TRYBOOT_CONFIG:-}"
    apo_state_set SOURCE_APPLIED_GPU_KEY "${APO_SOURCE_APPLIED_GPU_KEY:-}"
    apo_state_set SOURCE_AUTO_BASELINE_CPU "${APO_SOURCE_AUTO_BASELINE_CPU:-}"
    apo_state_set SOURCE_AUTO_BASELINE_GPU "${APO_SOURCE_AUTO_BASELINE_GPU:-}"
    apo_state_set SOURCE_AUTO_BASELINE_VOLTAGE "${APO_SOURCE_AUTO_BASELINE_VOLTAGE:-}"
    apo_state_set SOURCE_AUTO_BASELINE_PROVENANCE "${APO_SOURCE_AUTO_BASELINE_PROVENANCE:-}"
    apo_state_set SOURCE_AUTO_BASELINE_EVIDENCE "${APO_SOURCE_AUTO_BASELINE_EVIDENCE:-}"
    apo_state_set TEST_VOLTAGE "$APO_TEST_VOLTAGE"
    apo_state_set PERMANENT_HASH "$APO_PERMANENT_CONFIG_HASH"
    apo_state_set THROTTLE_BASELINE "$APO_THROTTLE_BASELINE"
    apo_state_set THROTTLE_RUNTIME_BASELINE "$APO_THROTTLE_RUNTIME_BASELINE"
    apo_state_set THROTTLE_RECENT_SUPPORTED "$APO_THROTTLE_RECENT_SUPPORTED"
    apo_state_set DISPLAY_BASELINE "$APO_DISPLAY_BASELINE"
    apo_state_set AUDIO_BASELINE "$APO_AUDIO_BASELINE"
    apo_state_set STORAGE_LAYOUT "$APO_STORAGE_LAYOUT"
    apo_state_set REQUIRE_GPU_STRESS "$APO_REQUIRE_GPU_STRESS"
    for key in MODEL COMPATIBLE ARCH OS_ID OS_VERSION NORMAL_VOLTAGE_SOURCE PERMANENT_TUNING_PROVENANCE PERMANENT_TUNING_EVIDENCE TRYBOOT_EXISTS TRYBOOT_TYPE TRYBOOT_HASH BOOT_WATCHDOG_TIMEOUT KERNEL_WATCHDOG_TIMEOUT RUNTIME_WATCHDOG WATCHDOG_DEVICE WATCHDOG_RUNTIME_TIMEOUT WATCHDOG_OWNER ROOT_SOURCE BOOT_SOURCE DISPLAY_PRESENT AUDIO_BASELINE CPU_STRESS_AVAILABLE GPU_STRESS_AVAILABLE STRESS_NG_BINARY STRESS_NG_GPU_AVAILABLE STRESS_NG_GPU_STRATEGY DRM_RENDER_NODE OPENSSL_BINARY GLMARK_BINARY GLMARK_WAYLAND_BINARY GLMARK_DRM_BINARY GLMARK_DATA RECENT_THROTTLED THROTTLE_RECENT_SUPPORTED; do
        apo_state_set "DISC_${key}" "${APO_DISCOVERY[$key]:-}"
    done
    apo_state_save
}

apo_domain_source_managed_clock_zero_mode() {
    local config_file=$1 expected_run=$2 expected_cpu=$3 expected_gpu=$4 expected_gpu_key=$5 expected_voltage=$6
    [[ -f $config_file && ! -L $config_file && -r $config_file ]] || return 1
    awk -v begin='# BEGIN AUTOPIOVERCLOCK MANAGED CLOCKS' \
        -v end='# END AUTOPIOVERCLOCK MANAGED CLOCKS' \
        -v run_line="# Run: $expected_run" \
        -v cpu_line="arm_freq=$expected_cpu" \
        -v gpu_line="$expected_gpu_key=$expected_gpu" \
        -v voltage_line="over_voltage_delta=$expected_voltage" \
        -v expected_voltage="$expected_voltage" '
        {
            semantic=$0
            sub(/\r$/, "", semantic)
            lower=tolower(semantic)
            if (index(lower, "autopioverclock managed clocks") && semantic != begin && semantic != end) invalid=1
            if (semantic == begin) {
                if (inside || blocks > 0) invalid=1
                inside=1
                blocks++
                next
            }
            if (semantic == end) {
                if (!inside) invalid=1
                inside=0
                next
            }
            if (inside) block[++block_lines]=semantic
        }
        END {
            if (invalid || inside || blocks != 1 || block_lines < 4 || block_lines > 5) exit 1
            line_number=1
            if (block[line_number++] != run_line || block[line_number++] != "[all]") exit 1
            zero_mode="absent"
            if (block[line_number] == voltage_line) {
                zero_mode="present"
                line_number++
            } else if (expected_voltage != "0") {
                exit 1
            }
            if (block[line_number++] != cpu_line || block[line_number++] != gpu_line || line_number != block_lines + 1) exit 1
            print zero_mode
        }
    ' "$config_file"
}

apo_domain_source_active_snapshot() {
    local config_file=$1 output_file=$2 drop_project_zero=${3:-0}
    awk -v begin='# BEGIN AUTOPIOVERCLOCK MANAGED CLOCKS' \
        -v end='# END AUTOPIOVERCLOCK MANAGED CLOCKS' \
        -v drop_project_zero="$drop_project_zero" '
        {
            semantic=$0
            sub(/\r$/, "", semantic)
            if (semantic == begin) { inside=1; next }
            if (semantic == end) { inside=0; next }
            trimmed=semantic
            sub(/^[[:space:]]*/, "", trimmed)
            if (trimmed == "" || substr(trimmed, 1, 1) == "#") next
            if (drop_project_zero == 1 && inside && semantic == "over_voltage_delta=0") next
            print semantic
        }
    ' "$config_file" > "$output_file"
}

apo_reconcile_domain_sweep_source_hash() {
    local source_state=${APO_DOMAIN_SOURCE_STATE:-} source_artifact live_snapshot source_hash live_hash
    local source_zero_mode live_zero_mode source_active live_active source_without_zero
    local -a cleanup_files=()
    APO_SOURCE_APPLIED_LIVE_HASH=$APO_PERMANENT_CONFIG_HASH
    if [[ $APO_PERMANENT_CONFIG_HASH == "${APO_SOURCE_APPLIED_PERMANENT_HASH:-}" ]]; then
        APO_SOURCE_APPLIED_HASH_RELATION=exact
        APO_SOURCE_APPLIED_HASH_EVIDENCE=live-hash-equals-retained-applied-hash
        return 0
    fi

    [[ -n $source_state && $source_state == *.state && -f $source_state && ! -L $source_state ]] ||
        apo_die 'The retained applied source state is unavailable for strict permanent-config reconciliation.' "$APO_EXIT_RECOVERY"
    source_artifact="${source_state%.state}-apply-proposed-config.txt"
    [[ -f $source_artifact && ! -L $source_artifact && -r $source_artifact ]] ||
        apo_die 'The retained applied source config artifact is unavailable; permanent-config drift cannot be reconciled safely.' "$APO_EXIT_RECOVERY"
    source_hash=$(sha256sum "$source_artifact" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    [[ $source_hash == "$APO_SOURCE_APPLIED_PERMANENT_HASH" ]] ||
        apo_die 'The retained applied source config artifact no longer matches its recorded hash.' "$APO_EXIT_RECOVERY"

    [[ -n ${APO_RUN_PREFIX:-} ]] || apo_die 'Applied-source reconciliation is missing its run artifact prefix.' "$APO_EXIT_INTERNAL"
    live_snapshot="${APO_RUN_PREFIX}-source-live-config.txt"
    apo_remote_root_read_file "$live_snapshot" "cat $(apo_sh_quote "$APO_BOOT_CONFIG")" ||
        apo_die 'The live permanent config could not be captured for strict applied-source reconciliation.' "$APO_EXIT_RECOVERY"
    chmod 600 "$live_snapshot"
    live_hash=$(sha256sum "$live_snapshot" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    [[ $live_hash == "$APO_PERMANENT_CONFIG_HASH" ]] ||
        apo_die 'The live permanent config changed between discovery and applied-source reconciliation.' "$APO_EXIT_RECOVERY"

    source_zero_mode=$(apo_domain_source_managed_clock_zero_mode "$source_artifact" \
        "$APO_SOURCE_APPLIED_RUN_ID" "$APO_SOURCE_APPLIED_CPU" "$APO_SOURCE_APPLIED_GPU" \
        "$APO_SOURCE_APPLIED_GPU_KEY" "$APO_SOURCE_APPLIED_VOLTAGE" || true)
    live_zero_mode=$(apo_domain_source_managed_clock_zero_mode "$live_snapshot" \
        "$APO_SOURCE_APPLIED_RUN_ID" "$APO_SOURCE_APPLIED_CPU" "$APO_SOURCE_APPLIED_GPU" \
        "$APO_SOURCE_APPLIED_GPU_KEY" "$APO_SOURCE_APPLIED_VOLTAGE" || true)
    [[ $source_zero_mode == present || $source_zero_mode == absent ]] ||
        apo_die 'The retained applied source contains malformed or mismatched AutoPiOverclock clock markers.' "$APO_EXIT_RECOVERY"
    [[ $live_zero_mode == present || $live_zero_mode == absent ]] ||
        apo_die 'The live permanent config contains malformed or mismatched AutoPiOverclock clock markers.' "$APO_EXIT_RECOVERY"

    source_active=$(mktemp "${APO_RUN_PREFIX}-source-active.XXXXXX") ||
        apo_die 'Could not create a local applied-source reconciliation file.' "$APO_EXIT_INTERNAL"
    live_active=$(mktemp "${APO_RUN_PREFIX}-live-active.XXXXXX") || {
        rm -f -- "$source_active"
        apo_die 'Could not create a local live-config reconciliation file.' "$APO_EXIT_INTERNAL"
    }
    source_without_zero=$(mktemp "${APO_RUN_PREFIX}-source-no-zero.XXXXXX") || {
        rm -f -- "$source_active" "$live_active"
        apo_die 'Could not create a local zero-normalized reconciliation file.' "$APO_EXIT_INTERNAL"
    }
    cleanup_files=("$source_active" "$live_active" "$source_without_zero")
    apo_domain_source_active_snapshot "$source_artifact" "$source_active" 0 &&
        apo_domain_source_active_snapshot "$live_snapshot" "$live_active" 0 &&
        apo_domain_source_active_snapshot "$source_artifact" "$source_without_zero" 1 || {
            rm -f -- "${cleanup_files[@]}"
            apo_die 'Could not derive strict active-line evidence for applied-source reconciliation.' "$APO_EXIT_RECOVERY"
        }

    if cmp -s -- "$source_active" "$live_active"; then
        APO_SOURCE_APPLIED_HASH_RELATION=comment-only
        APO_SOURCE_APPLIED_HASH_EVIDENCE=source-artifact-hash-and-managed-block-verified-active-lines-identical
    elif [[ $APO_SOURCE_APPLIED_VOLTAGE == 0 && $APO_NORMAL_VOLTAGE == 0 &&
            $source_zero_mode == present && $live_zero_mode == absent ]] &&
         cmp -s -- "$source_without_zero" "$live_active"; then
        APO_SOURCE_APPLIED_HASH_RELATION=comment-only-project-zero-removed
        APO_SOURCE_APPLIED_HASH_EVIDENCE=source-artifact-hash-and-managed-block-verified-active-lines-identical-after-project-zero-removal
    else
        rm -f -- "${cleanup_files[@]}"
        apo_die 'The live permanent config has active drift beyond a strictly verified comment-only change.' "$APO_EXIT_RECOVERY"
    fi
    rm -f -- "${cleanup_files[@]}"
}

apo_verify_domain_sweep_source_discovery() {
    [[ ${APO_SWEEP_DOMAIN:-all} != all ]] || return 0
    apo_is_safe_run_id "${APO_SOURCE_APPLIED_RUN_ID:-}" ||
        apo_die 'Domain-only tuning is missing a valid retained applied-source run ID.' "$APO_EXIT_INTERNAL"
    [[ ${APO_SOURCE_APPLIED_PERMANENT_HASH:-} =~ ^[0-9a-f]{64}$ ]] ||
        apo_die 'Domain-only tuning is missing a valid retained applied-source hash.' "$APO_EXIT_INTERNAL"
    [[ $APO_NORMAL_CPU == "${APO_SOURCE_APPLIED_CPU:-}" &&
       $APO_NORMAL_GPU == "${APO_SOURCE_APPLIED_GPU:-}" &&
       $APO_NORMAL_VOLTAGE == "${APO_SOURCE_APPLIED_VOLTAGE:-}" ]] ||
        apo_die "The live clock tuple (${APO_NORMAL_CPU}/${APO_NORMAL_GPU}/${APO_NORMAL_VOLTAGE}) does not match the retained applied tuple (${APO_SOURCE_APPLIED_CPU:-missing}/${APO_SOURCE_APPLIED_GPU:-missing}/${APO_SOURCE_APPLIED_VOLTAGE:-missing})." "$APO_EXIT_RECOVERY"
    [[ $APO_PROFILE == "${APO_SOURCE_APPLIED_PROFILE:-}" &&
       $APO_BOOT_CONFIG == "${APO_SOURCE_APPLIED_BOOT_CONFIG:-}" &&
       $APO_TRYBOOT_CONFIG == "${APO_SOURCE_APPLIED_TRYBOOT_CONFIG:-}" &&
       $APO_GPU_KEY == "${APO_SOURCE_APPLIED_GPU_KEY:-}" ]] ||
        apo_die 'Live profile or boot-path discovery does not match the retained applied source selected for domain-only tuning.' "$APO_EXIT_RECOVERY"
    apo_config_stock_auto_baseline_ready "${APO_SOURCE_AUTO_BASELINE_CPU:-}" "${APO_SOURCE_AUTO_BASELINE_GPU:-}" \
        "${APO_SOURCE_AUTO_BASELINE_VOLTAGE:-}" "${APO_SOURCE_AUTO_BASELINE_PROVENANCE:-}" \
        "${APO_SOURCE_AUTO_BASELINE_EVIDENCE:-}" ||
        apo_die 'The retained applied source has lost its verified stock-baseline lineage.' "$APO_EXIT_INTERNAL"
    apo_reconcile_domain_sweep_source_hash
}

apo_context_from_discovery() {
    local audio_attempt_suffix=''
    APO_BOOT_CONFIG=${APO_DISCOVERY[BOOT_CONFIG]:-}
    APO_TRYBOOT_CONFIG=${APO_DISCOVERY[TRYBOOT_CONFIG]:-}
    APO_INITIAL_TRYBOOT_EXISTS=${APO_DISCOVERY[TRYBOOT_EXISTS]:-}
    APO_INITIAL_TRYBOOT_TYPE=${APO_DISCOVERY[TRYBOOT_TYPE]:-}
    APO_INITIAL_TRYBOOT_HASH=${APO_DISCOVERY[TRYBOOT_HASH]:-}
    APO_BOOT_MOUNT=${APO_DISCOVERY[BOOT_MOUNT]:-}
    APO_GPU_KEY=${APO_DISCOVERY[GPU_KEY]:-}
    APO_NORMAL_CPU=${APO_DISCOVERY[NORMAL_CPU]:-}
    APO_NORMAL_GPU=${APO_DISCOVERY[NORMAL_GPU]:-}
    APO_NORMAL_VOLTAGE=${APO_DISCOVERY[NORMAL_VOLTAGE]:-}
    APO_PERMANENT_TUNING_PROVENANCE=${APO_DISCOVERY[PERMANENT_TUNING_PROVENANCE]:-missing}
    APO_PERMANENT_TUNING_EVIDENCE=${APO_DISCOVERY[PERMANENT_TUNING_EVIDENCE]:-missing}
    APO_PERMANENT_CONFIG_HASH=${APO_DISCOVERY[PERMANENT_HASH]:-}
    APO_DISPLAY_BASELINE=${APO_DISCOVERY[DISPLAY_BASELINE]:-}
    APO_AUDIO_BASELINE=${APO_DISCOVERY[AUDIO_BASELINE]:-}
    APO_STORAGE_LAYOUT=${APO_DISCOVERY[STORAGE_LAYOUT]:-}
    if [[ ${APO_CFG[VOLTAGE_DELTA_UV]} == existing ]]; then APO_TEST_VOLTAGE=$APO_NORMAL_VOLTAGE; else APO_TEST_VOLTAGE=${APO_CFG[VOLTAGE_DELTA_UV]}; fi
    [[ -n $APO_BOOT_CONFIG && -n $APO_TRYBOOT_CONFIG && -n $APO_GPU_KEY && -n $APO_NORMAL_CPU && -n $APO_NORMAL_GPU && -n $APO_NORMAL_VOLTAGE && -n $APO_PERMANENT_CONFIG_HASH ]] || apo_die 'Discovery omitted required boot/configuration fields.' "$APO_EXIT_PREFLIGHT"
    [[ $APO_GPU_KEY == gpu_freq || $APO_GPU_KEY == v3d_freq ]] || apo_die "Discovery returned an unsupported GPU key: $APO_GPU_KEY" "$APO_EXIT_PREFLIGHT"
    [[ $APO_INITIAL_TRYBOOT_EXISTS == 0 || $APO_INITIAL_TRYBOOT_EXISTS == 1 ]] || apo_die 'Discovery returned malformed tryboot-file existence evidence.' "$APO_EXIT_PREFLIGHT"
    if [[ $APO_INITIAL_TRYBOOT_EXISTS == 0 ]]; then
        [[ $APO_INITIAL_TRYBOOT_TYPE == absent && $APO_INITIAL_TRYBOOT_HASH == unavailable ]] ||
            apo_die 'Discovery returned inconsistent evidence for an absent tryboot path.' "$APO_EXIT_PREFLIGHT"
    else
        case $APO_INITIAL_TRYBOOT_TYPE in
            regular) [[ $APO_INITIAL_TRYBOOT_HASH =~ ^[0-9a-f]{64}$ ]] || apo_die 'Discovery could not hash the existing regular tryboot file.' "$APO_EXIT_PREFLIGHT" ;;
            symlink|directory|other) [[ $APO_INITIAL_TRYBOOT_HASH == unavailable ]] || apo_die 'Discovery returned inconsistent hash evidence for a non-regular tryboot path.' "$APO_EXIT_PREFLIGHT" ;;
            *) apo_die "Discovery returned an unsupported tryboot path type: ${APO_INITIAL_TRYBOOT_TYPE:-missing}" "$APO_EXIT_PREFLIGHT" ;;
        esac
    fi
    if [[ $APO_COMMAND =~ ^(run|prepare)$ && $APO_DRY_RUN == 0 && $APO_INITIAL_TRYBOOT_EXISTS == 1 ]]; then
        apo_die "An existing tryboot path is present at $APO_TRYBOOT_CONFIG (type $APO_INITIAL_TRYBOOT_TYPE, hash $APO_INITIAL_TRYBOOT_HASH). AutoPiOverclock will not overwrite it. If it is project-owned recovery evidence, run autopioverclock reset ${APO_RAW_TARGET}; otherwise inspect it manually." "$APO_EXIT_PREFLIGHT"
    fi
    [[ $APO_NORMAL_CPU =~ ^[1-9][0-9]{0,8}$ ]] || apo_die "Discovery returned an invalid normal CPU clock: $APO_NORMAL_CPU" "$APO_EXIT_PREFLIGHT"
    [[ $APO_NORMAL_GPU =~ ^[1-9][0-9]{0,8}$ ]] || apo_die "Discovery returned an invalid normal GPU clock: $APO_NORMAL_GPU" "$APO_EXIT_PREFLIGHT"
    apo_is_int "$APO_NORMAL_VOLTAGE" || apo_die "Discovery returned an invalid normal voltage delta: $APO_NORMAL_VOLTAGE" "$APO_EXIT_PREFLIGHT"
    [[ $APO_PERMANENT_CONFIG_HASH =~ ^[0-9a-f]{64}$ ]] || apo_die 'Discovery returned an invalid permanent-config hash.' "$APO_EXIT_PREFLIGHT"
    apo_verify_domain_sweep_source_discovery
    apo_config_resolve_auto_candidates "$APO_NORMAL_CPU" "$APO_NORMAL_GPU" "$APO_NORMAL_VOLTAGE" "$APO_PERMANENT_TUNING_PROVENANCE" "$APO_PERMANENT_TUNING_EVIDENCE"
    if (( APO_AUTO_GENERATED_CANDIDATES == 1 )); then
        if [[ ${APO_SWEEP_DOMAIN:-all} == all ]]; then
            APO_AUTO_BASELINE_CPU=$APO_NORMAL_CPU
            APO_AUTO_BASELINE_GPU=$APO_NORMAL_GPU
            APO_AUTO_BASELINE_VOLTAGE=$APO_NORMAL_VOLTAGE
            APO_AUTO_BASELINE_PROVENANCE=$APO_PERMANENT_TUNING_PROVENANCE
            APO_AUTO_BASELINE_EVIDENCE=$APO_PERMANENT_TUNING_EVIDENCE
        else
            APO_AUTO_BASELINE_CPU=$APO_SOURCE_AUTO_BASELINE_CPU
            APO_AUTO_BASELINE_GPU=$APO_SOURCE_AUTO_BASELINE_GPU
            APO_AUTO_BASELINE_VOLTAGE=$APO_SOURCE_AUTO_BASELINE_VOLTAGE
            APO_AUTO_BASELINE_PROVENANCE=$APO_SOURCE_AUTO_BASELINE_PROVENANCE
            APO_AUTO_BASELINE_EVIDENCE=$APO_SOURCE_AUTO_BASELINE_EVIDENCE
        fi
    else
        APO_AUTO_BASELINE_CPU=''
        APO_AUTO_BASELINE_GPU=''
        APO_AUTO_BASELINE_VOLTAGE=''
        APO_AUTO_BASELINE_PROVENANCE=''
        APO_AUTO_BASELINE_EVIDENCE=''
    fi
    local candidate
    if (( ${APO_MANUAL_TEST:-0} == 1 )); then
        (( APO_MANUAL_CPU >= APO_NORMAL_CPU )) ||
            apo_die "Manual CPU clock $APO_MANUAL_CPU MHz is below the protected normal clock $APO_NORMAL_CPU MHz; test accepts a normal-or-higher clock, not an underclock." "$APO_EXIT_USAGE"
        (( APO_MANUAL_GPU >= APO_NORMAL_GPU )) ||
            apo_die "Manual GPU/V3D clock $APO_MANUAL_GPU MHz is below the protected normal clock $APO_NORMAL_GPU MHz; test accepts a normal-or-higher clock, not an underclock." "$APO_EXIT_USAGE"
        (( APO_MANUAL_CPU > APO_NORMAL_CPU || APO_MANUAL_GPU > APO_NORMAL_GPU )) ||
            apo_die 'Manual test clocks exactly match the protected normal clocks; raise at least one clock to test an overclock.' "$APO_EXIT_USAGE"
    else
        for candidate in "${APO_CPU_CANDIDATES[@]}"; do
            (( candidate > APO_NORMAL_CPU )) || apo_die "CPU candidate $candidate MHz is not above the discovered normal clock $APO_NORMAL_CPU MHz. The normal-clock tryboot proof is automatic; tuning candidates must be fresh overclocks." "$APO_EXIT_USAGE"
        done
        for candidate in "${APO_GPU_CANDIDATES[@]}"; do
            (( candidate > APO_NORMAL_GPU )) || apo_die "GPU/V3D candidate $candidate MHz is not above the discovered normal clock $APO_NORMAL_GPU MHz. The normal-clock tryboot proof is automatic; tuning candidates must be fresh overclocks." "$APO_EXIT_USAGE"
        done
    fi
    if [[ $APO_MODE_EFFECTIVE == graphical && -z $APO_AUDIO_BASELINE ]]; then
        if (( APO_AUDIO_DISCOVERY_ATTEMPTS_USED > 1 )); then
            audio_attempt_suffix=" after $APO_AUDIO_DISCOVERY_ATTEMPTS_USED read-only discovery attempts"
        fi
        case $APO_PROFILE in
            debian) apo_die "Debian graphical mode requires a healthy audio-output baseline, but neither a default PipeWire/PulseAudio sink nor ALSA playback hardware could be captured${audio_attempt_suffix}." "$APO_EXIT_HARNESS" ;;
            batocera) apo_die "Batocera graphical mode requires a healthy default audio-sink baseline, but none could be captured${audio_attempt_suffix}." "$APO_EXIT_HARNESS" ;;
            *) apo_die "Graphical mode requires a healthy audio-output baseline, but none could be captured${audio_attempt_suffix}." "$APO_EXIT_HARNESS" ;;
        esac
    fi
}

apo_dependency_description() {
    case $APO_PROFILE in
        debian)
            printf 'stress-ng=%s; stress-ng-gpu=%s; gpu-strategy=%s; drm-render-node=%s' \
                "${APO_DISCOVERY[STRESS_NG_BINARY]:-missing}" \
                "$([[ ${APO_DISCOVERY[STRESS_NG_GPU_AVAILABLE]:-0} == 1 ]] && printf ready || printf missing)" \
                "${APO_DISCOVERY[STRESS_NG_GPU_STRATEGY]:-missing}" \
                "${APO_DISCOVERY[DRM_RENDER_NODE]:-missing}"
            ;;
        batocera)
            local glmark_binary
            case ${APO_MODE_EFFECTIVE:-} in
                graphical) glmark_binary=${APO_DISCOVERY[GLMARK_WAYLAND_BINARY]:-missing} ;;
                headless) glmark_binary=${APO_DISCOVERY[GLMARK_DRM_BINARY]:-missing} ;;
                *) glmark_binary=missing ;;
            esac
            printf 'openssl=%s; glmark-binary=%s; glmark-data=%s' \
                "${APO_DISCOVERY[OPENSSL_BINARY]:-missing}" \
                "$glmark_binary" \
                "${APO_DISCOVERY[GLMARK_DATA]:-missing}"
            ;;
        *) printf 'profile dependency evidence unavailable' ;;
    esac
}

apo_dependency_preflight() {
    local dependency_detail baseline_hash current_boot_id install_rc attempt
    dependency_detail=$(apo_dependency_description)
    if apo_profile_dependencies_ready; then
        apo_summary_line "Dependencies: READY ($dependency_detail)"
        return 0
    fi
    if (( APO_DRY_RUN == 1 )); then
        apo_warn 'Required stress dependencies are not ready; dry-run remains read-only.'
        apo_summary_line "Dependencies: NOT READY ($dependency_detail; dry-run did not modify target)"
        return 0
    fi
    (( APO_INSTALL_MISSING == 1 )) || apo_die "Required stress dependencies are missing. Run autopioverclock prepare ${APO_RAW_TARGET} first." "$APO_EXIT_PREFLIGHT"
    apo_reset_throttle_history dependency-staging-baseline || apo_die "$APO_LAST_REASON" "$APO_EXIT_PREFLIGHT"
    baseline_hash=$APO_PERMANENT_CONFIG_HASH
    # Debian package installation and the Batocera bundle transaction are
    # intentionally idempotent. If their SSH result is lost, reconcile the
    # live target first; accept a proved installation, or repeat the same
    # bounded operation up to five times. Protected-config drift still stops
    # immediately and is never retried away.
    for (( attempt=1; attempt<=5; attempt++ )); do
        install_rc=0
        apo_profile_install_dependencies || install_rc=$?
        apo_wait_for_ssh "$APO_PREFLIGHT_SSH_TIMEOUT_SECONDS" dependency-reconcile || {
            (( attempt < 5 )) || apo_die 'Dependency installation could not be reconciled because SSH remained unavailable.' "$APO_EXIT_PREFLIGHT"
            apo_event dependency-install-retry WARN HARNESS_FAILURE "Dependency staging lost SSH before reconciliation; retrying the same idempotent installation (attempt $((attempt + 1))/5)."
            apo_transient_read_delay
            continue
        }
        current_boot_id=$(apo_remote_boot_id || true)
        [[ -n $current_boot_id ]] || {
            (( attempt < 5 )) || apo_die 'Dependency installation could not be reconciled because the boot identity remained unreadable.' "$APO_EXIT_PREFLIGHT"
            apo_event dependency-install-retry WARN HARNESS_FAILURE "Dependency staging returned without a readable boot identity; retrying the same idempotent installation (attempt $((attempt + 1))/5)."
            apo_transient_read_delay
            continue
        }
        apo_ensure_worker_for_boot "$current_boot_id" dependency-reconcile || {
            (( attempt < 5 )) || apo_die "Dependency installation returned, but its run-isolated worker could not be restored: $APO_LAST_REASON" "$APO_EXIT_HARNESS"
            apo_event dependency-install-retry WARN HARNESS_FAILURE "Dependency staging returned but worker restoration was incomplete; retrying the same idempotent installation (attempt $((attempt + 1))/5)."
            apo_transient_read_delay
            continue
        }
        apo_discovery_capture
        [[ ${APO_DISCOVERY[PERMANENT_HASH]:-} == "$baseline_hash" ]] || apo_die 'Permanent config changed during dependency staging; refusing to replace the protected baseline hash.' "$APO_EXIT_RECOVERY"
        apo_throttle_clean_relative "${APO_DISCOVERY[RECENT_THROTTLED]:-}" "$APO_THROTTLE_RUNTIME_BASELINE" || apo_die "A current or new throttle condition appeared during dependency staging: ${APO_DISCOVERY[RECENT_THROTTLED]:-missing}" "$APO_EXIT_PREFLIGHT"
        apo_context_from_discovery
        if apo_profile_dependencies_ready; then break; fi
        (( attempt < 5 )) || apo_die 'Dependencies are still unavailable after five reconciled installation attempts.' "$APO_EXIT_PREFLIGHT"
        apo_event dependency-install-retry WARN HARNESS_FAILURE "Dependency staging did not yet prove the required workload after attempt $attempt/5 (worker rc=$install_rc); retrying automatically."
        apo_transient_read_delay
    done
    dependency_detail=$(apo_dependency_description)
    apo_summary_line "Dependencies: READY after approved staging ($dependency_detail)"
}

apo_watchdog_preflight() {
    local expected_repair_hash repair_class repair_reason
    if apo_profile_watchdogs_ready; then
        apo_summary_line "Watchdogs: READY ($(apo_profile_watchdog_description))"
        return 0
    fi
    apo_summary_line "Watchdogs: NOT READY ($(apo_profile_watchdog_description))"
    if (( APO_DRY_RUN == 1 )); then return 0; fi
    (( APO_REPAIR_WATCHDOGS == 1 )) || apo_die "The tryboot/watchdog recovery chain is not ready. Run autopioverclock prepare ${APO_RAW_TARGET} first." "$APO_EXIT_PREFLIGHT"
    # Persist the complete, still-unmodified target context before the separately
    # confirmed repair path plans or changes any permanent target file.
    apo_store_discovery_state
    apo_reset_throttle_history watchdog-remediation-baseline || apo_die "$APO_LAST_REASON" "$APO_EXIT_PREFLIGHT"
    if ! apo_profile_repair_watchdogs; then
        repair_class=${APO_LAST_CLASS:-PREFLIGHT_FAILURE}
        repair_reason=${APO_LAST_REASON:-'Watchdog remediation failed or was refused.'}
        case $repair_class in
            PREFLIGHT_FAILURE|HARNESS_FAILURE|RECOVERY_FAILURE) ;;
            *) repair_class=PREFLIGHT_FAILURE ;;
        esac
        apo_die "$repair_reason" "$(apo_class_exit_code "$repair_class")"
    fi
    expected_repair_hash=$(apo_state_get WATCHDOG_REPAIR_EXPECTED_HASH '')
    apo_discovery_capture
    if [[ ! $expected_repair_hash =~ ^[0-9a-f]{64}$ || ${APO_DISCOVERY[PERMANENT_HASH]:-} != "$expected_repair_hash" ]]; then
        apo_state_set WATCHDOG_REPAIR_STATUS HASH_MISMATCH
        apo_state_save
        apo_die "Watchdog remediation returned with an unrecognized permanent-config hash (expected ${expected_repair_hash:-missing}, found ${APO_DISCOVERY[PERMANENT_HASH]:-missing})." "$APO_EXIT_RECOVERY"
    fi
    apo_throttle_clean_relative "${APO_DISCOVERY[RECENT_THROTTLED]:-}" "$APO_THROTTLE_RUNTIME_BASELINE" || apo_die "A current or new throttle condition appeared during watchdog remediation: ${APO_DISCOVERY[RECENT_THROTTLED]:-missing}" "$APO_EXIT_PREFLIGHT"
    apo_context_from_discovery
    apo_profile_watchdogs_ready || apo_die 'Watchdogs remain unready after remediation.' "$APO_EXIT_PREFLIGHT"
    apo_state_set WATCHDOG_REPAIR_STATUS VERIFIED
    apo_state_set WATCHDOG_REPAIR_NEW_HASH "$expected_repair_hash"
    apo_state_set SUBPHASE WATCHDOG_REPAIR_VERIFIED
    apo_state_save
}

apo_finalize_discovered_config() {
    APO_NEED_GPU=$(( ${#APO_GPU_CANDIDATES[@]} > 0 ? 1 : 0 ))
    if (( APO_NEED_GPU == 1 )) || [[ $APO_MODE_EFFECTIVE == graphical || ${APO_SWEEP_DOMAIN:-all} != all ]]; then APO_REQUIRE_GPU_STRESS=1; else APO_REQUIRE_GPU_STRESS=0; fi
    apo_config_store_in_state
    apo_state_save
    apo_write_effective_config "$APO_EFFECTIVE_CONFIG_FILE"
    apo_summary_line "CPU candidates: ${APO_CFG[CPU_CANDIDATES]:-none}"
    apo_summary_line "GPU candidates: ${APO_CFG[GPU_CANDIDATES]:-none}"
}

apo_prepare_target() {
    apo_ssh_preflight
    APO_PROFILE=$(apo_probe_profile)
    apo_load_profile "$APO_PROFILE"
    if (( APO_DRY_RUN == 0 )); then apo_deploy_worker; fi
    APO_HAVE_REMOTE_CONTEXT=1
    apo_normalize_initial_boot
    apo_discovery_capture
    [[ ${APO_DISCOVERY[PROFILE]:-} == "$APO_PROFILE" ]] || apo_die 'Profile probe and worker discovery disagree.' "$APO_EXIT_PREFLIGHT"
    apo_validate_pi5
    apo_choose_mode
    apo_retry_graphical_audio_baseline
    apo_context_from_discovery
    apo_finalize_discovered_config
    local throttle=${APO_DISCOVERY[THROTTLED]:-} temp=${APO_DISCOVERY[TEMP]:-} baseline_boot_id audio_summary
    apo_throttle_reading_valid "$throttle" || apo_die "Power/throttle telemetry is malformed: ${throttle:-missing}" "$APO_EXIT_PREFLIGHT"
    apo_throttle_active_bits_clear "$throttle" || apo_die "Current power/throttle conditions are active at preflight: $throttle" "$APO_EXIT_PREFLIGHT"
    APO_THROTTLE_BASELINE=$throttle
    APO_THROTTLE_RECENT_SUPPORTED=${APO_DISCOVERY[THROTTLE_RECENT_SUPPORTED]:-0}
    if [[ $APO_COMMAND == run && $APO_DRY_RUN == 0 && $APO_THROTTLE_RECENT_SUPPORTED != 1 ]]; then
        apo_die 'This target cannot query/reset recent throttle history separately from permanent sticky bits; mutating tuning is refused.' "$APO_EXIT_PREFLIGHT"
    fi
    baseline_boot_id=$(apo_remote_boot_id || true)
    [[ -n $baseline_boot_id ]] || apo_die 'Could not record the normal baseline boot ID.' "$APO_EXIT_PREFLIGHT"
    apo_state_set BASELINE_BOOT_ID "$baseline_boot_id"
    apo_state_set LAST_BOOT_ID "$baseline_boot_id"
    apo_state_set NORMAL_BOOT_ID "$baseline_boot_id"
    apo_state_save
    [[ -n $temp ]] || apo_die 'Temperature telemetry is unavailable.' "$APO_EXIT_PREFLIGHT"
    awk -v t="$temp" -v m="${APO_CFG[MAX_TEMP_C]}" 'BEGIN{exit !(t<m)}' || apo_die "Starting temperature ${temp}C is not below ${APO_CFG[MAX_TEMP_C]}C." "$APO_EXIT_PREFLIGHT"
    apo_dependency_preflight
    apo_watchdog_preflight
    apo_store_discovery_state
    audio_summary=${APO_AUDIO_BASELINE:-not-captured}
    {
        printf 'Profile=%s\nMode=%s\nModel=%s\nOS=%s %s\nBootConfig=%s\nTrybootConfig=%s\nTrybootExists=%s\nTrybootType=%s\nTrybootHash=%s\nGPUKey=%s\nNormalCPU=%s\nNormalGPU=%s\nNormalVoltage=%s\nNormalVoltageSource=%s\nPermanentThrottleBaseline=%s\nRecentThrottle=%s\nRecentThrottleResetSupported=%s\nPermanentHash=%s\nStorage=%s\nDisplayBaseline=%s\nAudioBaseline=%s\n' \
            "$APO_PROFILE" "$APO_MODE_EFFECTIVE" "${APO_DISCOVERY[MODEL]:-}" "${APO_DISCOVERY[OS_ID]:-}" "${APO_DISCOVERY[OS_VERSION]:-}" \
            "$APO_BOOT_CONFIG" "$APO_TRYBOOT_CONFIG" "$APO_INITIAL_TRYBOOT_EXISTS" "$APO_INITIAL_TRYBOOT_TYPE" "$APO_INITIAL_TRYBOOT_HASH" "$APO_GPU_KEY" "$APO_NORMAL_CPU" "$APO_NORMAL_GPU" "$APO_NORMAL_VOLTAGE" "${APO_DISCOVERY[NORMAL_VOLTAGE_SOURCE]:-missing}" "$APO_THROTTLE_BASELINE" "${APO_DISCOVERY[RECENT_THROTTLED]:-}" "$APO_THROTTLE_RECENT_SUPPORTED" \
            "$APO_PERMANENT_CONFIG_HASH" "$APO_STORAGE_LAYOUT" "$APO_DISPLAY_BASELINE" "$audio_summary"
        printf 'CPUStressAvailable=%s\nGPUStressRequired=%s\nGPUStressAvailable=%s\nDependencyDetail=%s\n' \
            "${APO_DISCOVERY[CPU_STRESS_AVAILABLE]:-0}" "$APO_REQUIRE_GPU_STRESS" "${APO_DISCOVERY[GPU_STRESS_AVAILABLE]:-0}" "$(apo_dependency_description)"
        printf 'PermanentTuningProvenance=%s\nPermanentTuningEvidence=%s\n' \
            "$APO_PERMANENT_TUNING_PROVENANCE" "$APO_PERMANENT_TUNING_EVIDENCE"
        printf 'WatchdogEEPROMTimeout=%s\nWatchdogKernelHandoffTimeout=%s\nWatchdogDevice=%s\nWatchdogRuntimeTimeout=%s\nWatchdogOwner=%s\n' \
            "${APO_DISCOVERY[BOOT_WATCHDOG_TIMEOUT]:-}" "${APO_DISCOVERY[KERNEL_WATCHDOG_TIMEOUT]:-}" \
            "${APO_DISCOVERY[WATCHDOG_DEVICE]:-}" "${APO_DISCOVERY[WATCHDOG_RUNTIME_TIMEOUT]:-}" "${APO_DISCOVERY[WATCHDOG_OWNER]:-}"
    } > "$APO_DISCOVERY_FILE"
    chmod 600 "$APO_DISCOVERY_FILE"
    apo_summary_line "Target profile: $APO_PROFILE"
    apo_summary_line "Effective mode: $APO_MODE_EFFECTIVE"
    if [[ $APO_INITIAL_TRYBOOT_EXISTS == 1 ]]; then
        apo_summary_line "Existing tryboot path: PRESENT at $APO_TRYBOOT_CONFIG (type $APO_INITIAL_TRYBOOT_TYPE, hash $APO_INITIAL_TRYBOOT_HASH; live overwrite refused)"
    else
        apo_summary_line "Existing tryboot file: ABSENT at $APO_TRYBOOT_CONFIG"
    fi
    apo_summary_line "Normal clocks: CPU $APO_NORMAL_CPU MHz / V3D $APO_NORMAL_GPU MHz / voltage delta $APO_NORMAL_VOLTAGE uV (${APO_DISCOVERY[NORMAL_VOLTAGE_SOURCE]:-unknown source})"
    apo_summary_line "Permanent tuning provenance: $APO_PERMANENT_TUNING_PROVENANCE (${APO_PERMANENT_TUNING_EVIDENCE:-missing evidence})"
    apo_summary_line "Candidate voltage: $APO_TEST_VOLTAGE uV (configured as ${APO_CFG[VOLTAGE_DELTA_UV]})"
    apo_summary_line "Throttle baseline: $APO_THROTTLE_BASELINE (historical bits retained; active/new bits remain failures)"
    apo_summary_line "Permanent config hash: $APO_PERMANENT_CONFIG_HASH"
    apo_summary_line "Display baseline: ${APO_DISPLAY_BASELINE:-not captured}"
    apo_summary_line "Audio baseline: $audio_summary"
    apo_summary_line ''
}

apo_restore_context_from_state() {
    APO_PROFILE=$(apo_state_get PROFILE)
    APO_MODE_EFFECTIVE=$(apo_state_get MODE_EFFECTIVE)
    APO_MODE_REQUESTED=$(apo_state_get MODE_REQUESTED auto)
    APO_BOOT_CONFIG=$(apo_state_get BOOT_CONFIG)
    APO_TRYBOOT_CONFIG=$(apo_state_get TRYBOOT_CONFIG)
    APO_BOOT_MOUNT=$(apo_state_get BOOT_MOUNT)
    APO_GPU_KEY=$(apo_state_get GPU_KEY)
    APO_NORMAL_CPU=$(apo_state_get NORMAL_CPU)
    APO_NORMAL_GPU=$(apo_state_get NORMAL_GPU)
    APO_NORMAL_VOLTAGE=$(apo_state_get NORMAL_VOLTAGE)
    APO_PERMANENT_TUNING_PROVENANCE=$(apo_state_get PERMANENT_TUNING_PROVENANCE missing)
    APO_PERMANENT_TUNING_EVIDENCE=$(apo_state_get PERMANENT_TUNING_EVIDENCE missing)
    APO_AUTO_BASELINE_CPU=$(apo_state_get AUTO_BASELINE_CPU missing)
    APO_AUTO_BASELINE_GPU=$(apo_state_get AUTO_BASELINE_GPU missing)
    APO_AUTO_BASELINE_VOLTAGE=$(apo_state_get AUTO_BASELINE_VOLTAGE missing)
    APO_AUTO_BASELINE_PROVENANCE=$(apo_state_get AUTO_BASELINE_PROVENANCE missing)
    APO_AUTO_BASELINE_EVIDENCE=$(apo_state_get AUTO_BASELINE_EVIDENCE missing)
    APO_TEST_VOLTAGE=$(apo_state_get TEST_VOLTAGE)
    APO_PERMANENT_CONFIG_HASH=$(apo_state_get PERMANENT_HASH)
    APO_THROTTLE_BASELINE=$(apo_state_get THROTTLE_BASELINE throttled=0x0)
    APO_THROTTLE_RUNTIME_BASELINE=$(apo_state_get THROTTLE_RUNTIME_BASELINE throttled=0x0)
    APO_THROTTLE_RECENT_SUPPORTED=$(apo_state_get THROTTLE_RECENT_SUPPORTED 0)
    APO_DISPLAY_BASELINE=$(apo_state_get DISPLAY_BASELINE)
    APO_AUDIO_BASELINE=$(apo_state_get AUDIO_BASELINE)
    APO_STORAGE_LAYOUT=$(apo_state_get STORAGE_LAYOUT)
    apo_config_restore_from_state
    case ${APO_COMMAND:-} in
        resume|apply|post-floor-edge|post-floor-final)
            if (( APO_AUTO_GENERATED_CANDIDATES == 1 )); then
                apo_config_require_stock_auto_baseline "$APO_AUTO_BASELINE_CPU" "$APO_AUTO_BASELINE_GPU" "$APO_AUTO_BASELINE_VOLTAGE" \
                    "$APO_AUTO_BASELINE_PROVENANCE" "$APO_AUTO_BASELINE_EVIDENCE"
            fi
            ;;
    esac
    APO_NEED_GPU=$(( ${#APO_GPU_CANDIDATES[@]} > 0 ? 1 : 0 ))
    APO_REQUIRE_GPU_STRESS=$(apo_state_get REQUIRE_GPU_STRESS '')
    if [[ -z $APO_REQUIRE_GPU_STRESS ]]; then
        if (( APO_NEED_GPU == 1 )) || [[ $APO_MODE_EFFECTIVE == graphical ]]; then APO_REQUIRE_GPU_STRESS=1; else APO_REQUIRE_GPU_STRESS=0; fi
    fi
    apo_load_profile "$APO_PROFILE"
}
