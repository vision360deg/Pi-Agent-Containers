# Fake-Docker harness for bin/pi tests. Source after common.bash.
# shellcheck shell=bash

FAKE_BIN=$TMP_DIR/bin
FAKE_DOCKER_STATE=$TMP_DIR/docker-state
DOCKER_LOG=$TMP_DIR/docker.log
OUTPUT_LOG=$TMP_DIR/output.log
TEST_HOME=$TMP_DIR/home
CONFIG_DIR=$TMP_DIR/config
SEED_FILE=$CONFIG_DIR/seed
mkdir -p "$FAKE_BIN" "$FAKE_DOCKER_STATE" "$TEST_HOME" "$TMP_DIR/tmp"
cp "$ROOT/tests/lib/fake-docker" "$FAKE_BIN/docker"
cat > "$FAKE_BIN/lsof" <<'FAKE_LSOF'
#!/usr/bin/env bash
# Reports a listener (status 0) for each port in FAKE_BUSY_PORTS.
port=''
for argument in "$@"; do
  case $argument in -iTCP:*) port=${argument#-iTCP:} ;; esac
done
printf 'lsof %s\n' "$port" >> "$DOCKER_LOG"
[[ " ${FAKE_BUSY_PORTS:-} " == *" $port "* ]]
FAKE_LSOF
chmod +x "$FAKE_BIN/docker" "$FAKE_BIN/lsof"

# Extra NAME=VALUE environment entries for the next run_pi calls.
EXTRA_ENV=()
# Text fed to the launcher's standard input (printf %b escapes allowed).
INPUT=''
# Shell command whose output, as it is produced, replaces INPUT when set.
INPUT_COMMAND=''
STATUS=0

run_pi() {
  local cwd=$1
  shift
  : > "$DOCKER_LOG"
  : > "$OUTPUT_LOG"
  printf '%b' "$INPUT" > "$TMP_DIR/stdin"
  if (
    cd "$cwd" &&
      env -u PI_WORKSPACE -u PI_OAUTH_CALLBACK_PORTS -u PI_CODING_AGENT_DIR -u PI_MANAGED_INSTALL_ROOT \
        HOME="$TEST_HOME" SHELL=/bin/bash TMPDIR="$TMP_DIR/tmp" PATH="$FAKE_BIN:$PATH" \
        PI_AGENT_CONTAINERS_CONFIG_PATH="$CONFIG_DIR" DOCKER_LOG="$DOCKER_LOG" FAKE_DOCKER_STATE="$FAKE_DOCKER_STATE" \
        "${EXTRA_ENV[@]}" "$ROOT/bin/pi" "$@"
  ) < <(if [[ -n $INPUT_COMMAND ]]; then bash -c "$INPUT_COMMAND"; else cat -- "$TMP_DIR/stdin"; fi) > "$OUTPUT_LOG" 2>&1; then
    STATUS=0
  else
    STATUS=$?
  fi
}

show_run() {
  printf -- '--- output ---\n%s\n--- docker log ---\n%s\n' "$(cat -- "$OUTPUT_LOG")" "$(cat -- "$DOCKER_LOG")"
}

assert_status() {
  [[ $STATUS -eq $1 ]] || fail "exit status $STATUS, expected $1"$'\n'"$(show_run)"
}

assert_log_has() {
  grep -Fq -- "$1" "$DOCKER_LOG" || fail "docker log lacks: $1"$'\n'"$(show_run)"
}

assert_log_lacks() {
  ! grep -Fq -- "$1" "$DOCKER_LOG" || fail "docker log unexpectedly has: $1"$'\n'"$(show_run)"
}

assert_log_matches() {
  grep -Eq -- "$1" "$DOCKER_LOG" || fail "docker log does not match: $1"$'\n'"$(show_run)"
}

assert_output_has() {
  grep -Fq -- "$1" "$OUTPUT_LOG" || fail "output lacks: $1"$'\n'"$(show_run)"
}

assert_output_lacks() {
  ! grep -Fq -- "$1" "$OUTPUT_LOG" || fail "output unexpectedly has: $1"$'\n'"$(show_run)"
}

# Assert a failing run with the given message and no Docker side effects
# beyond read-only queries.
assert_fails_with() {
  assert_status "$1"
  assert_output_has "$2"
}

reset_docker() {
  rm -rf -- "$FAKE_DOCKER_STATE" "$CONFIG_DIR"
  mkdir -p "$FAKE_DOCKER_STATE"
}

workspace_hash() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print substr($1, 1, 12)}'
  else
    printf '%s' "$1" | cksum | awk '{print $1}'
  fi
}

agent_volume() { printf 'pi-agents-ws-%s_pi-agent-state' "$(workspace_hash "$1")"; }
session_volume() { printf 'pi-agents-ws-%s_pi-sessions' "$(workspace_hash "$1")"; }
browser_volume() { printf 'pi-agents-ws-%s_agent-browser-state' "$(workspace_hash "$1")"; }
extra_volume() { printf 'pi-agents-new-ws-%s_pi-agent-state' "$(workspace_hash "$1")"; }

