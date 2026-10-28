#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
TMP_DIR="$(cd -P -- "$TMP_DIR" && pwd)"

FAKE_BIN="$TMP_DIR/fake-bin"
WRAPPER_LINK_DIR="$TMP_DIR/link-bin"
PATH_NATIVE_DIR="$TMP_DIR/path-native"
SYSTEM_BIN="$TMP_DIR/system-bin"
HOST_HOME="$TMP_DIR/home"
WORKSPACE="$TMP_DIR/workspace"
OTHER_WORKSPACE="$TMP_DIR/other workspace"
LAUNCHER="$HOST_HOME/.pi/agent/bin/pi"
PATH_NATIVE="$PATH_NATIVE_DIR/pi"
INSTALLED_TEMPLATE="$TMP_DIR/installed-pi"
FAKE_INSTALLER="$TMP_DIR/install.sh"
DOCKER_LOG="$TMP_DIR/docker.log"
CURL_LOG="$TMP_DIR/curl.log"
INSTALLER_LOG="$TMP_DIR/installer.log"
NATIVE_LOG="$TMP_DIR/native.log"
OUTPUT_LOG="$TMP_DIR/output.log"
export DOCKER_LOG CURL_LOG INSTALLER_LOG NATIVE_LOG FAKE_INSTALLER INSTALLED_TEMPLATE

mkdir -p "$FAKE_BIN" "$WRAPPER_LINK_DIR" "$PATH_NATIVE_DIR" "$SYSTEM_BIN" "$HOST_HOME" "$WORKSPACE" "$OTHER_WORKSPACE"
# PATH reaches the wrapper both through a symlink, like ~/.local/bin/pi, and
# through the repository's bin directory. The system bash is linked in so the
# wrapper's env shebang works without exposing other host commands named pi.
ln -s "$ROOT/bin/pi" "$WRAPPER_LINK_DIR/pi"
ln -s "$(command -v bash)" "$SYSTEM_BIN/bash"
printf 'y\n' > "$TMP_DIR/answer-yes"
printf 'n\n' > "$TMP_DIR/answer-no"

cat > "$FAKE_BIN/docker" <<'FAKE_DOCKER'
#!/bin/sh
printf 'docker %s\n' "$*" >> "$DOCKER_LOG"
FAKE_DOCKER

cat > "$FAKE_BIN/curl" <<'FAKE_CURL'
#!/bin/sh
printf 'curl %s\n' "$*" >> "$CURL_LOG"
if [ "${FAKE_CURL_FAIL-}" = 1 ]; then
  exit 22
fi
cat "$FAKE_INSTALLER"
FAKE_CURL
chmod +x "$FAKE_BIN/docker" "$FAKE_BIN/curl"

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
FAKE_INSTALL

write_fake_native() {
  local target="$1"
  local label="$2"
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

# Usage: [WRAPPER_INPUT=file] run_wrapper [NAME=value...] -- [WRAPPER_ARGS...]
run_wrapper() {
  local -a assignments=()
  while [[ "$1" != -- ]]; do
    assignments+=("$1")
    shift
  done
  shift
  : > "$DOCKER_LOG"
  : > "$CURL_LOG"
  : > "$INSTALLER_LOG"
  : > "$NATIVE_LOG"
  STATUS=0
  (
    cd "$WORKSPACE"
    env -u PI_WORKSPACE -u PI_CODING_AGENT_DIR -u PI_MANAGED_INSTALL_ROOT \
      HOME="$HOST_HOME" \
      PI_AGENT_CONTAINERS_CONFIG_PATH="$TMP_DIR/config" \
      PATH="$FAKE_BIN:$WRAPPER_LINK_DIR:$ROOT/bin:$PATH_NATIVE_DIR:$SYSTEM_BIN:/usr/bin:/bin" \
      "${assignments[@]}" \
      "$ROOT/bin/pi" "$@"
  ) < "${WRAPPER_INPUT:-/dev/null}" > "$OUTPUT_LOG" 2>&1 || STATUS=$?
}

fail() {
  printf 'FAIL: %s\n--- output ---\n%s\n--- native ---\n%s\n--- docker ---\n%s\n' \
    "$1" "$(cat "$OUTPUT_LOG")" "$(cat "$NATIVE_LOG")" "$(cat "$DOCKER_LOG")" >&2
  exit 1
}

assert_status() {
  [[ "$STATUS" -eq "$1" ]] || fail "expected status $1, got $STATUS"
}

assert_contains() {
  grep -Fq -- "$2" "$1" || fail "missing text in ${1##*/}: $2"
}

assert_lacks() {
  ! grep -Fq -- "$2" "$1" || fail "unexpected text in ${1##*/}: $2"
}

assert_line() {
  grep -Fqx -- "$2" "$1" || fail "missing line in ${1##*/}: $2"
}

assert_empty() {
  [[ ! -s "$1" ]] || fail "expected ${1##*/} to be empty, got: $(cat "$1")"
}

# Asserts which native Pi ran, from which directory, with exactly these args.
assert_native() {
  local label="$1"
  local cwd="$2"
  local expected
  shift 2
  expected="$(
    printf 'native=%s\ncwd=%s\n' "$label" "$cwd"
    for arg in "$@"; do
      printf 'arg=%s\n' "$arg"
    done
  )"
  [[ "$(cat "$NATIVE_LOG")" == "$expected" ]] || fail "native Pi invocation mismatch; expected:
$expected"
}

