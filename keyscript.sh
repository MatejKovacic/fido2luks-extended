#!/bin/sh
# Author: Matej Kovačič (2026)
# This script is based on fido2luks script that was written by Alberto Garcia from 2024-2025
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Modified version:
# - Plymouth-friendly PIN/touch handling
# - Slovenian/English messages
# - enable/disable technical/debug messages shown via Plymouth and text console
# - increased timeout for the FIDO2 USB key to appear during initramfs boot
# - configurable user-friendly countdown for confirming physical presence (touch)
# - exactly one inserted FIDO2 authenticator expected
# - try all usable systemd/FIDO2 token records from the LUKS2 header
# - harden temporary files and fido2-assert error handling

# NOTICE:
# For this setup, where client PIN and touch are required, set the FIDO2 PIN first,
# then enroll the FIDO2 device with:
# systemd-cryptenroll --fido2-device=auto --fido2-with-client-pin=true --fido2-with-user-presence=true /dev/nvme0n1p5
#
# Set an initial FIDO2 PIN: fido2-token -S /dev/hidraw1
# Change the existing FIDO2 PIN: fido2-token -C /dev/hidraw1
# Check if FIDO2 PIN is set: fido2-token -I /dev/hidraw1 | grep 'clientPin\|pin retries'
#
# Runtime tools needed in initramfs: fido2-token, fido2-assert, jq, cryptsetup,
# setsid, mktemp, sed, tail, wc, tr, sleep, kill, stty, and /lib/cryptsetup/askpass.
# On Debian, fido2-token/fido2-assert are provided by: apt install fido2-tools jq

# PLEASE NOTE:
# One deliberate limitation remains: the PIN is still briefly written to a root-only temp file. 
# In POSIX sh, that is the practical choice here because the script needs a real fido2-assert 
# PID for the watchdog/countdown. With umask 077 and initramfs tmpfs, this is acceptable, 
# but it is not as strong as a memory-only implementation in a different language.


# Keep all temporary files private. FIDO2_OUT contains the derived unlock secret.
umask 077

cleanup () {
    # If the script is interrupted while fido2-assert or its watchdog is running,
    # stop them before removing temporary files.
    if [ -n "${FIDO2_TIMER_PID:-}" ]; then
        kill "$FIDO2_TIMER_PID" 2>/dev/null || true
        wait "$FIDO2_TIMER_PID" 2>/dev/null || true
    fi

    if [ -n "${FIDO2_PID:-}" ]; then
        kill "$FIDO2_PID" 2>/dev/null || true
        wait "$FIDO2_PID" 2>/dev/null || true
    fi

    rm -f "${ASSERT_PARAMS:-}" "${LUKS_TOKEN:-}" "${LUKS_TOKEN_LIST:-}" \
          "${FIDO2_OUT:-}" "${FIDO2_ERR:-}" "${FIDO2_ERR_FILTERED:-}" \
          "${FIDO2_PIN:-}" "${FIDO2_TIMEOUT_MARKER:-}"
}

ASSERT_PARAMS=$(mktemp -t params.XXXXXX)
LUKS_TOKEN_LIST=$(mktemp -t tokenlist.XXXXXX)
LUKS_TOKEN=$(mktemp -t token.XXXXXX)
trap cleanup INT TERM HUP EXIT

# Enable technical/debug messages shown via Plymouth and text console.
# Set to 1 while testing. Keep 0 for normal use.
FIDO2LUKS_DEBUG=${FIDO2LUKS_DEBUG:-0}

# Language for user-facing messages: en, sl.
FIDO2LUKS_LANG=${FIDO2LUKS_LANG:-en}

# How long to wait for the FIDO2 USB key to appear during initramfs boot.
FIDO2LUKS_WAIT_SECONDS=${FIDO2LUKS_WAIT_SECONDS:-15}
case "$FIDO2LUKS_WAIT_SECONDS" in
    ''|*[!0-9]*) FIDO2LUKS_WAIT_SECONDS=15 ;;
esac

