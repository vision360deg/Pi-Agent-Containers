#!/usr/bin/env bash
# --oauth port parsing, override contents, and reuse of this stack's bindings.
set -euo pipefail

ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN" "$TMP_DIR/tmp" "$TMP_DIR/home/path-1/workspace" "$TMP_DIR/home/path-2/workspace"
DOCKER_LOG="$TMP_DIR/docker.log"
OUTPUT_LOG="$TMP_DIR/output.log"
export DOCKER_LOG OUTPUT_LOG

cat > "$FAKE_BIN/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
set -euo pipefail

printf 'docker %s\n' "$*" >> "$DOCKER_LOG"

# FAKE_CONTAINERS rows are ID, name, status, workspace. FAKE_FOREIGN_CONTAINERS
# rows are name, workspace for containers outside the basename filter.
container_workspace() {
  local id name status path
  while IFS=$'\t' read -r id name status path; do
    [[ -n "$name" && "$name" == "$1" ]] && { printf '%s' "$path"; return 0; }
  done <<< "${FAKE_CONTAINERS-}"
  while IFS=$'\t' read -r name path; do
    [[ -n "$name" && "$name" == "$1" ]] && { printf '%s' "$path"; return 0; }
  done <<< "${FAKE_FOREIGN_CONTAINERS-}"
  return 1
}

# FAKE_ONEOFF_CONTAINERS rows are name, workspace, project for `docker compose
# run` containers, which share their project with the persistent stack.
oneoff_record() {
  local name path project
  while IFS=$'\t' read -r name path project; do
    [[ -n "$name" && "$name" == "$1" ]] && { printf '%s\t%s\n' "$path" "$project"; return 0; }
  done <<< "${FAKE_ONEOFF_CONTAINERS-}"
  return 1
}

if [[ "${1:-}" == "ps" ]]; then
  if [[ "$*" == *'label=com.docker.compose.project='* ]]; then
    wanted="$*"
    wanted="${wanted#*label=com.docker.compose.project=}"
    wanted="${wanted%% --*}"
    while IFS=$'\t' read -r name path project; do
      [[ -n "$name" && "$project" == "$wanted" ]] && printf '%s\n' "$name"
    done <<< "${FAKE_ONEOFF_CONTAINERS-}"
  elif [[ "$*" == *'label=com.pi-agents.workspace-basename='* && -n "${FAKE_CONTAINERS-}" ]]; then
    printf '%s\n' "$FAKE_CONTAINERS"
  elif [[ "$*" == *'label=com.pi-agents.workspace='* ]]; then
    # Exact-workspace lookup: ID, name, project for rows with that workspace.
    wanted="$*"
    wanted="${wanted#*label=com.pi-agents.workspace=}"
    wanted="${wanted%% --*}"
    while IFS=$'\t' read -r id name status path; do
      [[ -n "$id" && "$path" == "$wanted" ]] || continue
      printf '%s\t%s\t%s\n' "$id" "$name" "${FAKE_PROJECT:-$name}"
    done <<< "${FAKE_CONTAINERS-}"
  fi
  exit 0
fi

if [[ "${1:-}" == "rename" ]]; then
  printf 'rename %s -> %s\n' "$2" "$3" >> "$DOCKER_LOG"
  exit 0
fi

if [[ "${1:-}" == "container" && "${2:-}" == "inspect" ]]; then
  # FAKE_MOUNTED_AGENT_STATE is the agent-state volume the container mounts.
  if [[ "$*" == *'/home/node/.pi/agent'* ]]; then
    [[ -n "${FAKE_MOUNTED_AGENT_STATE-}" ]] || exit 1
    printf '%s\n' "$FAKE_MOUNTED_AGENT_STATE"
    exit 0
  fi
  container_workspace "$3" >/dev/null
  exit $?
fi

if [[ "${1:-}" == "image" && "${2:-}" == "inspect" ]]; then
  exit 0
fi