write_fake_native "$INSTALLED_TEMPLATE" installed

# The installer launcher wins over PATH, Pi arguments pass through unchanged,
# and Docker is never used.
write_fake_native "$LAUNCHER" launcher
write_fake_native "$PATH_NATIVE" path
run_wrapper -- --host --model test-model 'two words'
assert_status 0
assert_native launcher "$WORKSPACE" --model test-model 'two words'
assert_empty "$DOCKER_LOG"

# PI_CODING_AGENT_DIR relocates the launcher, as it does for the installer.
write_fake_native "$TMP_DIR/agent-dir/bin/pi" custom
run_wrapper PI_CODING_AGENT_DIR="$TMP_DIR/agent-dir" -- --host
assert_status 0
assert_native custom "$WORKSPACE"

# Without a launcher, PATH lookup skips every entry that is this wrapper, and
# wrapper command names belong to native Pi.
rm -f "$LAUNCHER"
run_wrapper -- --host update --extensions
assert_status 0
assert_native path "$WORKSPACE" update --extensions
assert_empty "$DOCKER_LOG"

# Workspace precedence still applies, wrapper options may follow --host, and a
# leading - is dropped so native help stays reachable.
run_wrapper PI_WORKSPACE="$OTHER_WORKSPACE" -- --host list
assert_status 0
assert_native path "$OTHER_WORKSPACE" list
run_wrapper PI_WORKSPACE="$TMP_DIR" -- --host --workspace "$OTHER_WORKSPACE" - --help
assert_status 0
assert_native path "$OTHER_WORKSPACE" --help

run_wrapper -- --host --workspace "$TMP_DIR/missing"
assert_status 1
assert_contains "$OUTPUT_LOG" "pi: workspace does not exist: $TMP_DIR/missing"
assert_empty "$NATIVE_LOG"

# Container-only options are rejected before anything runs, in either order.
for option in --rm --replace --rebuild --keep-existing --new-state --seed --latest-state --oauth --bash --zsh --no-rc-config; do
  run_wrapper -- --host "$option"
  assert_status 2
  assert_contains "$OUTPUT_LOG" 'pi: --host cannot be combined with'
  assert_empty "$NATIVE_LOG"
  assert_empty "$DOCKER_LOG"
done
run_wrapper -- --rm --host
assert_status 2
assert_empty "$NATIVE_LOG"
assert_empty "$DOCKER_LOG"

# Without native Pi, declining the install offer or reaching EOF changes
# nothing and exits 127.
rm -f "$PATH_NATIVE"
WRAPPER_INPUT="$TMP_DIR/answer-no" run_wrapper -- --host
assert_status 127
assert_contains "$OUTPUT_LOG" 'pi: native Pi was not found'
assert_contains "$OUTPUT_LOG" 'curl -fsSL https://pi.dev/install.sh | sh'
assert_empty "$CURL_LOG"
assert_empty "$DOCKER_LOG"

run_wrapper -- --host
assert_status 127
assert_empty "$CURL_LOG"

# Accepting runs the official installer from the workspace. The wrapper is
# hidden from it, the launcher directory comes first so nothing shadows the
# wrapper, and Pi is not started a second time afterward.
WRAPPER_INPUT="$TMP_DIR/answer-yes" run_wrapper FAKE_INSTALL_ACTION=install -- --host --workspace "$OTHER_WORKSPACE" first-prompt
assert_status 0
assert_line "$CURL_LOG" 'curl -fsSL https://pi.dev/install.sh'
assert_line "$INSTALLER_LOG" "cwd=$OTHER_WORKSPACE"
assert_line "$INSTALLER_LOG" 'pi=none'
installer_path="$(sed -n 's/^path=//p' "$INSTALLER_LOG")"
[[ "$installer_path" == "$HOST_HOME/.pi/agent/bin:"* ]] || fail "installer PATH must start with the launcher directory: $installer_path"
[[ ":$installer_path:" != *":$WRAPPER_LINK_DIR:"* && ":$installer_path:" != *":$ROOT/bin:"* ]] || fail "installer PATH still exposes the wrapper: $installer_path"
[[ ":$installer_path:" == *":$SYSTEM_BIN:"* ]] || fail "installer PATH dropped unrelated entries: $installer_path"
assert_contains "$OUTPUT_LOG" "pi: native Pi is ready at $LAUNCHER"
assert_empty "$NATIVE_LOG"
assert_empty "$DOCKER_LOG"

run_wrapper -- --host again
assert_status 0
assert_native installed "$WORKSPACE" again

# An installer run that installs nothing, or a failed download, still fails.
rm -f "$LAUNCHER"
WRAPPER_INPUT="$TMP_DIR/answer-yes" run_wrapper -- --host
assert_status 127
assert_line "$INSTALLER_LOG" "cwd=$WORKSPACE"
assert_lacks "$OUTPUT_LOG" 'native Pi is ready'

WRAPPER_INPUT="$TMP_DIR/answer-yes" run_wrapper FAKE_CURL_FAIL=1 -- --host
assert_status 22
assert_empty "$INSTALLER_LOG"
assert_lacks "$OUTPUT_LOG" 'native Pi is ready'

printf 'bin/pi host tests passed\n'