# How long to wait for the user-presence touch confirmation.
FIDO2LUKS_TOUCH_SECONDS=${FIDO2LUKS_TOUCH_SECONDS:-20}
case "$FIDO2LUKS_TOUCH_SECONDS" in
    ''|*[!0-9]*) FIDO2LUKS_TOUCH_SECONDS=20 ;;
esac

plymouth_available () {
    command -v plymouth >/dev/null 2>&1 && plymouth --ping >/dev/null 2>&1
}

msg_text () {
    _msg_id=$1
    _arg1=${2:-}

    case "$FIDO2LUKS_LANG:$_msg_id" in
        sl:waiting_key)
            printf '%s\n' "Čakam na varnostni USB ključ..." ;;
        *:waiting_key)
            printf '%s\n' "Waiting for the security USB key..." ;;

        sl:no_key)
            printf '%s\n' "Varnostnega USB ključa ni bilo mogoče najti!" ;;
        *:no_key)
            printf '%s\n' "No security USB key found!" ;;

        sl:too_many_keys)
            printf '%s\n' "Vstavljen je več kot en varnostni USB ključ. Odstranite dodatne ključe in znova zaženite računalnik." ;;
        *:too_many_keys)
            printf '%s\n' "More than one security USB key is inserted. Remove the extra keys and reboot." ;;

        sl:pin_prompt)
            printf '%s\n' "Vnesite PIN za varnostni USB ključ" ;;
        *:pin_prompt)
            printf '%s\n' "Enter PIN for security USB key" ;;

        sl:touch_countdown)
            cat <<EOF
Potrdite svojo prisotnost.
Dotaknite se varnostnega USB ključa ZDAJ.

Ta poskus bo potekel čez ${_arg1}s.
EOF
            ;;

        *:touch_countdown)
            cat <<EOF
Please confirm your presence.
Touch the security USB key NOW.

This attempt will time out in ${_arg1}s.
EOF
            ;;

        sl:touch_timeout)
            cat <<EOF
Varnostnega ključa se niste pravočasno dotaknili.
Znova vstavite ključ in ponovno zaženite računalnik,
ali vnesite obnovitveno šifrirno geslo.
EOF
            ;;

        *:touch_timeout)
            cat <<EOF
Security key was not touched in time.
Reinsert the key and reboot computer to retry,
or enter recovery encryption passphrase.
EOF
            ;;

        sl:fido_failed)
            cat <<EOF
Odklepanje diska z varnostnim USB ključem ni uspelo.
Znova vstavite ključ in ponovno zaženite računalnik,
ali vnesite obnovitveno šifrirno geslo.
EOF
            ;;

        *:fido_failed)
            cat <<EOF
Unlocking disk with security USB key failed.
Reinsert the key and reboot computer to retry,
or enter recovery encryption passphrase.
EOF
            ;;

        sl:passphrase_fallback)
            printf '%s\n' "Odklepanje diska z obnovitvenim šifrirnim geslom" ;;
        *:passphrase_fallback)
            printf '%s\n' "Unlocking disk using a recovery encryption passphrase" ;;

        sl:passphrase_prompt)
            printf '%s\n' "Vnesite obnovitveno šifrirno geslo: " ;;
        *:passphrase_prompt)
            printf '%s\n' "Enter recovery encryption passphrase: " ;;
    esac
}

plymouth_message () {
    echo "*** $*" >&2
    if plymouth_available; then
        plymouth display-message --text="$*" >/dev/null 2>&1 || true
    fi
}

debug_message () {
    if [ "$FIDO2LUKS_DEBUG" = "1" ]; then
        plymouth_message "DEBUG: $*"
    fi
}

ask_security_key_pin () {
    if plymouth_available; then
        plymouth ask-for-password --prompt="$(msg_text pin_prompt)"
        return
    fi

    if [ -x /lib/cryptsetup/askpass ]; then
        /lib/cryptsetup/askpass "$(msg_text pin_prompt): "
        return
    fi

    printf '%s: ' "$(msg_text pin_prompt)" >&2
    stty -echo 2>/dev/null || true
    IFS= read -r _pin
    stty echo 2>/dev/null || true
    echo >&2
    printf '%s\n' "$_pin"
}

