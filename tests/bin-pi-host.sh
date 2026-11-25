#!/usr/bin/env bash
# pi --host: native Pi lookup, passthrough, conflicts, and the installer offer. Docker must never run.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.bash"
source "$ROOT/tests/lib/launcher.bash"

WS=$(make_workspace "$TEST_HOME/projects/alpha")
OTHER=$(make_workspace "$TEST_HOME/projects/other workspace")
WRAPPER_LINK_DIR=$TMP_DIR/link-bin
PATH_NATIVE_DIR=$TMP_DIR/path-native
SYSTEM_BIN=$TMP_DIR/system-bin
LAUNCHER=$TEST_HOME/.pi/agent/bin/pi
PATH_NATIVE=$PATH_NATIVE_DIR/pi
INSTALLED_TEMPLATE=$TMP_DIR/installed-pi
FAKE_INSTALLER=$TMP_DIR/install.sh
CURL_LOG=$TMP_DIR/curl.log
INSTALLER_LOG=$TMP_DIR/installer.log
NATIVE_LOG=$TMP_DIR/native.log
export CURL_LOG INSTALLER_LOG NATIVE_LOG FAKE_INSTALLER INSTALLED_TEMPLATE

mkdir -p "$WRAPPER_LINK_DIR" "$PATH_NATIVE_DIR" "$SYSTEM_BIN"
# PATH reaches the wrapper both through a symlink, like ~/.local/bin/pi, and
# through the repository's bin directory. The system bash is linked in so the
# wrapper's env shebang works without exposing other host commands named pi.
ln -s "$ROOT/bin/pi" "$WRAPPER_LINK_DIR/pi"
[[ -L $ROOT/bin/pi && $(readlink -- "$ROOT/bin/pi") == pi-container && $ROOT/bin/pi -ef $ROOT/bin/pi-container ]] ||
  fail 'bin/pi is not a relative symlink to bin/pi-container'
ln -s "$(command -v bash)" "$SYSTEM_BIN/bash"
HOST_PATH=$FAKE_BIN:$WRAPPER_LINK_DIR:$ROOT/bin:$PATH_NATIVE_DIR:$SYSTEM_BIN:/usr/bin:/bin

cat > "$FAKE_BIN/curl" <<'FAKE_CURL'
#!/bin/sh
printf 'curl %s\n' "$*" >> "$CURL_LOG"
if [ "${FAKE_CURL_FAIL-}" = 1 ]; then
  exit 22
fi
cat "$FAKE_INSTALLER"
FAKE_CURL
chmod +x "$FAKE_BIN/curl"

# Stands in for https://pi.dev/install.sh: records what it sees and installs a
# launcher where the official installer keeps its script.
cat > "$FAKE_INSTALLER" <<'FAKE_INSTALL'
{
  printf 'cwd=%s\n' "$(pwd -P)"
  printf 'path=%s\n' "$PATH"
  printf 'pi=%s\n' "$(command -v pi || printf none)"
} >> "$INSTALLER_LOG"
if [ "${FAKE_INSTALL_ACTION-}" = install ]; then
  agent_dir=${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}
  mkdir -p "$agent_dir/bin"
  cp "$INSTALLED_TEMPLATE" "$agent_dir/bin/pi"
  chmod +x "$agent_dir/bin/pi"
fi
exit "${FAKE_INSTALL_STATUS:-0}"
FAKE_INSTALL

# write_fake_native PATH LABEL: a native Pi that records how it was started.
write_fake_native() {
  local target=$1 label=$2
  mkdir -p -- "$(dirname -- "$target")"
  {
    printf '#!/bin/sh\n'
    printf "label='%s'\n" "$label"
    cat <<'FAKE_NATIVE'
{
  printf 'native=%s\n' "$label"
  printf 'cwd=%s\n' "$(pwd -P)"
  for arg in "$@"; do
    printf 'arg=%s\n' "$arg"
  done
} >> "$NATIVE_LOG"
FAKE_NATIVE
  } > "$target"
  chmod +x "$target"
}

# run_host CWD ARGS...: run the wrapper with the host PATH and HOST_ENV entries.
HOST_ENV=()
run_host() {
  local cwd=$1
  shift
  : > "$CURL_LOG"
  : > "$INSTALLER_LOG"
  : > "$NATIVE_LOG"
  EXTRA_ENV=(PATH="$HOST_PATH" "${HOST_ENV[@]}")
  run_pi "$cwd" "$@"
  EXTRA_ENV=()
  HOST_ENV=()
  INPUT=''
}

