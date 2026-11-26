#!/usr/bin/env bash
# bin/pi-shell-launch: starting the selected shell or command with the host rc inside the container.
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.bash"
LAUNCHER="$ROOT/bin/pi-shell-launch"

assert_contains() { grep -Fqx -- "$2" "$1" || fail "missing $2"; }

[[ -x $LAUNCHER ]] || fail 'launcher must be executable'

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/tmpdir"
for shell in bash zsh; do
  cat > "$TMP_DIR/bin/$shell" <<'EOF'
#!/bin/sh
printf 'shell=%s\n' "$(basename "$0")" >> "$PI_TEST_LOG"
printf 'zdotdir=%s\n' "${ZDOTDIR-}" >> "$PI_TEST_LOG"
if [ -n "${ZDOTDIR-}" ] && [ -L "$ZDOTDIR/.zshrc" ]; then
  printf 'zshrc=%s\n' "$(readlink "$ZDOTDIR/.zshrc")" >> "$PI_TEST_LOG"
fi
for argument in "$@"; do
  printf 'arg=%s\n' "$argument" >> "$PI_TEST_LOG"
done
exit "${PI_TEST_STATUS:-0}"
EOF
  chmod 0755 "$TMP_DIR/bin/$shell"
done

run_launcher() {
  : > "$TMP_DIR/log"
  PI_TEST_LOG="$TMP_DIR/log" TMPDIR="$TMP_DIR/tmpdir" PATH="$TMP_DIR/bin:$PATH" /bin/bash "$LAUNCHER" "$@"
}
# args: the shell's arguments from the last run, in order, joined by |.
args() { sed -n 's/^arg=//p' "$TMP_DIR/log" | paste -sd '|' -; }

PI_HOST_SHELL=zsh PI_HOST_RC_FILE="$TMP_DIR/rc" PI_NO_RC_CONFIG=0 run_launcher command one
assert_contains "$TMP_DIR/log" 'shell=zsh'
assert_contains "$TMP_DIR/log" 'arg=-i'
assert_contains "$TMP_DIR/log" 'arg=-c'
assert_contains "$TMP_DIR/log" 'arg=exec "$@"'
assert_contains "$TMP_DIR/log" 'arg=pi-shell-launch'
assert_contains "$TMP_DIR/log" 'arg=command'
assert_contains "$TMP_DIR/log" 'arg=one'
assert_eq "$(args)" '-i|-c|exec "$@"|pi-shell-launch|command|one' 'zsh command arguments'
grep -Eq "^zdotdir=$TMP_DIR/tmpdir/pi-shell-launch\." "$TMP_DIR/log" || fail 'zsh must receive a private ZDOTDIR under TMPDIR'
assert_contains "$TMP_DIR/log" "zshrc=$TMP_DIR/rc"
zdotdir="$(sed -n 's/^zdotdir=//p' "$TMP_DIR/log")"
[[ ! -e $zdotdir ]] || fail 'the private ZDOTDIR must be removed after zsh exits'

# zsh runs as a child, so its exit status is preserved after cleanup.
set +e
PI_TEST_STATUS=7 PI_HOST_SHELL=zsh PI_HOST_RC_FILE="$TMP_DIR/rc" PI_NO_RC_CONFIG=0 run_launcher command one
status=$?
set -e
[[ $status -eq 7 ]] || fail "zsh exit status must be preserved, got $status"
[[ -z $(find "$TMP_DIR/tmpdir" -mindepth 1 -print) ]] || fail 'failed zsh must not leave a ZDOTDIR behind'

PI_HOST_SHELL=zsh PI_HOST_RC_FILE="$TMP_DIR/rc" PI_NO_RC_CONFIG=0 run_launcher
assert_contains "$TMP_DIR/log" 'shell=zsh'
assert_contains "$TMP_DIR/log" 'arg=-i'
assert_eq "$(args)" '-i' 'interactive zsh arguments'
if grep -Fq 'arg=-c' "$TMP_DIR/log"; then fail 'interactive zsh must not receive -c'; fi

PI_HOST_SHELL=bash PI_HOST_RC_FILE="$TMP_DIR/rc" PI_NO_RC_CONFIG=0 run_launcher command two
assert_contains "$TMP_DIR/log" 'shell=bash'
assert_contains "$TMP_DIR/log" 'arg=-i'
assert_contains "$TMP_DIR/log" 'arg=--rcfile'
assert_contains "$TMP_DIR/log" "arg=$TMP_DIR/rc"
assert_contains "$TMP_DIR/log" 'arg=-c'
assert_contains "$TMP_DIR/log" 'arg=command'
assert_contains "$TMP_DIR/log" 'arg=two'
assert_eq "$(args)" "--rcfile|$TMP_DIR/rc|-i|-c|exec \"\$@\"|pi-shell-launch|command|two" 'bash command arguments'