# Prepare fido2-assert input for one token record from the LUKS header.
make_assert_params_for_token () {
    jq ".[${1}]" "$LUKS_TOKEN_LIST" > "$LUKS_TOKEN"

    TOKEN_ID=$(jq -r '.token_id' "$LUKS_TOKEN")

    jq -r '"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
           .token."fido2-rp",
           .token."fido2-credential",
           .token."fido2-salt"' "$LUKS_TOKEN" > "$ASSERT_PARAMS"

    REQ_UV=$(jq -r '.token."fido2-uv-required" // false' "$LUKS_TOKEN")
    REQ_PIN=$(jq -r '.token."fido2-clientPin-required" // false' "$LUKS_TOKEN")
    REQ_UP=$(jq -r '.token."fido2-up-required" // false' "$LUKS_TOKEN")

    # Not all authenticators support 'uv', so pass '-t uv' only
    # when needed using the UV_OPT variable.
    if [ "$REQ_UV" = "true" ]; then
        UV_OPT="-t uv=true"
    else
        UV_OPT=""
    fi

    debug_message "Prepared FIDO2 token id $TOKEN_ID attempt index ${1}: pin=$REQ_PIN up=$REQ_UP uv=$REQ_UV dev=$FIDO2_DEV"
}

classify_fido2_error () {
    _err=$1

    # Clear PIN-authentication failures: abort to avoid burning retries.
    case "$_err" in
        *"invalid PIN"*|*"Invalid PIN"*|*"invalid PIN length"*|*"Invalid PIN length"*|*"PIN_INVALID"*|*"PIN_AUTH_INVALID"*|*"PIN blocked"*|*"PIN_BLOCKED"*|*"PIN is blocked"*|*"pinAuthInvalid"*)
            printf '%s\n' "pin-error"
            return
            ;;
    esac

    # Credential mismatch or unsupported credential: try the next disk token.
    case "$_err" in
        *"credential"*|*"Credential"*|*"not found"*|*"No such"*|*"no credentials"*|*"No credentials"*|*"invalid credential"*|*"Invalid credential"*|*"FIDO_ERR_NO_CREDENTIALS"*)
            printf '%s\n' "credential-mismatch"
            return
            ;;
    esac

    printf '%s\n' "failed"
}

filter_fido2_error () {
    # fido2-assert prints its PIN prompt to stderr even when the PIN is supplied
    # through stdin. Strip only the prompt prefix, not the rest of the line.
    sed 's/^Enter PIN for [^:]*:[[:space:]]*//' "$FIDO2_ERR" 2>/dev/null | \
        sed '/^[[:space:]]*$/d' > "$FIDO2_ERR_FILTERED" || true
}

is_base64_secret () {
    _candidate=$1

    # libfido2 emits the hmac-secret as a base64/base64url-like blob.
    # For one CTAP hmac-secret salt this is normally 32 bytes encoded as
    # 43 or 44 characters; two-salt output would be 86 or 88 characters.
    case "$_candidate" in
        ''|*[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=_-]*)
            return 1
            ;;
    esac

    _candidate_len=${#_candidate}
    case "$_candidate_len" in
        43|44|86|88)
            return 0
            ;;
    esac

    return 1
}

extract_fido2_secret () {
    # fido2-assert currently writes the hmac-secret as the final non-empty
    # stdout line. Do not blindly accept any last line: validate that it looks
    # like a plausible hmac-secret blob before giving it to cryptsetup.
    SECRET=$(sed '/^[[:space:]]*$/d' "$FIDO2_OUT" 2>/dev/null | tail -n 1)

    if is_base64_secret "$SECRET"; then
        return 0
    fi

    SECRET=""
    return 1
}

