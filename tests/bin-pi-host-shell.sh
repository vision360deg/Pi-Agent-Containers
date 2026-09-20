#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN="$TMP_DIR/bin"
WORKSPACE="$TMP_DIR/workspace"
HOST_HOME="$TMP_DIR/home"
DOCKER_LOG="$TMP_DIR/docker.log"
OUTPUT_LOG="$TMP_DIR/output.log"
mkdir -p "$FAKE_BIN" "$WORKSPACE" "$HOST_HOME"
export DOCKER_LOG

cat > "$FAKE_BIN/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
set -euo pipefail

printf 'docker %s\n' "$*" >> "$DOCKER_LOG"

if [[ "${1:-}" == compose ]]; then
  printf 'PI_HOST_SHELL=%s\n' "${PI_HOST_SHELL-<unset>}" >> "$DOCKER_LOG"
  printf 'PI_HOST_RC_SOURCE=%s\n' "${PI_HOST_RC_SOURCE-<unset>}" >> "$DOCKER_LOG"
  printf 'PI_HOST_RC_FILE=%s\n' "${PI_HOST_RC_FILE-<unset>}" >> "$DOCKER_LOG"
  printf 'PI_NO_RC_CONFIG=%s\n' "${PI_NO_RC_CONFIG-<unset>}" >> "$DOCKER_LOG"
  exit 0
fi

if [[ "${1:-}" == ps ]]; then
  printf '%s\n' "${FAKE_CONTAINERS-}"
  exit 0
fi

if [[ "${1:-}" == inspect ]]; then
  if [[ "${FAKE_NO_RC_MOUNT-}" == 1 ]]; then
    exit 0
  fi
  printf 'mounted\n'
  exit 0
fi

if [[ "${1:-}" == exec && "$*" == *'test -x /usr/local/bin/pi-shell-launch'* ]]; then
  [[ "${FAKE_NO_LAUNCHER-}" != 1 ]]
  exit $?
fi

if [[ "${1:-}" == volume ]]; then
  case "${2:-}" in
    inspect) exit 1 ;;
    ls|create) exit 0 ;;
  esac
fi

case "${1:-}" in
  exec|run|start) exit 0 ;;
esac

printf 'unexpected Docker command: %s\n' "$*" >&2
exit 99
FAKE_DOCKER
chmod +x "$FAKE_BIN/docker"

run_wrapper() {
  local host_shell="$1"
  local state_path="$2"
  shift 2
  : > "$DOCKER_LOG"
  : > "$OUTPUT_LOG"
  (
    cd "$WORKSPACE"
    env -u PI_WORKSPACE \
      SHELL="$host_shell" \
      PI_AGENT_CONTAINERS_CONFIG_PATH="$state_path" \
      HOME="$HOST_HOME" \
      FAKE_CONTAINERS="${FAKE_CONTAINERS-}" \
      FAKE_NO_RC_MOUNT="${FAKE_NO_RC_MOUNT-}" \
      FAKE_NO_LAUNCHER="${FAKE_NO_LAUNCHER-}" \
      PATH="$FAKE_BIN:$PATH" \
      "$ROOT/bin/pi" "$@"
  ) >"$OUTPUT_LOG" 2>&1
}

assert_log_has() {
  local expected="$1"
  if ! grep -Fq -- "$expected" "$DOCKER_LOG"; then
    printf 'missing Docker log text:\n%s\nactual:\n%s\n' "$expected" "$(cat "$DOCKER_LOG")" >&2
    exit 1
  fi
}

assert_log_has_line() {
  local expected="$1"
  if ! grep -Fqx -- "$expected" "$DOCKER_LOG"; then
    printf 'missing Docker log line:\n%s\nactual:\n%s\n' "$expected" "$(cat "$DOCKER_LOG")" >&2
    exit 1
  fi
}

assert_no_docker() {
  if [[ -s "$DOCKER_LOG" ]]; then
    printf 'expected no Docker calls, got:\n%s\n' "$(cat "$DOCKER_LOG")" >&2
    exit 1
  fi
}

