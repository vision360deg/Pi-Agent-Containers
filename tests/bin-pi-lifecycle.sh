#!/usr/bin/env bash
# pi stop, remove, remove --all, leftover volumes, seed repointing on removal, and list output.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.bash"
source "$ROOT/tests/lib/launcher.bash"

WS=$(make_workspace "$TEST_HOME/projects/alpha")
NAME=pi-agents-pi-alpha
FILES="--project-name $NAME --project-directory $ROOT --file $ROOT/compose.yml --file $ROOT/compose.shell-rc.yml"

existing_stack() {
  reset_docker
  fake_image "$NAME"
  fake_state "$WS" 2026-01-01T00:00:00Z
  fake_container "$NAME" "$WS" running
}

# stop stops this workspace's stack and keeps it.
existing_stack
run_pi "$WS" stop
assert_status 0
assert_log_has "$FILES stop"
assert_eq "$(container_field "$NAME" state)" exited 'stopped container state'

# remove takes the stack down and keeps its state volumes, with or without --all
# never through Compose's own volume removal.
existing_stack
run_pi "$WS" remove
assert_status 0
assert_log_has "$FILES down"
assert_log_lacks 'down --volumes'
! container_exists "$NAME" || fail 'remove must delete the container'
volume_exists "$(agent_volume "$WS")" || fail 'remove must keep the agent state'

existing_stack
run_pi "$WS" remove --all
assert_status 0
assert_log_has "$FILES down"
assert_log_lacks 'down --volumes'
! container_exists "$NAME" || fail 'remove --all must delete the container'

# --- Stacks that share a basename ---
PATH_1=$(make_workspace "$TEST_HOME/path-1/workspace")
PATH_2=$(make_workspace "$TEST_HOME/path-2/workspace")
BASE=pi-agents-pi-workspace
TARGET_1=pi-agents-pi-path-1-workspace-$(workspace_hash "$PATH_1")
TARGET_2=pi-agents-pi-path-2-workspace-$(workspace_hash "$PATH_2")
NORMAL_1=$(agent_volume "$PATH_1")
SESSIONS_1=$(session_volume "$PATH_1")
BROWSER_1=$(browser_volume "$PATH_1")
EXTRA_1=$(extra_volume "$PATH_1")

# stack_1: PATH_1's running stack under the basename project, without state volumes.
stack_1() {
  reset_docker
  fake_image "$BASE"
  fake_container "$BASE" "$PATH_1" running
}

# leftovers: PATH_1's four state volumes and no stack.
leftovers() {
  reset_docker
  fake_volume "$NORMAL_1" "$PATH_1" agent 2026-01-01T00:00:00Z
  fake_volume "$SESSIONS_1" "$PATH_1" sessions 2026-01-01T00:00:01Z
  fake_volume "$BROWSER_1" "$PATH_1" browser 2026-01-01T00:00:02Z
  fake_volume "$EXTRA_1" "$PATH_1" agent-extra 2026-01-01T00:00:03Z
}

stack_1
run_pi "$PATH_1" stop
assert_status 0
assert_log_has "compose --project-name $BASE"
assert_log_has ' stop'
assert_log_lacks ' up '

# stop and remove act on this workspace's own stack, even when its name was
# disambiguated, and never on the basename project of another workspace.
stack_1
fake_container "$TARGET_2" "$PATH_2" running
run_pi "$PATH_2" stop
assert_status 0
assert_log_has "compose --project-name $TARGET_2"
assert_log_has ' stop'
assert_log_lacks "compose --project-name $BASE "
assert_log_lacks 'rename'
assert_eq "$(container_field "$BASE" state)" running 'the other workspace stack state'

# Without a stack, stop and remove fail instead of acting on a computed name.
for command in stop remove; do
  stack_1
  run_pi "$PATH_2" "$command"
  assert_status 2
  assert_output_has "pi: no stack found for workspace: $PATH_2"
  assert_log_lacks 'docker compose'