show_host_run() {
  printf '%s\n--- native ---\n%s\n' "$(show_run)" "$(cat -- "$NATIVE_LOG")"
}

assert_empty() {
  [[ ! -s $1 ]] || fail "expected ${1##*/} to be empty"$'\n'"$(show_host_run)"
}

assert_line() {
  grep -Fqx -- "$2" "$1" || fail "missing line in ${1##*/}: $2"$'\n'"$(show_host_run)"
}

# assert_native LABEL CWD ARGS...: which native Pi ran, from which directory,
# with exactly these arguments.
assert_native() {
  local expected argument
  expected="native=$1"$'\n'"cwd=$2"
  shift 2
  for argument in "$@"; do expected+=$'\n'"arg=$argument"; done
  assert_eq "$(cat -- "$NATIVE_LOG")" "$expected" 'native Pi invocation'
}

write_fake_native "$INSTALLED_TEMPLATE" installed

# The installer launcher wins over PATH, Pi arguments pass through unchanged,
# and Docker is never used.
write_fake_native "$LAUNCHER" launcher
write_fake_native "$PATH_NATIVE" path
run_host "$WS" --host --model test-model 'two words'
assert_status 0
assert_native launcher "$WS" --model test-model 'two words'
assert_empty "$DOCKER_LOG"

# Wrapper command names and option-like arguments pass through; a leading
# `-` is stripped, so `- --help` reaches native help.
for arguments in 'list' 'update' 'stop' 'shell --root' 'copy --all' 'remove --all' '--version'; do
  read -r -a words <<< "$arguments"
  run_host "$WS" --host "${words[@]}"
  assert_status 0
  assert_native launcher "$WS" "${words[@]}"
  assert_empty "$DOCKER_LOG"
done
run_host "$WS" --host - list
assert_status 0
assert_native launcher "$WS" list
run_host "$WS" --host
assert_status 0
assert_native launcher "$WS"

# Arguments that match no wrapper option or command run native Pi the same
# way without --host, from PI_WORKSPACE or the invocation directory, and the
# home directory is allowed.
for arguments in '--version' 'install npm:x' '-p hi'; do
  read -r -a words <<< "$arguments"
  run_host "$WS" "${words[@]}"
  assert_status 0
  assert_native launcher "$WS" "${words[@]}"
  assert_empty "$DOCKER_LOG"
done
run_host "$TEST_HOME" --version
assert_status 0
assert_native launcher "$(cd -P -- "$TEST_HOME" && pwd -P)" --version
assert_empty "$DOCKER_LOG"
HOST_ENV=(PI_WORKSPACE="$OTHER")
run_host "$WS" install npm:x
assert_status 0
assert_native launcher "$OTHER" install npm:x
assert_empty "$DOCKER_LOG"

# `pi --host --help` stays local brief usage.
run_host "$WS" --host --help
assert_status 0
assert_output_has 'pi [--workspace PATH] --host [PI_ARGS...]'
assert_empty "$NATIVE_LOG"
assert_empty "$DOCKER_LOG"

# --workspace may precede --host, and relative paths resolve from the
# invocation directory.
run_host "$WS" --workspace "$OTHER" --host -p hi
assert_status 0
assert_native launcher "$OTHER" -p hi
run_host "$WS" --host '--workspace=../other workspace'
assert_status 0
assert_native launcher "$OTHER"

# PI_CODING_AGENT_DIR relocates the launcher, as it does for the installer.
write_fake_native "$TMP_DIR/agent-dir/bin/pi" custom
HOST_ENV=(PI_CODING_AGENT_DIR="$TMP_DIR/agent-dir")
run_host "$WS" --host
assert_status 0
assert_native custom "$WS"

# Without a launcher, PATH lookup skips every entry that is this wrapper, and
# wrapper command names belong to native Pi.
rm -f "$LAUNCHER"
run_host "$WS" --host update --extensions
assert_status 0
assert_native path "$WS" update --extensions
assert_empty "$DOCKER_LOG"

# A launcher path holding this wrapper, as the README may install it, is
# skipped too.
ln -s "$ROOT/bin/pi" "$LAUNCHER"
run_host "$WS" --host x
assert_status 0
assert_native path "$WS" x
assert_empty "$DOCKER_LOG"
rm -f "$LAUNCHER"

# Workspace precedence still applies, wrapper options may follow --host, and a
# leading - is dropped so native help stays reachable.
HOST_ENV=(PI_WORKSPACE="$OTHER")
run_host "$WS" --host list
assert_status 0
assert_native path "$OTHER" list
HOST_ENV=(PI_WORKSPACE="$TMP_DIR")
run_host "$WS" --host --workspace "$OTHER" - --help
assert_status 0
assert_native path "$OTHER" --help

