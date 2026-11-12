#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN" "$TMP_DIR/home/path-1/workspace" "$TMP_DIR/home/path-2/workspace"
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
    env -u PI_WORKSPACE PI_AGENT_CONTAINERS_CONFIG_PATH="$TMP_DIR/state-registry" HOME="$TMP_DIR/home" PATH="$FAKE_BIN:$PATH" "$ROOT/bin/pi" "$@"
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

HOME_ROOT="$TMP_DIR/home"
PATH_1="$(cd -P -- "$HOME_ROOT/path-1/workspace" && pwd)"
PATH_2="$(cd -P -- "$HOME_ROOT/path-2/workspace" && pwd)"
path_hash() {
  printf '%s' "$1" | shasum -a 256 | awk '{print substr($1, 1, 12)}'
}
TARGET_1="pi-agents-pi-path-1-workspace-$(path_hash "$PATH_1")"
TARGET_2="pi-agents-pi-path-2-workspace-$(path_hash "$PATH_2")"

unset FAKE_CONTAINERS
run_wrapper "$PATH_1"
assert_log_has '--project-name pi-agents-pi-workspace'
assert_log_lacks '--project-name pi-agents-ws-'
assert_log_has 'PI_CONTAINER_NAME=pi-agents-pi-workspace'
assert_log_has 'PI_WORKSPACE_PROJECT=pi-agents-pi-workspace'
grep -Eq '^PI_AGENT_STATE_VOLUME_NAME=pi-agents-ws-[a-z0-9]+_pi-agent-state$' "$DOCKER_LOG"
grep -Eq '^PI_SESSION_STATE_VOLUME_NAME=pi-agents-ws-[a-z0-9]+_pi-sessions$' "$DOCKER_LOG"
grep -Eq '^PI_BROWSER_STATE_VOLUME_NAME=pi-agents-ws-[a-z0-9]+_agent-browser-state$' "$DOCKER_LOG"
assert_log_has "PI_WORKSPACE=$PATH_1"

# Compose project names cannot contain dots, so a dotted basename is mapped
# to hyphens and the launch proceeds.
mkdir -p "$HOME_ROOT/src/my.project"
DOTTED="$(cd -P -- "$HOME_ROOT/src/my.project" && pwd)"
run_wrapper "$DOTTED"
assert_log_has '--project-name pi-agents-pi-my-project '
assert_log_has 'PI_CONTAINER_NAME=pi-agents-pi-my-project'
assert_log_has 'up --detach pi'

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

NORMAL_1="pi-agents-ws-$(path_hash "$PATH_1")_pi-agent-state"
EXTRA_1="pi-agents-new-ws-$(path_hash "$PATH_1")_pi-agent-state"

# --new-state creates the extra volume with its own kind label and runs on it
# while sessions and browser state stay on the normal volumes.
run_wrapper "$PATH_1" --new-state
assert_log_has "PI_AGENT_STATE_VOLUME_NAME=$EXTRA_1"
assert_log_has 'com.pi-agents.state-kind=agent-extra'
assert_log_has "com.pi-agents.workspace=$PATH_1 --label com.pi-agents.project=pi-agents-pi-workspace $EXTRA_1"
assert_log_lacks "$NORMAL_1"
assert_log_has 'PI_SESSION_STATE_VOLUME_NAME=pi-agents-ws-'
assert_log_has 'up --detach --force-recreate pi'
assert_log_lacks 'up --build'

# Each start on the extra volume says so and names the untouched normal state.
FAKE_EXISTING_VOLUMES="$EXTRA_1" run_wrapper "$PATH_1" --new-state
assert_output_has "pi: warning: using the extra state volume $EXTRA_1; the normal state volume $NORMAL_1 is untouched"
assert_log_lacks 'com.pi-agents.state-kind=agent-extra'

# Omitting --new-state moves a container mounted on the extra volume back to
# the normal state and warns that the extra volume is unused.
FAKE_EXISTING_VOLUMES="$EXTRA_1" FAKE_MOUNTED_AGENT_STATE="$EXTRA_1" run_wrapper "$PATH_1"
assert_log_has "PI_AGENT_STATE_VOLUME_NAME=$NORMAL_1"
assert_log_has 'up --detach --force-recreate pi'
assert_output_has "pi: warning: an extra state volume $EXTRA_1 exists and is not in use"
assert_output_has 'pi remove --all'

# A container already on the normal volume is reused, still with the warning.
FAKE_EXISTING_VOLUMES="$EXTRA_1" FAKE_MOUNTED_AGENT_STATE="$NORMAL_1" run_wrapper "$PATH_1"
assert_log_has 'up --detach pi'
assert_log_lacks 'force-recreate'
assert_output_has "pi: warning: an extra state volume $EXTRA_1 exists and is not in use"