start_touch_watchdog () {
    FIDO2_TIMER_PID=""
    FIDO2_TIMEOUT_MARKER=$(mktemp -t fido2timeout.XXXXXX)
    rm -f "$FIDO2_TIMEOUT_MARKER"

    (
        _seconds_left=$FIDO2LUKS_TOUCH_SECONDS

        while [ "$_seconds_left" -gt 0 ]; do
            if ! kill -0 "$FIDO2_PID" 2>/dev/null; then
                exit 0
            fi

            plymouth_message "$(msg_text touch_countdown "$_seconds_left")"
            sleep 1
            _seconds_left=$((_seconds_left - 1))
        done

        if kill -0 "$FIDO2_PID" 2>/dev/null; then
            : > "$FIDO2_TIMEOUT_MARKER"
            kill "$FIDO2_PID" 2>/dev/null || true
        fi
    ) &

    FIDO2_TIMER_PID=$!
}

stop_touch_watchdog () {
    if [ -n "${FIDO2_TIMER_PID:-}" ]; then
        kill "$FIDO2_TIMER_PID" 2>/dev/null || true
        wait "$FIDO2_TIMER_PID" 2>/dev/null || true
        FIDO2_TIMER_PID=""
    fi
}

try_assert_for_current_token () {
    _token_index=$1

    ASSERT_STATUS=""
    SECRET=""
    FIDO2_RC=1
    FIDO2_PID=""
    FIDO2_TIMER_PID=""
    FIDO2_TIMEOUT_MARKER=""

    FIDO2_OUT=$(mktemp -t fido2out.XXXXXX)
    FIDO2_ERR=$(mktemp -t fido2err.XXXXXX)
    FIDO2_ERR_FILTERED=$(mktemp -t fido2err-filtered.XXXXXX)
    FIDO2_PIN=""

    # If this token requires a PIN, use the PIN collected for the single
    # inserted authenticator and pass it to fido2-assert through stdin.
    # A temporary root-only file is used because POSIX sh has no portable
    # here-string/process substitution, and we need a real fido2-assert PID
    # while the touch watchdog displays the countdown.
    if [ "$REQ_PIN" = "true" ]; then
        if [ -z "${PIN_COLLECTED:-}" ]; then
            PIN=$(ask_security_key_pin)
            PIN_COLLECTED=1
        fi

        if [ -z "$PIN" ]; then
            debug_message "Empty PIN entered"
            ASSERT_STATUS=pin-error
            rm -f "$FIDO2_OUT" "$FIDO2_ERR" "$FIDO2_ERR_FILTERED"
            return 1
        fi

        FIDO2_PIN=$(mktemp -t fido2pin.XXXXXX)
        chmod 600 "$FIDO2_PIN" 2>/dev/null || true
        printf "%s\n" "$PIN" > "$FIDO2_PIN"

        # UV_OPT is intentionally unquoted: when set, it expands to two
        # arguments (-t uv=true). Keep it controlled inside this script.
        setsid fido2-assert \
            -G -h -t up="$REQ_UP" -t pin="$REQ_PIN" $UV_OPT \
            -i "$ASSERT_PARAMS" "$FIDO2_DEV" \
            < "$FIDO2_PIN" > "$FIDO2_OUT" 2> "$FIDO2_ERR" &
    else
        # UV_OPT is intentionally unquoted for the same reason as above.
        setsid fido2-assert \
            -G -h -t up="$REQ_UP" -t pin="$REQ_PIN" $UV_OPT \
            -i "$ASSERT_PARAMS" "$FIDO2_DEV" \
            < /dev/null > "$FIDO2_OUT" 2> "$FIDO2_ERR" &
    fi

    FIDO2_PID=$!

    # Avoid the old race where a final kill -0 check could classify a just-
    # completed assertion as a timeout. A separate watchdog kills fido2-assert
    # after the configured touch window; the main path always waits for the
    # actual process exit code and treats rc=0 plus valid output as success.
    if [ "$REQ_UP" = "true" ]; then
        start_touch_watchdog
    fi

    wait "$FIDO2_PID" 2>/dev/null
    FIDO2_RC=$?
    FIDO2_PID=""

    stop_touch_watchdog

    if [ "$FIDO2_RC" -eq 0 ] && extract_fido2_secret; then
        ASSERT_STATUS=ok
    elif [ -n "${FIDO2_TIMEOUT_MARKER:-}" ] && [ -e "$FIDO2_TIMEOUT_MARKER" ]; then
        plymouth_message "$(msg_text touch_timeout)"
        sleep 5
        SECRET=""
        ASSERT_STATUS=timeout
    else
        SECRET=""
        ASSERT_STATUS=failed
    fi

    # Only classify normal fido2-assert failures. A watchdog timeout is
    # already authoritative and should not be overwritten by stderr text.
    if [ "$ASSERT_STATUS" = "failed" ] && [ -s "$FIDO2_ERR" ]; then
        filter_fido2_error
        if [ -s "$FIDO2_ERR_FILTERED" ]; then
            _last_err=$(tail -n 1 "$FIDO2_ERR_FILTERED")
            ASSERT_STATUS=$(classify_fido2_error "$_last_err")
            debug_message "Token id $TOKEN_ID attempt index $_token_index failed: $_last_err status=$ASSERT_STATUS rc=$FIDO2_RC"
        else
            debug_message "Token id $TOKEN_ID attempt index $_token_index failed status=$ASSERT_STATUS rc=$FIDO2_RC"
        fi
    fi

    rm -f "$FIDO2_OUT" "$FIDO2_ERR" "$FIDO2_ERR_FILTERED" "${FIDO2_PIN:-}" "${FIDO2_TIMEOUT_MARKER:-}"
    FIDO2_PIN=""
    FIDO2_TIMEOUT_MARKER=""

    [ "$ASSERT_STATUS" = "ok" ]
}

