#!/bin/sh
set -eu

CDPATH=''
export CDPATH
test_dir=$(cd -- "$(dirname -- "$0")" && pwd)
shim=$test_dir/../libexec/ox-ghostel-ssh
fake=$test_dir/fixtures/ox-ghostel-ssh-fake
test_root=$(mktemp -d "${TMPDIR:-/tmp}/ox-ghostel-ssh-test.XXXXXX")
trap 'rm -rf "$test_root"' EXIT HUP INT TERM

log=$test_root/log
cache=$test_root/cache
source_entry=$test_root/xterm-kitty.terminfo
compiled_entry=$test_root/xterm-kitty.compiled
printf 'terminfo source\n' > "$source_entry"
printf 'compiled terminfo\n' > "$compiled_entry"

export OX_GHOSTEL_SSH_REAL="$fake"
export OX_GHOSTEL_SSH_FAKE_LOG="$log"
export OX_GHOSTEL_SSH_CACHE_DIR="$cache"
export OX_GHOSTEL_SSH_TERMINFO_SOURCE="$source_entry"
export OX_GHOSTEL_SSH_TERMINFO_COMPILED="$compiled_entry"
export OX_GHOSTEL_SSH_TEST_TTY=1
export OX_GHOSTEL_SSH_CACHE_TTL=604800
export OX_GHOSTEL_SSH_DEBUG=0

hex() {
    printf %s "$1" | LC_ALL=C od -An -tx1 | tr -d ' \n'
}

reset_case() {
    rm -rf "$cache"
    : > "$log"
    unset OX_GHOSTEL_SSH_ENABLE OX_GHOSTEL_SSH_FAKE_FINAL_STATUS
    unset OX_GHOSTEL_SSH_FAKE_HOSTNAME OX_GHOSTEL_SSH_FAKE_USER
    unset OX_GHOSTEL_SSH_FAKE_PORT
    unset OX_GHOSTEL_SSH_FAKE_REQUEST_TTY OX_GHOSTEL_SSH_FAKE_SESSION_TYPE
    unset OX_GHOSTEL_SSH_FAKE_REMOTE_COMMAND
}

assert_contains() {
    grep -F "$1" "$log" >/dev/null || {
        printf 'missing log entry: %s\n' "$1" >&2
        sed -n '1,240p' "$log" >&2
        exit 1
    }
}

assert_call_count() {
    actual=$(grep -c '^CALL ' "$log" || true)
    [ "$actual" = "$1" ] || {
        printf 'expected %s calls, got %s\n' "$1" "$actual" >&2
        sed -n '1,240p' "$log" >&2
        exit 1
    }
}

# Noninteractive commands, -T, and disabled mode are exact passthroughs.
reset_case
OX_GHOSTEL_SSH_FAKE_SCENARIO=native; export OX_GHOSTEL_SSH_FAKE_SCENARIO
# shellcheck disable=SC2016 # literal hostile remote command argument
"$shim" host 'printf "%s" "$HOME;not-code"'
assert_call_count 1
assert_contains 'CALL KIND=final ARGC=2'
assert_contains "ARGHEX=$(hex host)"
# shellcheck disable=SC2016 # literal hostile remote command argument
literal_command='printf "%s" "$HOME;not-code"'
assert_contains "ARGHEX=$(hex "$literal_command")"

reset_case
"$shim" -T host
assert_call_count 1
assert_contains 'CALL KIND=final ARGC=2'

reset_case
"$shim" -N -L '127.0.0.1:8080:localhost:80' host
assert_call_count 1
assert_contains 'CALL KIND=final ARGC=4'

reset_case
OX_GHOSTEL_SSH_ENABLE=0; export OX_GHOSTEL_SSH_ENABLE
"$shim" -p 2222 user@host
assert_call_count 1
assert_contains 'CALL KIND=final ARGC=3'

# Native support: one probe connection and an exec handoff with native TERM.
reset_case
OX_GHOSTEL_SSH_FAKE_SCENARIO=native; export OX_GHOSTEL_SSH_FAKE_SCENARIO
"$shim" -v -A -p 2222 -J 'jump host' 'user@alias'
assert_call_count 3
assert_contains 'KIND=config'
assert_contains 'KIND=native-probe'
assert_contains "KIND=final"
assert_contains "TERMHEX=$(hex xterm-kitty)"
assert_contains "ARGHEX=$(hex 'jump host')"
assert_contains "ARGHEX=$(hex user@alias)"
assert_contains "ARGHEX=$(hex 2222)"

# Interactive forwarding is applied only by the final session; the probe
# master explicitly clears it to avoid duplicate listener side effects.
reset_case
OX_GHOSTEL_SSH_FAKE_SCENARIO=native; export OX_GHOSTEL_SSH_FAKE_SCENARIO
"$shim" -L '127.0.0.1:8080:localhost:80' host
assert_contains 'KIND=native-probe'
assert_contains "ARGHEX=$(hex ClearAllForwardings=yes)"
assert_contains 'KIND=final'