run_host "$WS" --host --workspace "$TMP_DIR/missing"
assert_status 1
assert_output_has "pi-container: workspace does not exist: $TMP_DIR/missing"
assert_empty "$NATIVE_LOG"

# Container-only options are rejected before anything runs, in either order.
for option in --rm --replace --rebuild --keep-existing --new-state --seed --latest-state --oauth --bash --zsh --no-rc-config; do
  for order in before after; do
    if [[ $order == before ]]; then run_host "$WS" "$option" --host; else run_host "$WS" --host "$option"; fi
    assert_status 2
    assert_output_has 'pi-container: --host cannot be combined with container, state, shell, or OAuth options'
    assert_output_has 'pi-container: usage: pi [--workspace PATH] --host [PI_ARGS...]'
    assert_empty "$NATIVE_LOG"
    assert_empty "$DOCKER_LOG"
  done
done

# Without native Pi, declining the install offer or reaching EOF changes
# nothing and exits 127.
rm -f "$PATH_NATIVE"
for answer in 'n\n' '' 'yes\n'; do
  INPUT=$answer
  run_host "$WS" --host
  assert_status 127
  assert_output_has 'pi-container: native Pi was not found.'
  assert_output_has 'pi-container: run the official installer (curl -fsSL https://pi.dev/install.sh | sh)? [y/N]'
  assert_output_has 'install it with: curl -fsSL https://pi.dev/install.sh | sh'
  assert_empty "$CURL_LOG"
  assert_empty "$NATIVE_LOG"
  assert_empty "$DOCKER_LOG"
done

# Implicit host runs make the same offer; a standard input that is not a
# terminal declines it.
run_host "$WS" --version
assert_status 127
assert_output_has 'pi-container: native Pi was not found.'
assert_output_has 'install it with: curl -fsSL https://pi.dev/install.sh | sh'
assert_empty "$CURL_LOG"
assert_empty "$NATIVE_LOG"
assert_empty "$DOCKER_LOG"

# Accepting runs the official installer from the workspace. The wrapper is
# hidden from it, the launcher directory comes first so nothing shadows the
# wrapper, and Pi is not started a second time afterward.
INPUT='y\n'
HOST_ENV=(FAKE_INSTALL_ACTION=install)
run_host "$WS" --host --workspace "$OTHER" first-prompt
assert_status 0
assert_line "$CURL_LOG" 'curl -fsSL https://pi.dev/install.sh'
assert_line "$INSTALLER_LOG" "cwd=$OTHER"
assert_line "$INSTALLER_LOG" 'pi=none'
installer_path=$(sed -n 's/^path=//p' "$INSTALLER_LOG")
[[ $installer_path == "$TEST_HOME/.pi/agent/bin:"* ]] || fail "installer PATH must start with the launcher directory: $installer_path"
[[ ":$installer_path:" != *":$WRAPPER_LINK_DIR:"* && ":$installer_path:" != *":$ROOT/bin:"* ]] || fail "installer PATH still exposes the wrapper: $installer_path"
[[ ":$installer_path:" == *":$SYSTEM_BIN:"* ]] || fail "installer PATH dropped unrelated entries: $installer_path"
assert_output_has "pi-container: native Pi is ready at $LAUNCHER; start it with: pi --host"
assert_output_has 'pi-container: update native Pi with: pi --host update'
assert_empty "$NATIVE_LOG"
assert_empty "$DOCKER_LOG"

run_host "$WS" --host again
assert_status 0
assert_native installed "$WS" again

# An installer run that installs nothing reports it and exits with its
# status, or 127 when it claimed success; a failed download still fails.
rm -f "$LAUNCHER"
INPUT='y\n'
run_host "$WS" --host
assert_status 127
assert_line "$INSTALLER_LOG" "cwd=$WS"
assert_output_has 'pi-container: native Pi is still not installed'
assert_output_lacks 'native Pi is ready'

INPUT='y\n'
HOST_ENV=(FAKE_INSTALL_STATUS=3)
run_host "$WS" --host
assert_status 3
assert_output_has 'pi-container: native Pi is still not installed'
assert_empty "$DOCKER_LOG"

INPUT='y\n'
HOST_ENV=(FAKE_CURL_FAIL=1)
run_host "$WS" --host
assert_status 22
assert_empty "$INSTALLER_LOG"
assert_output_lacks 'native Pi is ready'

pass