if [[ "${1:-}" == "inspect" ]]; then
  if [[ "$*" == *State.Running* ]]; then
    printf '%s\n' "${FAKE_RUNNING-false}"
  elif [[ "$*" == *NetworkSettings.Ports* ]]; then
    # FAKE_PORT_BINDINGS rows are HostIp:HostPort:port/tcp.
    printf '%s\n' "${FAKE_PORT_BINDINGS-}"
  elif [[ "$*" == *com.pi-agents.managed* ]]; then
    name="${@: -1}"
    if record="$(oneoff_record "$name")"; then
      IFS=$'\t' read -r path project <<< "$record"
      printf '/%s\037true\037%s\037%s\037pi\037True\n' "$name" "$path" "$project"
      exit 0
    fi
    path="$(container_workspace "$name")" || exit 1
    printf '/%s\037%s\037%s\037%s\037pi\037False\n' "$name" "${FAKE_MANAGED_LABEL-true}" "$path" "${FAKE_PROJECT:-$name}"
  else
    printf '%s\n' "${FAKE_PROJECT-}"
  fi
  exit 0
fi

if [[ "${1:-}" == "run" ]]; then
  # Fresh volumes report no initialization marker and no auth.
  [[ "$*" == *'exit 11'* ]] && exit 11
  [[ "$*" == *'exit 42'* ]] && exit 42
  exit 0
fi

if [[ "${1:-}" == "exec" && "$*" == *'test -x /usr/local/bin/pi-shell-launch'* ]]; then
  exit 0
fi

if [[ "${1:-}" == "volume" ]]; then
  if [[ "${2:-}" == "inspect" ]]; then
    [[ "$*" == *com.pi-agents.managed* ]] && exit 0
    # FAKE_EXISTING_VOLUMES lists volumes that already exist; removed ones are gone.
    ! grep -Fqx -- "${@: -1}" "$DOCKER_LOG.removed" 2>/dev/null || exit 1
    grep -Fqx -- "${@: -1}" <<< "${FAKE_EXISTING_VOLUMES-}" && exit 0
    exit 1
  fi
  if [[ "${2:-}" == "create" ]]; then
    exit 0
  fi
  if [[ "${2:-}" == "ls" ]]; then
    exit 0
  fi
  if [[ "${2:-}" == "rm" ]]; then
    printf '%s\n' "$*" >> "$DOCKER_LOG"
    [[ "${@: -1}" != "${FAKE_RM_FAIL-}" ]] || exit 1
    printf '%s\n' "${@: -1}" >> "$DOCKER_LOG.removed"
    exit 0
  fi
  exit 1
fi

if [[ "${1:-}" == "stop" || "${1:-}" == "rm" ]]; then
  printf '%s\n' "$*" >> "$DOCKER_LOG"
  exit 0
fi