# Without an extra volume there is no warning.
FAKE_MOUNTED_AGENT_STATE="$NORMAL_1" run_wrapper "$PATH_1"
assert_output_lacks 'extra state volume'

# Disposable runs warn too.
FAKE_EXISTING_VOLUMES="$EXTRA_1" run_wrapper "$PATH_1" --rm --new-state
assert_log_has "PI_AGENT_STATE_VOLUME_NAME=$EXTRA_1"
assert_output_has "pi: warning: using the extra state volume $EXTRA_1"

export FAKE_CONTAINERS=$'id-1\tpi-agents-pi-workspace\tUp 2 minutes\t'$PATH_1
if printf 'c\n' | run_wrapper "$PATH_2"; then
  printf 'collision cancel unexpectedly succeeded\n' >&2
  exit 1
fi
assert_log_lacks 'rename'
grep -Fq '¡¡¡ WARNING !!!' "$OUTPUT_LOG"

printf 'r\n' | run_wrapper "$PATH_2"
assert_log_has "rename pi-agents-pi-workspace -> $TARGET_1"
assert_log_has "PI_CONTAINER_NAME=$TARGET_2"
assert_log_has "compose --project-name $TARGET_2"
assert_log_has 'up --detach --force-recreate pi'
assert_log_lacks 'up --build'

# Every rename destination is validated before the first rename: a target
# name held by another workspace aborts without renaming anything.
export FAKE_FOREIGN_CONTAINERS="$TARGET_1"$'\t'"$HOME_ROOT/elsewhere"
if printf 'r\n' | run_wrapper "$PATH_2"; then
  printf 'occupied rename target unexpectedly succeeded\n' >&2
  exit 1
fi
grep -Fq "disambiguated container name is occupied: $TARGET_1" "$OUTPUT_LOG"
assert_log_lacks 'rename'
assert_log_lacks ' up '
unset FAKE_FOREIGN_CONTAINERS

# Two stacks claiming the same workspace are ambiguous and refused.
export FAKE_CONTAINERS=$'id-1\tpi-agents-pi-workspace\tUp 2 minutes\t'$PATH_1$'\nid-2\t'"$TARGET_1"$'\tExited (0) 1 hour ago\t'$PATH_1
if run_wrapper "$PATH_1"; then
  printf 'duplicate workspace stacks unexpectedly succeeded\n' >&2
  exit 1
fi
grep -Fq "multiple managed stacks found for workspace: $PATH_1" "$OUTPUT_LOG"
assert_log_lacks ' up '

# `pi --rm` one-off containers live in the workspace's own project, so a
# running or leftover one-off of the same workspace does not block launches.
export FAKE_CONTAINERS=$'id-1\tpi-agents-pi-workspace\tUp 2 minutes\t'$PATH_1
export FAKE_ONEOFF_CONTAINERS=$'pi-agents-pi-workspace-pi-run-0123abcd\t'"$PATH_1"$'\tpi-agents-pi-workspace'
run_wrapper "$PATH_1"
assert_log_has 'up --detach pi'
assert_output_lacks 'occupied'
run_wrapper "$PATH_1" --rm
assert_log_has 'run --rm --service-ports pi'
assert_output_lacks 'occupied'
unset FAKE_CONTAINERS
run_wrapper "$PATH_1"
assert_log_has 'up --detach pi'

# A one-off belonging to another workspace still marks the project occupied.
export FAKE_ONEOFF_CONTAINERS=$'pi-agents-pi-workspace-pi-run-0123abcd\t'"$PATH_2"$'\tpi-agents-pi-workspace'
for arguments in '' --rm; do
  if run_wrapper "$PATH_1" $arguments; then
    printf 'foreign one-off container did not block pi %s\n' "$arguments" >&2
    exit 1
  fi
  assert_output_has 'workspace Compose project is occupied: pi-agents-pi-workspace'
  assert_log_lacks ' up '
  assert_log_lacks 'run --rm --service-ports'
done
unset FAKE_ONEOFF_CONTAINERS

# Containers created before the managed label existed are still reused.
export FAKE_CONTAINERS=$'id-1\tpi-agents-pi-workspace\tUp 2 minutes\t'$PATH_1
FAKE_MANAGED_LABEL='<no value>' run_wrapper "$PATH_1"
assert_log_has 'PI_CONTAINER_NAME=pi-agents-pi-workspace'
assert_log_has 'up --detach pi'

export FAKE_CONTAINERS=$'id-1\tpi-agents-pi-workspace\tExited (0) 3 hours ago\t'$PATH_1
if printf 'c\n' | run_wrapper "$PATH_2"; then
  printf 'stopped-container collision cancel unexpectedly succeeded\n' >&2
  exit 1