done

# Two stacks for one workspace are ambiguous.
stack_1
fake_container "$TARGET_1" "$PATH_1" exited
run_pi "$PATH_1" stop
[[ $STATUS -ne 0 ]] || fail 'stop with duplicate stacks unexpectedly succeeded'
assert_output_has "pi: multiple stacks found for workspace: $PATH_1"
assert_log_lacks 'docker compose'

stack_1
run_pi "$PATH_1" remove
assert_status 0
assert_log_has "compose --project-name $BASE"
assert_log_has ' down'
assert_log_lacks 'down --volumes'
assert_log_lacks 'volume rm'
assert_output_lacks 'extra state volume'

# Removing the stack keeps the extra state volume and says so.
stack_1
fake_volume "$EXTRA_1" "$PATH_1" agent-extra 2026-01-01T00:00:00Z
run_pi "$PATH_1" remove
assert_status 0
assert_log_has ' down'
assert_log_lacks 'volume rm'
assert_output_has "pi: warning: state volumes are kept, including the extra state volume $EXTRA_1"
volume_exists "$EXTRA_1" || fail 'remove must keep the extra state volume'

stack_1
run_pi "$PATH_1" remove --all
assert_status 0
assert_log_has "compose --project-name $BASE"
assert_log_has ' down'
assert_log_lacks 'down --volumes'

# remove --all also removes the extra state volume.
stack_1
fake_volume "$NORMAL_1" "$PATH_1" agent 2026-01-01T00:00:00Z
fake_volume "$EXTRA_1" "$PATH_1" agent-extra 2026-01-01T00:00:00Z
run_pi "$PATH_1" remove --all
assert_status 0
assert_log_has "volume rm $NORMAL_1"
assert_log_has "volume rm $EXTRA_1"
assert_output_lacks 'extra state volume'
! volume_exists "$EXTRA_1" || fail 'remove --all must delete the extra state volume'

# remove --all without a stack offers the workspace's leftover volumes.
reset_docker
run_pi "$PATH_1" remove --all
[[ $STATUS -ne 0 ]] || fail 'remove --all without stack or volumes unexpectedly succeeded'
assert_output_has "pi: no stack or state volumes found for workspace: $PATH_1"
assert_log_lacks 'volume rm'
assert_log_lacks 'docker compose'

# Leaving them (l, Enter, or end of input) changes nothing.
for INPUT in 'l\n' '\n' ''; do
  leftovers
  run_pi "$PATH_1" remove --all
  assert_output_has "pi: no stack found for workspace: $PATH_1"
  assert_output_has "1) $NORMAL_1"
  assert_output_has "4) $EXTRA_1"
  assert_output_has 'kind: agent-extra'
  assert_output_has 'state volumes left unchanged'
  assert_log_lacks 'volume rm'
  assert_log_lacks 'docker compose'
done

# Deleting the seed volume deletes the seed pointer when no other state remains.
leftovers
mkdir -p "$CONFIG_DIR"
printf '%s\n' "$NORMAL_1" > "$SEED_FILE"
INPUT='a\n'
run_pi "$PATH_1" remove --all
assert_status 0
for volume in "$NORMAL_1" "$SESSIONS_1" "$BROWSER_1" "$EXTRA_1"; do
  assert_log_has "volume rm $volume"
  assert_output_has "pi: removed state volume $volume"
  ! volume_exists "$volume" || fail "$volume must be removed"
done
assert_log_lacks 'docker compose'
[[ ! -e $SEED_FILE ]] || fail "seed pointer was not deleted with its volume: $(seed_value)"

leftovers
INPUT='s\n2, 4\n'
run_pi "$PATH_1" remove --all
assert_status 0
assert_log_has "volume rm $SESSIONS_1"
assert_log_has "volume rm $EXTRA_1"
assert_log_lacks "volume rm $NORMAL_1"
assert_log_lacks "volume rm $BROWSER_1"