assert_status_2() {
  local description="$1"
  shift
  if "$@"; then
    printf '%s unexpectedly succeeded\n' "$description" >&2
    exit 1
  else
    local status=$?
    if [[ "$status" -ne 2 ]]; then
      printf '%s returned status %s, expected 2\n' "$description" "$status" >&2
      exit 1
    fi
  fi
}

printf 'export FROM_PROFILE=yes\n' > "$HOST_HOME/.profile"
printf 'source ~/.profile\nexport FROM_ZSHRC=yes\n' > "$HOST_HOME/.zshrc"
printf 'export FROM_BASH_PROFILE=yes\n' > "$HOST_HOME/.bash_profile"
printf 'export FROM_BASHRC=yes\n' > "$HOST_HOME/.bashrc"

# Default selection follows the basename of SHELL and prepares a stable
# per-workspace rc file.
DEFAULT_STATE="$TMP_DIR/default-state"
run_wrapper /usr/local/bin/zsh "$DEFAULT_STATE" --version
zsh_rc_dirs=("$DEFAULT_STATE"/shell-rc/*)
[[ "${#zsh_rc_dirs[@]}" -eq 1 && -d "${zsh_rc_dirs[0]}" ]]
zsh_rc_file="${zsh_rc_dirs[0]}/rc"
[[ -f "$zsh_rc_file" ]]
grep -Fq 'export FROM_PROFILE=yes' "$zsh_rc_file"
grep -Fq 'export FROM_ZSHRC=yes' "$zsh_rc_file"
assert_log_has_line 'PI_HOST_SHELL=zsh'
assert_log_has_line "PI_HOST_RC_SOURCE=${zsh_rc_dirs[0]}"
assert_log_has_line 'PI_HOST_RC_FILE=/tmp/pi-host-shellrc/rc'
assert_log_has_line 'PI_NO_RC_CONFIG=0'
assert_log_has 'compose.shell-rc.yml'
assert_log_has 'up --build --detach pi'
assert_log_has 'exec pi pi-shell-launch pi-session-log --forward-output install npm:pi-agent-browser-native'
assert_log_has 'exec pi pi-shell-launch pi-session-log --version'

# Explicit overrides win over SHELL and rewrite the same rc source file, so an
# already-running container's read-only mount sees the selected shell's config.
run_wrapper /bin/zsh "$DEFAULT_STATE" --bash --version
bash_rc_dirs=("$DEFAULT_STATE"/shell-rc/*)
[[ "${#bash_rc_dirs[@]}" -eq 1 && "${bash_rc_dirs[0]}" == "${zsh_rc_dirs[0]}" ]]
grep -Fq 'export FROM_BASH_PROFILE=yes' "$zsh_rc_file"
grep -Fq 'export FROM_BASHRC=yes' "$zsh_rc_file"
assert_log_has_line 'PI_HOST_SHELL=bash'
assert_log_has_line "PI_HOST_RC_SOURCE=${zsh_rc_dirs[0]}"

ZSH_STATE="$TMP_DIR/zsh-state"
run_wrapper /bin/bash "$ZSH_STATE" --zsh --version
assert_log_has_line 'PI_HOST_SHELL=zsh'

# No-rc mode selects the shell without generating or mounting an rc file.
NO_RC_STATE="$TMP_DIR/no-rc-state"
run_wrapper /bin/zsh "$NO_RC_STATE" --no-rc-config --version
[[ ! -e "$NO_RC_STATE/shell-rc" ]]
assert_log_has_line 'PI_HOST_SHELL=zsh'
assert_log_has_line 'PI_HOST_RC_SOURCE='
assert_log_has_line 'PI_NO_RC_CONFIG=1'
if grep -Fq 'compose.shell-rc.yml' "$DOCKER_LOG"; then
  printf 'no-rc mode unexpectedly enabled the rc Compose override\n' >&2
  exit 1
fi
assert_log_has 'exec pi pi-shell-launch pi-session-log --version'

# Disposable Pi and extension installation both use the shell launcher.
RM_STATE="$TMP_DIR/rm-state"
run_wrapper /bin/bash "$RM_STATE" --rm --version
assert_log_has 'run --build --rm pi pi-shell-launch pi install npm:pi-agent-browser-native'
assert_log_has 'run --build --rm --service-ports pi pi-shell-launch pi --version'

# Existing-container shell attachment uses the helper and preserves root ordering.
WORKSPACE_PATH="$(cd -P -- "$WORKSPACE" && pwd)"
FAKE_CONTAINERS=$'current-id\tpi-agents-pi-workspace\tUp 1 minute\trunning\t'"$WORKSPACE_PATH"
SHELL_STATE="$TMP_DIR/shell-state"
run_wrapper /bin/zsh "$SHELL_STATE" shell
assert_log_has 'docker exec -it --env PI_HOST_SHELL=zsh --env PI_HOST_RC_FILE=/tmp/pi-host-shellrc/rc --env PI_NO_RC_CONFIG=0 pi-agents-pi-workspace pi-shell-launch'

# Normal shell attachment reconciles a current container previously created
# with --no-rc-config before trying to source the generated rc.
FAKE_NO_RC_MOUNT=1 run_wrapper /bin/zsh "$SHELL_STATE" shell
assert_log_has 'compose.shell-rc.yml'
assert_log_has 'up --build --detach pi'
assert_log_has 'docker exec -it --env PI_HOST_SHELL=zsh --env PI_HOST_RC_FILE=/tmp/pi-host-shellrc/rc --env PI_NO_RC_CONFIG=0 pi-agents-pi-workspace pi-shell-launch'

# If an older image is already mounted/configured but lacks the new helper,
# rebuild and recreate the current workspace container before attaching.
FAKE_NO_LAUNCHER=1 run_wrapper /bin/zsh "$SHELL_STATE" shell
assert_log_has 'up --build --detach --force-recreate pi'
assert_log_has 'docker exec -it --env PI_HOST_SHELL=zsh --env PI_HOST_RC_FILE=/tmp/pi-host-shellrc/rc --env PI_NO_RC_CONFIG=0 pi-agents-pi-workspace pi-shell-launch'

run_wrapper /bin/zsh "$SHELL_STATE" shell --root
assert_log_has 'docker exec -it --user 0 --env PI_HOST_SHELL=zsh --env PI_HOST_RC_FILE=/tmp/pi-host-shellrc/rc --env PI_NO_RC_CONFIG=0 pi-agents-pi-workspace pi-shell-launch'

run_wrapper /bin/bash "$SHELL_STATE" --no-rc-config shell
assert_log_has 'docker exec -it --env PI_HOST_SHELL=bash --env PI_HOST_RC_FILE=/tmp/pi-host-shellrc/rc --env PI_NO_RC_CONFIG=1 pi-agents-pi-workspace pi-shell-launch'

# Invalid selection fails before any Docker command.
INVALID_STATE="$TMP_DIR/invalid-state"
assert_status_2 'mutually exclusive shell overrides' run_wrapper /bin/bash "$INVALID_STATE" --bash --zsh --version
assert_no_docker
grep -Fq -- '--bash and --zsh are mutually exclusive' "$OUTPUT_LOG"

assert_status_2 'unsupported host shell' run_wrapper /usr/bin/fish "$INVALID_STATE" --version
assert_no_docker
grep -Fq 'unsupported host shell: fish' "$OUTPUT_LOG"

# Read-only inventory does not generate startup configuration.
FAKE_CONTAINERS=''
LIST_STATE="$TMP_DIR/list-state"
run_wrapper /bin/zsh "$LIST_STATE" list
[[ ! -e "$LIST_STATE/shell-rc" ]]

# The long-lived service supervisor remains Bash.
grep -Fq 'command: ["bash", "-lc", "pi-session-forwarder & exec sleep infinity"]' "$ROOT/compose.yml"

printf 'bin/pi host shell tests passed\n'