if [[ "${1:-}" == "compose" ]]; then
  # Compose rejects project names outside [a-z0-9][a-z0-9_-]*.
  project_arguments=("$@")
  for index in "${!project_arguments[@]}"; do
    [[ "${project_arguments[$index]}" == --project-name ]] || continue
    project="${project_arguments[$((index + 1))]}"
    if ! [[ "$project" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
      printf 'invalid project name "%s"\n' "$project" >&2
      exit 1
    fi
  done
  # Record the contents of the temporary OAuth override so tests can check it.
  for index in "${!project_arguments[@]}"; do
    [[ "${project_arguments[$index]}" == --file ]] || continue
    file="${project_arguments[$((index + 1))]}"
    [[ "$(basename -- "$file")" == pi-oauth.* ]] || continue
    printf 'override %s\n' "$file" >> "$DOCKER_LOG"
    sed 's/^/override-content /' "$file" >> "$DOCKER_LOG"
  done
  printf 'PI_WORKSPACE=%s\nPI_WORKSPACE_BASENAME=%s\nPI_CONTAINER_NAME=%s\nPI_WORKSPACE_PROJECT=%s\nPI_AGENT_STATE_VOLUME_NAME=%s\nPI_SESSION_STATE_VOLUME_NAME=%s\nPI_BROWSER_STATE_VOLUME_NAME=%s\n' \
    "${PI_WORKSPACE-}" "${PI_WORKSPACE_BASENAME-}" "${PI_CONTAINER_NAME-}" \
    "${PI_WORKSPACE_PROJECT-}" "${PI_AGENT_STATE_VOLUME_NAME-}" \
    "${PI_SESSION_STATE_VOLUME_NAME-}" "${PI_BROWSER_STATE_VOLUME_NAME-}" >> "$DOCKER_LOG"
  exit 0
fi

printf 'unexpected fake docker command\n' >&2
exit 1
FAKE_DOCKER
chmod +x "$FAKE_BIN/docker"

cat > "$FAKE_BIN/lsof" <<'FAKE_LSOF'
#!/usr/bin/env bash
# Reports a listener (status 0) for each port in FAKE_BUSY_PORTS.
port=''
for argument in "$@"; do
  case "$argument" in -iTCP:*) port="${argument#-iTCP:}" ;; esac
done
[[ " ${FAKE_BUSY_PORTS-} " == *" $port "* ]]
FAKE_LSOF
chmod +x "$FAKE_BIN/lsof"

run_wrapper() {
  local workspace="$1"
  shift
  : > "$DOCKER_LOG"
  : > "$DOCKER_LOG.removed"
  : > "$OUTPUT_LOG"
  (
    cd "$workspace"
    env -u PI_WORKSPACE TMPDIR="$TMP_DIR/tmp" PI_AGENT_CONTAINERS_CONFIG_PATH="$TMP_DIR/state-registry" HOME="$TMP_DIR/home" PATH="$FAKE_BIN:$PATH" "$ROOT/bin/pi" "$@"
  ) >"$OUTPUT_LOG" 2>&1
}

assert_log_has() {
  local expected="$1"
  if ! grep -Fq -- "$expected" "$DOCKER_LOG"; then
    printf 'missing log text:\n%s\nactual:\n%s\n' "$expected" "$(cat "$DOCKER_LOG")" >&2
    exit 1
  fi
}

assert_log_lacks() {
  local unexpected="$1"
  if grep -Fq -- "$unexpected" "$DOCKER_LOG"; then
    printf 'unexpected log text:\n%s\nactual:\n%s\n' "$unexpected" "$(cat "$DOCKER_LOG")" >&2
    exit 1
  fi
}

unset PI_OAUTH_CALLBACK_PORTS
PATH_1="$(cd -P -- "$TMP_DIR/home/path-1/workspace" && pwd)"

assert_output_has() {
  if ! grep -Fq -- "$1" "$OUTPUT_LOG"; then
    printf 'missing output text:\n%s\nactual:\n%s\n' "$1" "$(cat "$OUTPUT_LOG")" >&2
    exit 1
  fi
}

assert_output_lacks() {
  if grep -Fq -- "$1" "$OUTPUT_LOG"; then
    printf 'unexpected output text:\n%s\nactual:\n%s\n' "$1" "$(cat "$OUTPUT_LOG")" >&2
    exit 1
  fi
}

# assert_override_ports PORTS...: the override publishes exactly these ports on
# IPv4 and IPv6 loopback, in order.
assert_override_ports() {
  local expected=$'override-content services:\noverride-content   pi:\noverride-content     ports:' port actual
  for port in "$@"; do
    expected+=$'\n'"override-content       - \"127.0.0.1:$port:$port\""
    expected+=$'\n'"override-content       - \"[::1]:$port:$port\""
  done
  actual="$(grep '^override-content ' "$DOCKER_LOG" | awk '!seen[$0]++')"
  if [[ "$actual" != "$expected" ]]; then
    printf 'override contents differ\nexpected:\n%s\nactual:\n%s\n' "$expected" "$actual" >&2
    exit 1
  fi
}

assert_no_override() {
  assert_log_lacks 'override '
}

assert_override_removed() {
  if [[ -n "$(find "$TMP_DIR/tmp" -name 'pi-oauth.*')" ]]; then
    printf 'temporary OAuth override was not removed after exit\n' >&2
    exit 1
  fi
}

# expect_invalid MESSAGE ARGS...: status 2 and no Docker call.
expect_invalid() {
  local expected="$1" status=0
  shift
  run_wrapper "$PATH_1" "$@" || status=$?
  if [[ "$status" -ne 2 ]]; then
    printf 'pi %s exited %s, expected 2\n' "$*" "$status" >&2
    exit 1
  fi
  assert_output_has "$expected"
  if [[ -s "$DOCKER_LOG" ]]; then
    printf 'pi %s called docker:\n%s\n' "$*" "$(cat "$DOCKER_LOG")" >&2
    exit 1
  fi
}

export FAKE_CONTAINERS=$'id-1\tpi-agents-pi-workspace\tUp 2 minutes\t'$PATH_1

# The known callbacks need no override; custom ports get an override that
# publishes each on IPv4 and IPv6 loopback, removed after the wrapper exits.
run_wrapper "$PATH_1" --oauth
assert_log_has '/compose.oauth.yml'
assert_no_override
assert_override_removed

run_wrapper "$PATH_1" --oauth 7000,7001
assert_override_ports 7000 7001
assert_override_removed

# Space-separated lists, trailing commas, --oauth=, and known ports in the list.
run_wrapper "$PATH_1" --oauth 7002 7003, 1455
assert_override_ports 7002 7003
run_wrapper "$PATH_1" --oauth=7004,7005
assert_override_ports 7004 7005
run_wrapper "$PATH_1" --oauth=7006,
assert_override_ports 7006
run_wrapper "$PATH_1" --oauth=
assert_log_has '/compose.oauth.yml'
assert_no_override

# PI_OAUTH_CALLBACK_PORTS adds comma- or space-separated ports to the CLI list.
PI_OAUTH_CALLBACK_PORTS='7010, 7011 7012' run_wrapper "$PATH_1" --oauth 7013
assert_override_ports 7013 7010 7011 7012
assert_override_removed

# Invalid ports fail before Docker; the environment list is ignored without --oauth.
expect_invalid 'pi: invalid OAuth callback port list: 1,,2' --oauth=1,,2
expect_invalid 'pi: invalid OAuth callback port list: x' --oauth=x
expect_invalid 'pi: OAuth callback port must be between 1 and 65535 in --oauth: 0' --oauth 0
PI_OAUTH_CALLBACK_PORTS=abc expect_invalid 'PI_OAUTH_CALLBACK_PORTS' --oauth
PI_OAUTH_CALLBACK_PORTS=abc run_wrapper "$PATH_1"
assert_log_has 'up --detach pi'

# A port this stack publishes on only one loopback address is still its own
# and is reused, even though it appears busy on the host.
IPV4_ONLY=$'127.0.0.1:7000:7000/tcp'
IPV6_ONLY=$'::1:7000:7000/tcp'
for bindings in "$IPV4_ONLY" "$IPV6_ONLY"; do
  FAKE_BUSY_PORTS='7000' FAKE_PORT_BINDINGS="$bindings" run_wrapper "$PATH_1" --oauth 7000
  assert_output_lacks 'already in use'
  assert_log_has 'up --detach pi'
  assert_override_ports 7000
done

# A disposable --rm run cannot reuse the stack's custom port.
status=0
FAKE_BUSY_PORTS='7000' FAKE_PORT_BINDINGS="$IPV4_ONLY" run_wrapper "$PATH_1" --rm --oauth 7000 || status=$?
[[ "$status" -eq 2 ]] || { printf 'disposable run on a stack port exited %s, expected 2\n' "$status" >&2; exit 1; }
assert_output_has 'pi: OAuth callback port is already in use: 7000'
assert_log_lacks 'run --rm'
assert_override_removed

printf 'bin/pi oauth tests passed\n'