leftovers
INPUT='s\n\n'
run_pi "$PATH_1" remove --all
assert_output_has 'state volumes left unchanged'
assert_log_lacks 'volume rm'

for INPUT in 's\n5\n' 's\n1 x\n' 's\n1,1\n' 'd\n'; do
  leftovers
  run_pi "$PATH_1" remove --all
  assert_status 2
  assert_log_lacks 'volume rm'
done

# A failed removal is reported, the others still go, and the status is 1.
leftovers
INPUT='a\n'
EXTRA_ENV=("FAKE_VOLUME_RM_FAIL=$SESSIONS_1")
run_pi "$PATH_1" remove --all
EXTRA_ENV=()
assert_status 1
assert_output_has "pi: could not remove state volume $SESSIONS_1"
assert_log_has "volume rm $BROWSER_1"
assert_log_has "volume rm $EXTRA_1"
INPUT=''

# remove --all of the seed volume repoints the seed at the oldest remaining
# agent state; no volume carries this workspace's label.
SEEDED=$(make_workspace "$TEST_HOME/projects/seeded")
SEEDED_STATE=$(agent_volume "$SEEDED")
reset_docker
fake_volume "$SEEDED_STATE" "$SEEDED" agent 2026-08-06T12:00:00Z \
  -label.com.pi-agents.managed -label.com.pi-agents.workspace -label.com.pi-agents.project -label.com.pi-agents.state-kind
fake_volume pi-agents-ws-oldest_pi-agent-state /tmp/workspaces/oldest agent 2026-08-01T12:00:00Z
fake_volume pi-agents-ws-newer_pi-agent-state /tmp/workspaces/newer agent 2026-08-07T12:00:00Z
mkdir -p "$CONFIG_DIR"
printf '%s\n' "$SEEDED_STATE" > "$SEED_FILE"
INPUT='a\n'
run_pi "$SEEDED" remove --all
INPUT=''
assert_status 0
assert_eq "$(seed_value)" pi-agents-ws-oldest_pi-agent-state 'seed pointer after removing the seed volume'
! volume_exists "$SEEDED_STATE" || fail 'the seed volume must be removed'

# stop and remove refuse a stack whose Compose project also holds another
# workspace's container, before any compose stop or down.
for command in stop remove; do
  stack_1
  fake_container "$BASE-run-1" "$PATH_2" running "label.com.docker.compose.project=$BASE" label.com.docker.compose.oneoff=True
  run_pi "$PATH_1" "$command"
  [[ $STATUS -ne 0 ]] || fail "pi $command on a shared project succeeded"
  assert_output_has 'pi: workspace Compose project is shared with another stack'
  assert_log_lacks ' stop'
  assert_log_lacks ' down'
done

# --- list ---
# Alpha has an unused extra state volume; delta runs on its extra volume, which
# is newer than every normal volume yet never latest. Orphan has state volumes
# but no stack.
L_ALPHA=$(make_workspace "$TEST_HOME/list/alpha")
L_DELTA=$(make_workspace "$TEST_HOME/list/delta")
L_NONE=$(make_workspace "$TEST_HOME/list/no-agent-state")
L_ZETA=$(make_workspace "$TEST_HOME/list/zeta")
L_ORPHAN=$(make_workspace "$TEST_HOME/list/orphan")