try_fido2_unlock () {
    debug_message "Starting FIDO2 LUKS unlock"
    debug_message "CRYPTTAB_SOURCE=$CRYPTTAB_SOURCE"
    debug_message "PATH=$PATH"
    debug_message "cryptsetup path=$(command -v cryptsetup || echo missing)"
    debug_message "jq path=$(command -v jq || echo missing)"
    debug_message "fido2-token path=$(command -v fido2-token || echo missing)"
    debug_message "fido2-assert path=$(command -v fido2-assert || echo missing)"
    debug_message "setsid path=$(command -v setsid || echo missing)"

    if [ -z "$CRYPTTAB_SOURCE" ]; then
        debug_message "CRYPTTAB_SOURCE is empty"
        return 1
    fi

    if ! command -v setsid >/dev/null 2>&1; then
        debug_message "setsid is missing"
        return 1
    fi

    # Get all systemd/FIDO2 tokens from the LUKS header.
    # Ignore orphaned token records with no keyslots.
    # Preserve the original LUKS token id for debugging.
    # Sort least-interactive records first:
    #   no PIN before PIN
    #   no touch before touch
    #   no UV before UV
    if ! cryptsetup luksDump --dump-json-metadata "$CRYPTTAB_SOURCE" | \
            jq -e '[
                    (.tokens // {}) | to_entries[]
                    | select(.value.type == "systemd-fido2")
                    | select(.value."fido2-credential" != null)
                    | select(.value."fido2-rp" != null)
                    | select(.value."fido2-salt" != null)
                    | select((.value.keyslots // []) | length > 0)
                    | {
                        token_id: .key,
                        token: .value,
                        sort_pin: (.value."fido2-clientPin-required" // false),
                        sort_up: (.value."fido2-up-required" // false),
                        sort_uv: (.value."fido2-uv-required" // false)
                      }
                  ]
                  | sort_by([.sort_pin, .sort_up, .sort_uv])' > "$LUKS_TOKEN_LIST"; then
        debug_message "Error reading usable systemd/FIDO2 tokens from LUKS header: $CRYPTTAB_SOURCE"
        return 1
    fi

    # Count how many tokens we have.
    NTOKENS=$(jq length "$LUKS_TOKEN_LIST")
    debug_message "Found $NTOKENS usable systemd/FIDO2 LUKS token(s)"

    if [ -z "$NTOKENS" ] || [ "$NTOKENS" = "0" ]; then
        debug_message "No usable systemd/FIDO2 credentials found in $CRYPTTAB_SOURCE"
        return 1
    fi

    # Check if the FIDO2 authenticator is inserted.
    # This modified version expects exactly one authenticator.
    plymouth_message "$(msg_text waiting_key)"

    FIDO2_AUTHENTICATOR=""
    _i=0
    while [ "$_i" -lt "$FIDO2LUKS_WAIT_SECONDS" ]; do
        FIDO2_AUTHENTICATOR=$(fido2-token -L 2>/dev/null)
        debug_message "fido2-token -L attempt $_i returned: $FIDO2_AUTHENTICATOR"

        if [ -n "$FIDO2_AUTHENTICATOR" ]; then
            break
        fi

        _i=$((_i + 1))
        sleep 1
    done

    if [ -z "$FIDO2_AUTHENTICATOR" ]; then
        plymouth_message "$(msg_text no_key)"
        return 1
    fi

    NDEVICES=$(printf '%s\n' "$FIDO2_AUTHENTICATOR" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
    if [ "$NDEVICES" != "1" ]; then
        plymouth_message "$(msg_text too_many_keys)"
        debug_message "Expected exactly one FIDO2 device, found $NDEVICES"
        sleep 5
        return 1
    fi

    debug_message "Found FIDO2 authenticator $FIDO2_AUTHENTICATOR"
    FIDO2_DEV=${FIDO2_AUTHENTICATOR%%:*}
    debug_message "Using FIDO2 device: $FIDO2_DEV"

    PIN=""
    PIN_COLLECTED=""

    # Look for a credential that is valid for the inserted FIDO2
    # authenticator.
    #
    # The original keyscript first tried credentials silently with
    # 'up=false' and 'pin=false'. This modified version does not do that,
    # because PIN-required credentials and Plymouth PIN handling interact
    # badly with the silent pre-check path.
    #
    # Instead, try every usable systemd/FIDO2 token record from this LUKS
    # header with its real required options. Stop as soon as one token
    # returns a secret.
    TOKEN_INDEX=0
    while [ "$TOKEN_INDEX" -lt "$NTOKENS" ]; do
        make_assert_params_for_token "$TOKEN_INDEX"

        SECRET=""
        ASSERT_STATUS=""

        # Now use this token record to compute the hmac-secret,
        # which is what unlocks the LUKS volume.
        try_assert_for_current_token "$TOKEN_INDEX"
        RESULT=$?

        case "$ASSERT_STATUS" in
            ok)
                if [ "$RESULT" -eq 0 ] && [ -n "$SECRET" ]; then
                    PIN=""
                    echo >&2
                    printf "%s" "$SECRET"
                    return 0
                fi
                ;;

            credential-mismatch)
                # This disk token record does not belong to the inserted key.
                # Try the next usable systemd/FIDO2 token record.
                debug_message "Trying next FIDO2 token record"
                TOKEN_INDEX=$((TOKEN_INDEX + 1))
                continue
                ;;

            pin-error)
                # Clear PIN failures are hard failures: continuing could burn
                # more authenticator PIN retries.
                PIN=""
                plymouth_message "$(msg_text fido_failed)"
                sleep 5
                return 1
                ;;

            timeout)
                PIN=""
                return 1
                ;;

            failed|*)
                # Unknown fido2-assert/device errors are treated strictly.
                # Do not continue prompting through more disk records after an
                # unexpected transport/library/output-parsing failure.
                PIN=""
                plymouth_message "$(msg_text fido_failed)"
                sleep 5
                return 1
                ;;
        esac

        TOKEN_INDEX=$((TOKEN_INDEX + 1))
    done

    debug_message "No valid credential found for this FIDO2 authenticator"
    PIN=""
    plymouth_message "$(msg_text fido_failed)"
    sleep 5
    return 1
}

# Main execution.
if try_fido2_unlock; then
    exit 0
fi

plymouth_message "$(msg_text passphrase_fallback)"
/lib/cryptsetup/askpass "$(msg_text passphrase_prompt)"