# OpenSSH's effective RemoteCommand/RequestTTY policy can make a literal
# `ssh host` noninteractive; that decision remains authoritative.
reset_case
OX_GHOSTEL_SSH_FAKE_REQUEST_TTY=no; export OX_GHOSTEL_SSH_FAKE_REQUEST_TTY
"$shim" host
assert_call_count 2
if grep -F 'KIND=native-probe' "$log" >/dev/null; then exit 1; fi

# Explicit PTY allocation remains smart, but helper streams use -T on the
# already-authenticated control socket.
reset_case
OX_GHOSTEL_SSH_FAKE_SCENARIO=native; export OX_GHOSTEL_SSH_FAKE_SCENARIO
"$shim" -tt host
assert_call_count 3
assert_contains 'KIND=native-probe'
assert_contains 'KIND=final'

# A valid cache entry is keyed by ssh -G identity rather than literal alias and
# skips the remote probe, while TTL=0 forces revalidation.
reset_case
OX_GHOSTEL_SSH_FAKE_SCENARIO=native; export OX_GHOSTEL_SSH_FAKE_SCENARIO
"$shim" first-alias
: > "$log"
OX_GHOSTEL_SSH_FAKE_SCENARIO=unreachable; export OX_GHOSTEL_SSH_FAKE_SCENARIO
"$shim" second-alias
assert_call_count 2
assert_contains 'KIND=config'
assert_contains 'KIND=final'
if grep -F 'KIND=native-probe' "$log" >/dev/null; then exit 1; fi

: > "$log"
OX_GHOSTEL_SSH_CACHE_TTL=0; export OX_GHOSTEL_SSH_CACHE_TTL
set +e
"$shim" second-alias
status=$?
set -e
[ "$status" = 255 ]
assert_contains 'KIND=native-probe'
OX_GHOSTEL_SSH_CACHE_TTL=604800; export OX_GHOSTEL_SSH_CACHE_TTL

# tic and compiled no-tic bootstrap paths both require post-install success.
reset_case
OX_GHOSTEL_SSH_FAKE_SCENARIO=tic; export OX_GHOSTEL_SSH_FAKE_SCENARIO
"$shim" host
assert_contains 'KIND=tic-bootstrap'
assert_contains 'KIND=final'
assert_contains "TERMHEX=$(hex xterm-kitty)"

reset_case
OX_GHOSTEL_SSH_FAKE_SCENARIO=compiled; export OX_GHOSTEL_SSH_FAKE_SCENARIO
"$shim" host
assert_contains 'KIND=tic-bootstrap'
assert_contains 'KIND=compiled-bootstrap'
assert_contains 'KIND=final'
assert_contains "TERMHEX=$(hex xterm-kitty)"

# Bootstrap failure selects the first remotely verified fallback per connection.
reset_case
OX_GHOSTEL_SSH_FAKE_SCENARIO=fallback; export OX_GHOSTEL_SSH_FAKE_SCENARIO
"$shim" host
assert_contains 'KIND=compiled-bootstrap'
assert_contains 'KIND=fallback-256-probe'
assert_contains "TERMHEX=$(hex xterm-256color)"

# Destination-derived strings never enter a remote command or filesystem path.
reset_case
sentinel=$test_root/should-not-exist
OX_GHOSTEL_SSH_FAKE_HOSTNAME="bad;touch $sentinel"; export OX_GHOSTEL_SSH_FAKE_HOSTNAME
# shellcheck disable=SC2016 # literal hostile effective user value
OX_GHOSTEL_SSH_FAKE_USER='u`touch should-not-exist`'; export OX_GHOSTEL_SSH_FAKE_USER
OX_GHOSTEL_SSH_FAKE_SCENARIO=native; export OX_GHOSTEL_SSH_FAKE_SCENARIO
# shellcheck disable=SC2016 # literal hostile destination argument
"$shim" 'alias;$(touch should-not-exist)'
[ ! -e "$sentinel" ]
[ ! -e should-not-exist ]

# Final ssh exit status is propagated because the handoff uses exec.
reset_case
OX_GHOSTEL_SSH_FAKE_SCENARIO=native; export OX_GHOSTEL_SSH_FAKE_SCENARIO
OX_GHOSTEL_SSH_FAKE_FINAL_STATUS=37; export OX_GHOSTEL_SSH_FAKE_FINAL_STATUS
set +e
"$shim" host
status=$?
set -e
[ "$status" = 37 ]

# The final fake ssh replaces the wrapper process, preserving PID/signal and
# job-control semantics instead of leaving an intermediate shell parent.
reset_case
OX_GHOSTEL_SSH_FAKE_SCENARIO=native; export OX_GHOSTEL_SSH_FAKE_SCENARIO
"$shim" host &
handoff_pid=$!
wait "$handoff_pid"
assert_contains "KIND=final"
assert_contains "PID=$handoff_pid"

# A misresolved real executable fails closed instead of recursively invoking ssh.
reset_case
OX_GHOSTEL_SSH_REAL=$shim; export OX_GHOSTEL_SSH_REAL
set +e
"$shim" host >/dev/null 2>&1
status=$?
set -e
[ "$status" = 126 ]

printf 'ox-ghostel-ssh shim tests: PASS\n'
