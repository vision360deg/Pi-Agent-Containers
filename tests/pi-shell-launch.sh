#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHER="$ROOT/bin/pi-shell-launch"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { grep -Fqx -- "$2" "$1" || fail "missing $2"; }

[[ -x $LAUNCHER ]] || fail 'launcher must be executable'

mkdir -p "$TMP/bin"
for shell in bash zsh; do
  cat > "$TMP/bin/$shell" <<'EOF'
#!/bin/sh
printf 'shell=%s\n' "$(basename "$0")" >> "$PI_TEST_LOG"
printf 'zdotdir=%s\n' "${ZDOTDIR-}" >> "$PI_TEST_LOG"
for argument in "$@"; do
  printf 'arg=%s\n' "$argument" >> "$PI_TEST_LOG"
done
EOF
  chmod 0755 "$TMP/bin/$shell"
done

run_launcher() {
  : > "$TMP/log"
  PI_TEST_LOG="$TMP/log" PATH="$TMP/bin:$PATH" /bin/bash "$LAUNCHER" "$@"
}

PI_HOST_SHELL=zsh PI_HOST_RC_FILE="$TMP/rc" PI_NO_RC_CONFIG=0 run_launcher command one
assert_contains "$TMP/log" 'shell=zsh'
assert_contains "$TMP/log" 'arg=-i'
assert_contains "$TMP/log" 'arg=-c'
assert_contains "$TMP/log" 'arg=exec "$@"'
assert_contains "$TMP/log" 'arg=pi-shell-launch'
assert_contains "$TMP/log" 'arg=command'
assert_contains "$TMP/log" 'arg=one'
grep -Eq "^zdotdir=/tmp/pi-shell-launch\." "$TMP/log" || fail 'zsh must receive a private ZDOTDIR'

PI_HOST_SHELL=zsh PI_HOST_RC_FILE="$TMP/rc" PI_NO_RC_CONFIG=0 run_launcher
assert_contains "$TMP/log" 'shell=zsh'
assert_contains "$TMP/log" 'arg=-i'
if grep -Fq 'arg=-c' "$TMP/log"; then fail 'interactive zsh must not receive -c'; fi

PI_HOST_SHELL=bash PI_HOST_RC_FILE="$TMP/rc" PI_NO_RC_CONFIG=0 run_launcher command two
assert_contains "$TMP/log" 'shell=bash'
assert_contains "$TMP/log" 'arg=-i'
assert_contains "$TMP/log" 'arg=--rcfile'
assert_contains "$TMP/log" "arg=$TMP/rc"
assert_contains "$TMP/log" 'arg=-c'
assert_contains "$TMP/log" 'arg=command'
assert_contains "$TMP/log" 'arg=two'

PI_HOST_SHELL=bash PI_HOST_RC_FILE="$TMP/rc" PI_NO_RC_CONFIG=0 run_launcher
assert_contains "$TMP/log" 'shell=bash'
assert_contains "$TMP/log" 'arg=-i'
assert_contains "$TMP/log" 'arg=--rcfile'
assert_contains "$TMP/log" "arg=$TMP/rc"
if grep -Fq 'arg=-c' "$TMP/log"; then fail 'interactive bash must not receive -c'; fi

PI_HOST_SHELL=zsh PI_HOST_RC_FILE="$TMP/rc" PI_NO_RC_CONFIG=1 run_launcher command
assert_contains "$TMP/log" 'shell=zsh'
assert_contains "$TMP/log" 'arg=-f'
assert_contains "$TMP/log" 'arg=-i'
if grep -Fq "arg=$TMP/rc" "$TMP/log"; then fail 'zsh no-rc mode must not use the rc file'; fi

PI_HOST_SHELL=bash PI_HOST_RC_FILE="$TMP/rc" PI_NO_RC_CONFIG=1 run_launcher command
assert_contains "$TMP/log" 'shell=bash'
assert_contains "$TMP/log" 'arg=--noprofile'
assert_contains "$TMP/log" 'arg=--norc'
assert_contains "$TMP/log" 'arg=-i'
if grep -Fq "arg=$TMP/rc" "$TMP/log"; then fail 'bash no-rc mode must not use the rc file'; fi

: > "$TMP/rc"
PI_HOST_SHELL=bash PI_HOST_RC_FILE="$TMP/rc" PI_NO_RC_CONFIG=0 \
  gtimeout 5 /bin/bash "$LAUNCHER" /usr/bin/printf 'bash-real-launch' >"$TMP/bash-real.out" 2>"$TMP/bash-real.err" \
  || fail "real bash command must exit successfully: $(<"$TMP/bash-real.err")"
grep -Fqx 'bash-real-launch' "$TMP/bash-real.out" || fail 'real bash must execute command arguments'

if PI_HOST_SHELL=fish PI_NO_RC_CONFIG=1 /bin/bash "$LAUNCHER" >/dev/null 2>"$TMP/error"; then
  fail 'unsupported shell must fail'
fi
[[ $(<"$TMP/error") == *'unsupported shell'* ]] || fail 'unsupported shell error is missing'

printf 'pi shell launcher tests passed\n'