PI_HOST_SHELL=bash PI_HOST_RC_FILE="$TMP_DIR/rc" PI_NO_RC_CONFIG=0 run_launcher
assert_contains "$TMP_DIR/log" 'shell=bash'
assert_contains "$TMP_DIR/log" 'arg=-i'
assert_contains "$TMP_DIR/log" 'arg=--rcfile'
assert_contains "$TMP_DIR/log" "arg=$TMP_DIR/rc"
assert_eq "$(args)" "--rcfile|$TMP_DIR/rc|-i" 'interactive bash arguments'
if grep -Fq 'arg=-c' "$TMP_DIR/log"; then fail 'interactive bash must not receive -c'; fi

PI_HOST_SHELL=zsh PI_HOST_RC_FILE="$TMP_DIR/rc" PI_NO_RC_CONFIG=1 run_launcher command
assert_contains "$TMP_DIR/log" 'shell=zsh'
assert_contains "$TMP_DIR/log" 'arg=-f'
assert_contains "$TMP_DIR/log" 'arg=-i'
assert_eq "$(args)" '-f|-i|-c|exec "$@"|pi-shell-launch|command' 'zsh no-rc arguments'
assert_contains "$TMP_DIR/log" 'zdotdir='
if grep -Fq 'zshrc=' "$TMP_DIR/log"; then fail 'zsh no-rc mode must not get a private rc'; fi
if grep -Fq "arg=$TMP_DIR/rc" "$TMP_DIR/log"; then fail 'zsh no-rc mode must not use the rc file'; fi

PI_HOST_SHELL=bash PI_HOST_RC_FILE="$TMP_DIR/rc" PI_NO_RC_CONFIG=1 run_launcher command
assert_contains "$TMP_DIR/log" 'shell=bash'
assert_contains "$TMP_DIR/log" 'arg=--noprofile'
assert_contains "$TMP_DIR/log" 'arg=--norc'
assert_contains "$TMP_DIR/log" 'arg=-i'
assert_eq "$(args)" '--noprofile|--norc|-i|-c|exec "$@"|pi-shell-launch|command' 'bash no-rc arguments'
if grep -Fq "arg=$TMP_DIR/rc" "$TMP_DIR/log"; then fail 'bash no-rc mode must not use the rc file'; fi
PI_HOST_SHELL=bash PI_NO_RC_CONFIG=1 run_launcher
assert_eq "$(sed -n 's/^arg=//p' "$TMP_DIR/log" | paste -sd '|' -)" '--noprofile|--norc|-i' 'interactive bash no-rc arguments'

# Defaults: bash with the mounted rc path.
(unset PI_HOST_SHELL PI_HOST_RC_FILE PI_NO_RC_CONFIG; run_launcher)
assert_contains "$TMP_DIR/log" 'shell=bash'
assert_eq "$(sed -n 's/^arg=//p' "$TMP_DIR/log" | paste -sd '|' -)" '--rcfile|/tmp/pi-host-shellrc/rc|-i' 'default shell arguments'

# Without PI_HOST_RC_FILE the launcher uses the rc file the shell-rc Compose
# override mounts (inside /tmp/pi-host-shellrc), not the mount directory. The
# fake shells only record arguments, so nothing outside $TMP_DIR is touched.
(unset PI_HOST_RC_FILE; PI_HOST_SHELL=bash PI_NO_RC_CONFIG=0 run_launcher)
assert_contains "$TMP_DIR/log" 'arg=/tmp/pi-host-shellrc/rc'
(unset PI_HOST_RC_FILE; PI_HOST_SHELL=zsh PI_NO_RC_CONFIG=0 run_launcher)
assert_contains "$TMP_DIR/log" 'zshrc=/tmp/pi-host-shellrc/rc'

# A real bash runs the command after loading the rc file.
printf 'export PI_RC_LOADED=yes\n' > "$TMP_DIR/rc"
PI_HOST_SHELL=bash PI_HOST_RC_FILE="$TMP_DIR/rc" PI_NO_RC_CONFIG=0 \
  gtimeout 5 /bin/bash "$LAUNCHER" /bin/bash -c 'printf "bash-real-launch rc=%s\n" "$PI_RC_LOADED"' >"$TMP_DIR/bash-real.out" 2>"$TMP_DIR/bash-real.err" </dev/null \
  || fail "real bash command must exit successfully: $(<"$TMP_DIR/bash-real.err")"
grep -Fqx 'bash-real-launch rc=yes' "$TMP_DIR/bash-real.out" || fail "real bash must load the rc and execute command arguments: $(<"$TMP_DIR/bash-real.out")"

status=0
PI_HOST_SHELL=fish PI_NO_RC_CONFIG=1 /bin/bash "$LAUNCHER" >/dev/null 2>"$TMP_DIR/error" || status=$?
assert_eq "$status" 2 'unsupported shell status'
assert_file_has "$TMP_DIR/error" 'pi-shell-launch: unsupported shell: fish'

pass