make_workspace() {
  mkdir -p -- "$1"
  (cd -P -- "$1" && pwd -P)
}

# The sanitized workspace basename bin/pi derives container and project names from.
workspace_slug() {
  local slug
  slug=$(basename -- "$1" | tr '[:upper:]' '[:lower:]' |
    sed -e 's/[^a-z0-9_-]/-/g' -e 's/^[^a-z0-9]*//' -e 's/[^a-z0-9]*$//' -e 's/-\{2,\}/-/g')
  printf '%s' "${slug:-workspace}"
}

# fake_record FILE KEY=VALUE... ; a KEY of "-name" removes that key.
fake_record() {
  local file=$1 entry key
  local -A record=()
  shift
  if [[ -e $file ]]; then
    while IFS= read -r entry; do [[ -z $entry ]] || record[${entry%%=*}]=${entry#*=}; done < "$file"
  fi
  for entry in "$@"; do
    if [[ $entry == -* ]]; then unset "record[${entry#-}]"; else record[${entry%%=*}]=${entry#*=}; fi
  done
  mkdir -p -- "$(dirname -- "$file")"
  for key in "${!record[@]}"; do printf '%s=%s\n' "$key" "${record[$key]}"; done > "$file"
}

# fake_container NAME WORKSPACE STATE [KEY=VALUE...]; STATE is running or exited.
# Containers from before the managed label: pass -label.com.pi-agents.managed.
fake_container() {
  local name=$1 workspace=$2 state=$3 status
  shift 3
  if [[ $state == running ]]; then status='Up 2 minutes'; else status='Exited (0) 3 hours ago'; fi
  fake_record "$FAKE_DOCKER_STATE/containers/$name" \
    "id=id-$name" "name=$name" "state=$state" "status=$status" "image=$name-pi" image-id=current \
    created=2026-01-01T00:00:00Z started=2026-01-01T00:00:01Z \
    label.com.pi-agents.managed=true "label.com.pi-agents.workspace=$workspace" \
    "label.com.pi-agents.workspace-basename=$(workspace_slug "$workspace")" "label.com.docker.compose.project=$name" \
    label.com.docker.compose.service=pi label.com.docker.compose.oneoff=False \
    "mount./home/node/.pi/agent=$(agent_volume "$workspace")" \
    "mount./home/node/.pi/agent/sessions=$(session_volume "$workspace")" \
    "mount./home/node/.agent-browser=$(browser_volume "$workspace")" \
    "mount./tmp/pi-host-shellrc=$CONFIG_DIR/shell-rc/pi-agents-ws-$(workspace_hash "$workspace")" "$@"
}

# fake_volume NAME WORKSPACE KIND CREATED [KEY=VALUE...]
# Volumes from before state labels: pass -label.com.pi-agents.managed and the
# other label keys to drop them.
fake_volume() {
  local name=$1 workspace=$2 kind=$3 created=$4
  shift 4
  fake_record "$FAKE_DOCKER_STATE/volumes/$name" "name=$name" "created=$created" \
    label.com.pi-agents.managed=true "label.com.pi-agents.workspace=$workspace" \
    "label.com.pi-agents.project=pi-agents-pi-$(workspace_slug "$workspace")" \
    "label.com.pi-agents.state-kind=$kind" "$@"
}

# fake_volume_file VOLUME RELATIVE_PATH [CONTENT]
fake_volume_file() {
  mkdir -p -- "$(dirname -- "$FAKE_DOCKER_STATE/volume-data/$1/$2")"
  printf '%s\n' "${3:-}" > "$FAKE_DOCKER_STATE/volume-data/$1/$2"
}

volume_has_file() { [[ -e $FAKE_DOCKER_STATE/volume-data/$1/$2 ]]; }
volume_exists() { [[ -e $FAKE_DOCKER_STATE/volumes/$1 ]]; }
container_exists() { [[ -e $FAKE_DOCKER_STATE/containers/$1 ]]; }
container_field() { sed -n "s|^$2=||p" "$FAKE_DOCKER_STATE/containers/$1"; }
volume_field() { sed -n "s|^$2=||p" "$FAKE_DOCKER_STATE/volumes/$1"; }

# fake_state WORKSPACE CREATED: three initialized managed volumes for a workspace.
fake_state() {
  local workspace=$1 created=$2
  fake_volume "$(agent_volume "$workspace")" "$workspace" agent "$created"
  fake_volume "$(session_volume "$workspace")" "$workspace" sessions "$created"
  fake_volume "$(browser_volume "$workspace")" "$workspace" browser "$created"
  fake_volume_file "$(agent_volume "$workspace")" .container-initialized complete
}

# fake_image PROJECT: mark the project's service image as already built.
fake_image() {
  mkdir -p -- "$FAKE_DOCKER_STATE/images"
  printf 'current\n' > "$FAKE_DOCKER_STATE/images/$1-pi"
}

seed_value() { [[ ! -e $SEED_FILE ]] || cat -- "$SEED_FILE"; }