fi
assert_log_lacks 'rename'
if grep -Fq '¡¡¡ WARNING !!!' "$OUTPUT_LOG"; then
  printf 'stopped-container collision incorrectly emitted running warning\n' >&2
  exit 1
fi

export FAKE_CONTAINERS=$'id-1\tpi-agents-pi-workspace\tUp 2 minutes\t'$PATH_1
run_wrapper "$PATH_2" --keep-existing
assert_log_lacks 'rename pi-agents-pi-workspace'
assert_log_has "PI_CONTAINER_NAME=$TARGET_2"
assert_log_has "compose --project-name $TARGET_2"

STACK_1=$'id-1\tpi-agents-pi-workspace\tUp 2 minutes\t'$PATH_1
SESSIONS_1="pi-agents-ws-$(path_hash "$PATH_1")_pi-sessions"
BROWSER_1="pi-agents-ws-$(path_hash "$PATH_1")_agent-browser-state"

unset FAKE_CONTAINERS
run_wrapper "$PATH_1" --replace
assert_log_has 'up --detach --force-recreate pi'
assert_log_lacks 'up --build'

export FAKE_CONTAINERS="$STACK_1"
run_wrapper "$PATH_1" stop
assert_log_has 'compose --project-name pi-agents-pi-workspace'
assert_log_has ' stop'
assert_log_lacks ' up '

# stop and remove act on this workspace's own stack, even when its name was
# disambiguated, and never on the basename project of another workspace.
export FAKE_CONTAINERS="$STACK_1"$'\nid-2\t'"$TARGET_2"$'\tUp 1 minute\t'$PATH_2
run_wrapper "$PATH_2" stop
assert_log_has "compose --project-name $TARGET_2"
assert_log_has ' stop'
assert_log_lacks 'compose --project-name pi-agents-pi-workspace '
assert_log_lacks 'rename'

# Without a stack, stop and remove fail instead of acting on a computed name.
export FAKE_CONTAINERS="$STACK_1"
for command in stop remove; do
  if run_wrapper "$PATH_2" "$command"; then
    printf '%s without a stack unexpectedly succeeded\n' "$command" >&2
    exit 1
  elif [[ $? -ne 2 ]]; then
    printf '%s without a stack returned an unexpected status\n' "$command" >&2
    exit 1
  fi
  assert_output_has "pi: no stack found for workspace: $PATH_2"
  assert_log_lacks 'docker compose'
done

# Two stacks for one workspace are ambiguous.
export FAKE_CONTAINERS="$STACK_1"$'\nid-3\t'"$TARGET_1"$'\tExited (0) 1 hour ago\t'$PATH_1
if run_wrapper "$PATH_1" stop; then
  printf 'stop with duplicate stacks unexpectedly succeeded\n' >&2
  exit 1
fi
assert_output_has "pi: multiple stacks found for workspace: $PATH_1"
assert_log_lacks 'docker compose'

# --rm needs no existing stack and uses this workspace's own project.
export FAKE_CONTAINERS="$STACK_1"
run_wrapper "$PATH_2" --rm
assert_log_has "compose --project-name $TARGET_2"
assert_log_has 'run --rm --service-ports pi'
assert_log_lacks 'compose --project-name pi-agents-pi-workspace '
assert_log_lacks 'rename'

export FAKE_CONTAINERS="$STACK_1"
run_wrapper "$PATH_1" remove
assert_log_has 'compose --project-name pi-agents-pi-workspace'
assert_log_has ' down'
assert_log_lacks 'down --volumes'
assert_log_lacks 'volume rm'
assert_output_lacks 'extra state volume'

# Removing the stack keeps the extra state volume and says so.
FAKE_EXISTING_VOLUMES="$EXTRA_1" run_wrapper "$PATH_1" remove
assert_log_has ' down'
assert_log_lacks 'volume rm'
assert_output_has "pi: warning: state volumes are kept, including the extra state volume $EXTRA_1"

run_wrapper "$PATH_1" remove --all
assert_log_has 'compose --project-name pi-agents-pi-workspace'
assert_log_has ' down'
assert_log_lacks 'down --volumes'

# remove --all also removes the extra state volume.
FAKE_EXISTING_VOLUMES="$NORMAL_1"$'\n'"$EXTRA_1" run_wrapper "$PATH_1" remove --all
assert_log_has "volume rm $NORMAL_1"
assert_log_has "volume rm $EXTRA_1"
assert_output_lacks 'extra state volume'

# remove --all without a stack offers the workspace's leftover volumes.
unset FAKE_CONTAINERS
LEFTOVERS="$NORMAL_1"$'\n'"$SESSIONS_1"$'\n'"$BROWSER_1"$'\n'"$EXTRA_1"