list_stacks() {
  reset_docker
  fake_container pi-agents-pi-zeta "$L_ZETA" exited created=2026-08-08T10:00:00.000000000Z \
    started=0001-01-01T00:00:00Z
  fake_container pi-agents-pi-alpha "$L_ALPHA" running created=2026-08-08T08:00:00.000000000Z \
    started=2026-08-08T09:15:00.000000000Z label.com.docker.compose.project=
  fake_container pi-agents-pi-delta "$L_DELTA" running created=2026-08-08T07:00:00.000000000Z \
    started=2026-08-08T07:30:00.000000000Z "mount./home/node/.pi/agent=$(extra_volume "$L_DELTA")"
  fake_container pi-agents-pi-no-agent-state "$L_NONE" paused \
    created=2026-08-08T09:00:00.000000000Z started=2026-08-08T09:30:00.000000000Z -mount./home/node/.pi/agent
  # Real Docker lists --rm one-off containers unless the oneoff filter is set.
  fake_container pi-agents-pi-run-1a2b3c "$L_ALPHA" running label.com.docker.compose.project=pi-agents-pi-alpha \
    label.com.docker.compose.oneoff=True
  fake_state "$L_ALPHA" 2026-01-01T00:00:00Z
  fake_state "$L_ZETA" 2026-01-02T00:00:00Z
  fake_volume "$(agent_volume "$L_DELTA")" "$L_DELTA" agent 2026-01-03T00:00:00Z
  fake_volume "$(extra_volume "$L_ALPHA")" "$L_ALPHA" agent-extra 2026-01-05T00:00:00Z
  fake_volume "$(extra_volume "$L_DELTA")" "$L_DELTA" agent-extra 2026-01-09T00:00:00Z
  fake_volume "$(extra_volume "$L_ORPHAN")" "$L_ORPHAN" agent-extra 2026-01-04T00:00:00Z
  fake_volume "$(agent_volume "$L_ORPHAN")" "$L_ORPHAN" agent 2026-01-04T00:00:00Z
  fake_volume "$(session_volume "$L_ORPHAN")" "$L_ORPHAN" sessions 2026-01-04T00:00:00Z
  fake_volume unmanaged "$L_ORPHAN" agent 2026-01-06T00:00:00Z label.com.pi-agents.managed=false
  mkdir -p "$CONFIG_DIR"
}

assert_read_only_docker_calls() {
  local call
  while IFS= read -r call; do
    case $call in
      'docker ps '*|'docker inspect '*|'docker volume ls '*|'docker volume inspect '*) ;;
      *) fail "pi list invoked a command outside the read-only Docker list: $call"$'\n'"$(show_run)" ;;
    esac
  done < "$DOCKER_LOG"
}

stack_block() {
  printf 'STACK: %s\n  status: %s\n  workspace: %s\n  project: %s\n  created: %s\n  started: %s\n  agent-state: %s\n  active-state: %s\n  extra-state: %s\n  session-state: %s\n  browser-state: %s\n  markers: %s\n' "$@"
}

volume_block() {
  printf 'VOLUME: %s\n  kind: %s\n  workspace: %s\n  project: %s\n  created: %s\n  markers: %s\n' "$@"
}

# expected_list ALPHA DELTA ZETA ORPHAN: the markers of each agent state.
expected_list() {
  stack_block pi-agents-pi-alpha running "$L_ALPHA" '' \
    2026-08-08T08:00:00.000000000Z 2026-08-08T09:15:00.000000000Z \
    "$(agent_volume "$L_ALPHA")" normal "$(extra_volume "$L_ALPHA")" \
    "$(session_volume "$L_ALPHA")" "$(browser_volume "$L_ALPHA")" "$1"
  stack_block pi-agents-pi-delta running "$L_DELTA" pi-agents-pi-delta \
    2026-08-08T07:00:00.000000000Z 2026-08-08T07:30:00.000000000Z \
    "$(extra_volume "$L_DELTA")" extra "$(extra_volume "$L_DELTA")" \
    "$(session_volume "$L_DELTA")" "$(browser_volume "$L_DELTA")" "$2"
  stack_block pi-agents-pi-no-agent-state paused "$L_NONE" pi-agents-pi-no-agent-state \
    2026-08-08T09:00:00.000000000Z 2026-08-08T09:30:00.000000000Z none none none \
    "$(session_volume "$L_NONE")" "$(browser_volume "$L_NONE")" -
  stack_block pi-agents-pi-zeta exited "$L_ZETA" pi-agents-pi-zeta \
    2026-08-08T10:00:00.000000000Z never "$(agent_volume "$L_ZETA")" normal none \
    "$(session_volume "$L_ZETA")" "$(browser_volume "$L_ZETA")" "$3"
  printf 'ORPHAN VOLUMES:\n'
  volume_block "$(extra_volume "$L_ORPHAN")" agent-extra "$L_ORPHAN" pi-agents-pi-orphan 2026-01-04T00:00:00Z -
  volume_block "$(agent_volume "$L_ORPHAN")" agent "$L_ORPHAN" pi-agents-pi-orphan 2026-01-04T00:00:00Z "$4"
  volume_block "$(session_volume "$L_ORPHAN")" sessions "$L_ORPHAN" pi-agents-pi-orphan 2026-01-04T00:00:00Z -
}

