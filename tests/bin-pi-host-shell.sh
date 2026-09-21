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
FAKE_REBUILT_MARKER="$TMP_DIR/image-rebuilt"
mkdir -p "$FAKE_BIN" "$WORKSPACE" "$HOST_HOME"
mkdir -p "$HOST_HOME/.pi/agent"
printf '%s\n' '{"quietStartup":true,"shellCommandPrefix":"printf custom-prefix"}' > "$HOST_HOME/.pi/agent/settings.json"
export DOCKER_LOG FAKE_REBUILT_MARKER

cat > "$FAKE_BIN/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
set -euo pipefail

printf 'docker %s\n' "$*" >> "$DOCKER_LOG"

if [[ "${1:-}" == compose ]]; then
  if [[ " $* " == *' --build '* || " $* " == *' build pi '* ]]; then
    : > "$FAKE_REBUILT_MARKER"
  fi
  if [[ "$*" == *'exec -T pi test -x /usr/local/bin/pi-shell-launch'* &&
    "${FAKE_NO_LAUNCHER-}" == 1 && ! -e "$FAKE_REBUILT_MARKER" ]]; then
    exit 1
  fi
  if [[ " $* " == *' run '* && "$*" == *'pi-shell-launch'* &&
    "${FAKE_NO_LAUNCHER-}" == 1 && ! -e "$FAKE_REBUILT_MARKER" ]]; then
    printf 'pi: image lacks pi-shell-launch; run pi update or use --rebuild\n' >&2
    exit 2
  fi
  if [[ " $* " == *' exec -T pi sh -c '* ]]; then
    docker_args=("$@")
    setup_script=''
    for ((index = 0; index < ${#docker_args[@]}; index++)); do
      if (( index > 0 && index + 1 < ${#docker_args[@]} )) &&
        [[ "${docker_args[index]}" == -c && "${docker_args[index-1]}" == sh ]]; then
        setup_script=${docker_args[index+1]}
        break
      fi
    done
    [[ -n "$setup_script" ]] || { printf 'missing settings setup script\n' >&2; exit 99; }
    bash -c "$setup_script"
    exit $?
  fi
  if [[ " $* " == *' run --rm --entrypoint /bin/sh pi -c '* ]]; then
    docker_args=("$@")
    setup_script=''
    for ((index = 0; index < ${#docker_args[@]}; index++)); do
      if (( index > 0 && index + 3 < ${#docker_args[@]} )) &&
        [[ "${docker_args[index]}" == -c && "${docker_args[index-1]}" == pi ]]; then
        setup_script=${docker_args[index+3]}
        break
      fi
    done
    if [[ -n "$setup_script" ]]; then
      bash -c "$setup_script"
      exit $?
    fi
  fi
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
  [[ "${FAKE_NO_LAUNCHER-}" != 1 || -e "$FAKE_REBUILT_MARKER" ]]
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
  local invocation_home="${FAKE_HOME:-$HOST_HOME}"
  shift 2
  : > "$DOCKER_LOG"
  : > "$OUTPUT_LOG"
  rm -f "$FAKE_REBUILT_MARKER"
  (
    cd "$WORKSPACE"
    env -u PI_WORKSPACE \
      SHELL="$host_shell" \
      PI_AGENT_CONTAINERS_CONFIG_PATH="$state_path" \
      HOME="$invocation_home" \
      FAKE_CONTAINERS="${FAKE_CONTAINERS-}" \
      FAKE_NO_RC_MOUNT="${FAKE_NO_RC_MOUNT-}" \
      FAKE_NO_LAUNCHER="${FAKE_NO_LAUNCHER-}" \
      FAKE_REBUILT_MARKER="$FAKE_REBUILT_MARKER" \
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

assert_log_lacks() {
  local unexpected="$1"
  if grep -Fq -- "$unexpected" "$DOCKER_LOG"; then
    printf 'unexpected Docker log text:\n%s\nactual:\n%s\n' "$unexpected" "$(cat "$DOCKER_LOG")" >&2
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

printf 'export FROM_PROFILE=yes\nalias ll="printf host-ll"\n' > "$HOST_HOME/.profile"
printf 'source ~/.profile\nexport FROM_ZSHRC=yes\n' > "$HOST_HOME/.zshrc"
printf 'source ~/.profile\nexport FROM_BASH_PROFILE=yes\n' > "$HOST_HOME/.bash_profile"
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
SHELL_COMMAND_PREFIX=$(jq -r '.shellCommandPrefix' "$HOST_HOME/.pi/agent/settings.json")
[[ "$SHELL_COMMAND_PREFIX" == *'printf custom-prefix'* ]]
[[ "$SHELL_COMMAND_PREFIX" == *'shopt -s expand_aliases'* ]]
[[ "$SHELL_COMMAND_PREFIX" == *'pi-agents managed host shell aliases'* ]]
assert_log_has 'grep -E'
ALIAS_OUTPUT=$(PI_NO_RC_CONFIG=0 PI_HOST_RC_FILE="$zsh_rc_file" \
  /bin/bash -c "${SHELL_COMMAND_PREFIX}"$'\nll' 2>&1)
[[ "$ALIAS_OUTPUT" == *'host-ll'* ]] || {
  printf 'Pi shellCommandPrefix failed to expand the host ll alias:\n%s\n' "$ALIAS_OUTPUT" >&2
  exit 1
}
if PI_NO_RC_CONFIG=1 PI_HOST_RC_FILE="$zsh_rc_file" \
  /bin/bash -c "${SHELL_COMMAND_PREFIX}"$'\nll' > "$TMP_DIR/no-rc-alias.out" 2>&1; then
  printf 'no-rc command prefix unexpectedly expanded the host alias\n' >&2
  exit 1
fi
if grep -Fq 'host-ll' "$TMP_DIR/no-rc-alias.out"; then
  printf 'no-rc command prefix unexpectedly loaded host aliases\n' >&2
  exit 1
fi
[[ $(jq -r '.shellCommandPrefix' "$HOST_HOME/.pi/agent/settings.json" | grep -Fc 'pi-agents managed host shell aliases') -eq 1 ]]
assert_log_has_line 'PI_HOST_SHELL=zsh'
assert_log_has_line "PI_HOST_RC_SOURCE=${zsh_rc_dirs[0]}"
assert_log_has_line 'PI_HOST_RC_FILE=/tmp/pi-host-shellrc/rc'
assert_log_has_line 'PI_NO_RC_CONFIG=0'
assert_log_has 'compose.shell-rc.yml'
assert_log_has 'up --detach pi'
assert_log_lacks '--build'
assert_log_has 'exec pi pi-shell-launch pi-session-log --forward-output install npm:pi-agent-browser-native'
assert_log_has 'exec pi pi-shell-launch pi-session-log --version'

if FAKE_NO_LAUNCHER=1 run_wrapper /usr/local/bin/zsh "$DEFAULT_STATE" --version; then
  printf 'persistent launch with stale image unexpectedly succeeded\n' >&2
  exit 1
else
  status=$?
  [[ "$status" -eq 2 ]]
fi
grep -Fq 'image lacks pi-shell-launch' "$OUTPUT_LOG"
grep -Fq 'pi update' "$OUTPUT_LOG"
assert_log_lacks 'up --build'
assert_log_lacks 'install npm:pi-agent-browser-native'

# Explicit overrides win over SHELL and rewrite the same rc source file, so an
# already-running container's read-only mount sees the selected shell's config.
run_wrapper /bin/zsh "$DEFAULT_STATE" --bash --version
bash_rc_dirs=("$DEFAULT_STATE"/shell-rc/*)
[[ "${#bash_rc_dirs[@]}" -eq 1 && "${bash_rc_dirs[0]}" == "${zsh_rc_dirs[0]}" ]]
grep -Fq 'export FROM_BASH_PROFILE=yes' "$zsh_rc_file"
grep -Fq 'export FROM_BASHRC=yes' "$zsh_rc_file"
grep -Fq 'alias ll="printf host-ll"' "$zsh_rc_file"
ALIAS_OUTPUT=$(PI_NO_RC_CONFIG=0 PI_HOST_RC_FILE="$zsh_rc_file" \
  /bin/bash -c "${SHELL_COMMAND_PREFIX}"$'\nll' 2>&1)
[[ "$ALIAS_OUTPUT" == *'host-ll'* ]] || fail 'Bash host startup chain did not supply ll to Pi commands'
assert_log_has_line 'PI_HOST_SHELL=bash'
assert_log_has_line "PI_HOST_RC_SOURCE=${zsh_rc_dirs[0]}"

ZSH_STATE="$TMP_DIR/zsh-state"
run_wrapper /bin/bash "$ZSH_STATE" --zsh --version
assert_log_has_line 'PI_HOST_SHELL=zsh'

REBUILD_STATE="$TMP_DIR/rebuild-state"
run_wrapper /bin/bash "$REBUILD_STATE" --rebuild --version
assert_log_has 'up --build --detach pi'
assert_log_lacks '--no-cache'
assert_log_lacks ' --pull '

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
assert_log_lacks 'exec -T pi sh -c'

# Disposable Pi and extension installation both use the shell launcher.
RM_STATE="$TMP_DIR/rm-state"
RM_HOME="$TMP_DIR/rm-home"
mkdir -p "$RM_HOME/.pi/agent"
printf '%s\n' '{"shellCommandPrefix":"printf rm-custom-prefix"}' > "$RM_HOME/.pi/agent/settings.json"
printf 'alias ll="printf rm-host-ll"\n' > "$RM_HOME/.profile"
printf 'source ~/.profile\n' > "$RM_HOME/.bash_profile"
FAKE_HOME="$RM_HOME" run_wrapper /bin/bash "$RM_STATE" --rm --version
assert_log_has 'run --rm --entrypoint /bin/sh pi -c'
assert_log_has 'pi-agents managed host shell aliases'
assert_log_has '[ ! -x /usr/local/bin/pi-shell-launch ]'
assert_log_has 'run pi update or use --rebuild'
assert_log_has 'run --rm --service-ports pi pi-shell-launch pi --version'
assert_log_lacks 'run --build'
compose_run_count="$(grep -Ec '^docker compose .* run --' "$DOCKER_LOG" || true)"
[[ "$compose_run_count" -eq 2 ]]
[[ "$(jq -r '.shellCommandPrefix' "$RM_HOME/.pi/agent/settings.json")" == *'rm-custom-prefix'* ]]
RM_PREFIX=$(jq -r '.shellCommandPrefix' "$RM_HOME/.pi/agent/settings.json")
rm_rc_dirs=("$RM_STATE"/shell-rc/*)
RM_ALIAS_OUTPUT=$(PI_NO_RC_CONFIG=0 PI_HOST_RC_FILE="${rm_rc_dirs[0]}/rc" \
  /bin/bash -c "${RM_PREFIX}"$'\nll' 2>&1)
[[ "$RM_ALIAS_OUTPUT" == *'rm-host-ll'* ]] || fail 'one-off Pi launch did not configure host aliases'

if FAKE_NO_LAUNCHER=1 run_wrapper /bin/bash "$RM_STATE" --rm --version; then
  printf 'disposable launch with stale image unexpectedly succeeded\n' >&2
  exit 1
else
  status=$?
  [[ "$status" -eq 2 ]]
fi
grep -Fq 'image lacks pi-shell-launch' "$OUTPUT_LOG"
grep -Fq 'pi update' "$OUTPUT_LOG"
assert_log_lacks 'run --build'
assert_log_lacks 'build pi'

FAKE_NO_LAUNCHER=1 run_wrapper /bin/bash "$RM_STATE" --rebuild --rm --version
assert_log_has 'build pi'
assert_log_has 'run --rm --service-ports pi pi-shell-launch pi --version'
assert_log_lacks 'run --build'
assert_log_lacks '--no-cache'
compose_run_count="$(grep -Ec '^docker compose .* run --' "$DOCKER_LOG" || true)"
[[ "$compose_run_count" -eq 2 ]]

# Existing-container shell attachment uses the helper and preserves root ordering.
WORKSPACE_PATH="$(cd -P -- "$WORKSPACE" && pwd)"
FAKE_CONTAINERS=$'current-id\tpi-agents-pi-workspace\tUp 1 minute\trunning\t'"$WORKSPACE_PATH"
SHELL_STATE="$TMP_DIR/shell-state"
run_wrapper /bin/zsh "$SHELL_STATE" shell
assert_log_has 'docker exec -it --env PI_HOST_SHELL=zsh --env PI_HOST_RC_FILE=/tmp/pi-host-shellrc/rc --env PI_NO_RC_CONFIG=0 pi-agents-pi-workspace pi-shell-launch'

run_wrapper /bin/zsh "$SHELL_STATE" --rebuild shell
assert_log_has 'up --build --detach --force-recreate pi'
assert_log_has 'docker exec -it --env PI_HOST_SHELL=zsh --env PI_HOST_RC_FILE=/tmp/pi-host-shellrc/rc --env PI_NO_RC_CONFIG=0 pi-agents-pi-workspace pi-shell-launch'

# Normal shell attachment reconciles a current container previously created
# with --no-rc-config before trying to source the generated rc.
FAKE_NO_RC_MOUNT=1 run_wrapper /bin/zsh "$SHELL_STATE" shell
assert_log_has 'compose.shell-rc.yml'
assert_log_has 'up --detach pi'
assert_log_has 'docker exec -it --env PI_HOST_SHELL=zsh --env PI_HOST_RC_FILE=/tmp/pi-host-shellrc/rc --env PI_NO_RC_CONFIG=0 pi-agents-pi-workspace pi-shell-launch'

# A stale current image is diagnosed without an implicit rebuild.
if FAKE_NO_LAUNCHER=1 run_wrapper /bin/zsh "$SHELL_STATE" shell; then
  printf 'shell attachment with stale image unexpectedly succeeded\n' >&2
  exit 1
else
  status=$?
  [[ "$status" -eq 2 ]]
fi
grep -Fq 'image lacks pi-shell-launch' "$OUTPUT_LOG"
grep -Fq 'pi update' "$OUTPUT_LOG"
assert_log_lacks 'up --build'

# Explicit rebuilding repairs the current workspace image before attaching.
FAKE_NO_LAUNCHER=1 run_wrapper /bin/zsh "$SHELL_STATE" --rebuild shell
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
[[ $(jq -r '.shellCommandPrefix' "$HOST_HOME/.pi/agent/settings.json" | grep -Fc 'pi-agents managed host shell aliases') -eq 1 ]]

printf 'bin/pi host shell tests passed\n'