if run_wrapper "$PATH_1" remove --all; then
  printf 'remove --all without stack or volumes unexpectedly succeeded\n' >&2
  exit 1
fi
assert_output_has "pi: no stack or state volumes found for workspace: $PATH_1"
assert_log_lacks 'volume rm'
assert_log_lacks 'docker compose'

for answer in 'l' '' EOF; do
  if [[ "$answer" == EOF ]]; then
    FAKE_EXISTING_VOLUMES="$LEFTOVERS" run_wrapper "$PATH_1" remove --all < /dev/null
  else
    printf '%s\n' "$answer" | FAKE_EXISTING_VOLUMES="$LEFTOVERS" run_wrapper "$PATH_1" remove --all
  fi
  assert_output_has "pi: no stack found for workspace: $PATH_1"
  assert_output_has "1) $NORMAL_1"
  assert_output_has "4) $EXTRA_1"
  assert_output_has 'kind: agent-extra'
  assert_output_has 'state volumes left unchanged'
  assert_log_lacks 'volume rm'
  assert_log_lacks 'docker compose'
done

# Deleting the seed volume clears the seed when no other state remains.
mkdir -p "$TMP_DIR/state-registry"
printf '%s\n' "$NORMAL_1" > "$TMP_DIR/state-registry/seed"
printf 'a\n' | FAKE_EXISTING_VOLUMES="$LEFTOVERS" run_wrapper "$PATH_1" remove --all
for volume in "$NORMAL_1" "$SESSIONS_1" "$BROWSER_1" "$EXTRA_1"; do
  assert_log_has "volume rm $volume"
  assert_output_has "pi: removed state volume $volume"
done
assert_log_lacks 'docker compose'
[[ ! -s "$TMP_DIR/state-registry/seed" ]] || {
  printf 'seed pointer still names a deleted volume: %s\n' "$(cat "$TMP_DIR/state-registry/seed")" >&2
  exit 1
}

printf 's\n2, 4\n' | FAKE_EXISTING_VOLUMES="$LEFTOVERS" run_wrapper "$PATH_1" remove --all
assert_log_has "volume rm $SESSIONS_1"
assert_log_has "volume rm $EXTRA_1"
assert_log_lacks "volume rm $NORMAL_1"
assert_log_lacks "volume rm $BROWSER_1"

printf 's\n\n' | FAKE_EXISTING_VOLUMES="$LEFTOVERS" run_wrapper "$PATH_1" remove --all
assert_output_has 'state volumes left unchanged'
assert_log_lacks 'volume rm'

for input in $'s\n5\n' $'s\n1 x\n' $'s\n1,1\n' $'d\n'; do
  if printf '%s' "$input" | FAKE_EXISTING_VOLUMES="$LEFTOVERS" run_wrapper "$PATH_1" remove --all; then
    printf 'invalid remove selection unexpectedly succeeded: %q\n' "$input" >&2
    exit 1
  elif [[ $? -ne 2 ]]; then
    printf 'invalid remove selection returned an unexpected status: %q\n' "$input" >&2
    exit 1
  fi
  assert_log_lacks 'volume rm'
done

# A failed removal is reported, the others still go, and the status is 1.
if printf 'a\n' | FAKE_RM_FAIL="$SESSIONS_1" FAKE_EXISTING_VOLUMES="$LEFTOVERS" run_wrapper "$PATH_1" remove --all; then
  printf 'remove --all with a failed volume removal unexpectedly succeeded\n' >&2
  exit 1
elif [[ $? -ne 1 ]]; then
  printf 'remove --all with a failed volume removal returned an unexpected status\n' >&2
  exit 1
fi
assert_output_has "pi: could not remove state volume $SESSIONS_1"
assert_log_has "volume rm $BROWSER_1"
assert_log_has "volume rm $EXTRA_1"

# stop and remove refuse a stack whose Compose project also holds another
# workspace's container, before any compose stop or down.
export FAKE_CONTAINERS=$'id-1\tpi-agents-pi-workspace\tUp 2 minutes\t'$PATH_1
export FAKE_ONEOFF_CONTAINERS="pi-agents-pi-workspace-run-1"$'\t'"$PATH_2"$'\tpi-agents-pi-workspace'
for command in stop remove; do
  status=0
  run_wrapper "$PATH_1" "$command" || status=$?
  [[ "$status" -ne 0 ]] || { printf 'pi %s on a shared project succeeded\n' "$command" >&2; exit 1; }
  assert_output_has 'pi: workspace Compose project is shared with another stack'
  assert_log_lacks ' stop'
  assert_log_lacks ' down'
done
unset FAKE_ONEOFF_CONTAINERS

printf 'bin/pi workspace tests passed\n'