list_stacks
printf '%s\n' "$(agent_volume "$L_ALPHA")" > "$SEED_FILE"
run_pi "$WS" list
assert_status 0
assert_eq "$(cat -- "$OUTPUT_LOG")" "$(expected_list seed - - latest)" 'list output'
assert_read_only_docker_calls

# Stacks are listed by container name whatever order Docker returns them in.
EXTRA_ENV=(FAKE_PS_REVERSE=1)
run_pi "$WS" list
EXTRA_ENV=()
assert_status 0
assert_eq "$(cat -- "$OUTPUT_LOG")" "$(expected_list seed - - latest)" 'list output sorted by container name'

# A stack running on its extra volume is marked through its normal volume.
printf '%s\n' "$(agent_volume "$L_DELTA")" > "$SEED_FILE"
run_pi "$WS" list
assert_eq "$(cat -- "$OUTPUT_LOG")" "$(expected_list - seed - latest)" 'list output, delta seed'

# One volume can carry both markers.
printf '%s\n' "$(agent_volume "$L_ORPHAN")" > "$SEED_FILE"
run_pi "$WS" list
assert_eq "$(cat -- "$OUTPUT_LOG")" "$(expected_list - - - seed,latest)" 'list output, orphan seed'

# A seed pointer naming an extra volume is not shown as the seed.
printf '%s\n' "$(extra_volume "$L_DELTA")" > "$SEED_FILE"
run_pi "$WS" list
assert_eq "$(cat -- "$OUTPUT_LOG")" "$(expected_list - - - latest)" 'list output, extra seed'
assert_read_only_docker_calls

# An inherited missing PI_WORKSPACE does not affect listing.
printf '%s\n' "$(agent_volume "$L_ZETA")" > "$SEED_FILE"
EXTRA_ENV=(PI_WORKSPACE=/missing)
run_pi "$WS" list
EXTRA_ENV=()
assert_status 0
assert_eq "$(cat -- "$OUTPUT_LOG")" "$(expected_list - - seed latest)" 'list output with a missing PI_WORKSPACE'

# Without stacks, leftover state volumes are still listed.
reset_docker
fake_volume "$(agent_volume "$L_ORPHAN")" "$L_ORPHAN" agent 2026-01-04T00:00:00Z
run_pi "$WS" list
assert_status 0
assert_eq "$(cat -- "$OUTPUT_LOG")" "No Pi stacks found."$'\n'"ORPHAN VOLUMES:"$'\n'"$(volume_block "$(agent_volume "$L_ORPHAN")" agent "$L_ORPHAN" pi-agents-pi-orphan 2026-01-04T00:00:00Z latest)" 'orphans without stacks'
assert_read_only_docker_calls

reset_docker
run_pi "$WS" list
assert_status 0
assert_eq "$(cat -- "$OUTPUT_LOG")" 'No Pi stacks found.' 'empty list output'
assert_read_only_docker_calls

pass
