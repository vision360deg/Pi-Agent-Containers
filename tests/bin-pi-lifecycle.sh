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

# Deleting the seed volume clears the seed when no other state remains.
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
[[ -z $(seed_value) ]] || fail "seed pointer still names a deleted volume: $(seed_value)"

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
# Alpha has an unused extra state volume; delta runs on its legacy extra
# volume, which still carries the normal agent kind label.
ALPHA_EXTRA=$(extra_volume /tmp/workspaces/alpha)
DELTA_EXTRA=$(extra_volume /tmp/workspaces/delta)

list_stacks() {
  reset_docker
  fake_container pi-agents-pi-alpha /tmp/workspaces/alpha running created=2026-08-08T08:00:00.000000000Z \
    started=2026-08-08T09:15:00.000000000Z label.com.docker.compose.project= \
    mount./home/node/.pi/agent=pi-agents-ws-alpha_pi-agent-state
  fake_container pi-agents-pi-delta /tmp/workspaces/delta running created=2026-08-08T07:00:00.000000000Z \
    started=2026-08-08T07:30:00.000000000Z "mount./home/node/.pi/agent=$DELTA_EXTRA"
  fake_container pi-agents-pi-no-agent-state /tmp/workspaces/no-agent-state paused \
    created=2026-08-08T09:00:00.000000000Z started=2026-08-08T09:30:00.000000000Z -mount./home/node/.pi/agent
  fake_container pi-agents-pi-unresolvable /tmp/workspaces/unresolvable created \
    created=2026-08-08T09:30:00.000000000Z started=0001-01-01T00:00:00Z \
    mount./home/node/.pi/agent=pi-agents-ws-unresolvable_pi-agent-state
  fake_container pi-agents-pi-zeta /tmp/workspaces/zeta exited created=2026-08-08T10:00:00.000000000Z \
    started=0001-01-01T00:00:00Z mount./home/node/.pi/agent=pi-agents-ws-zeta_pi-agent-state
  # Real Docker lists --rm one-off containers unless the oneoff filter is set.
  fake_container pi-agents-pi-run-1a2b3c /tmp/workspaces/alpha running label.com.docker.compose.project=pi-agents-pi-alpha \
    label.com.docker.compose.oneoff=True mount./home/node/.pi/agent=pi-agents-ws-alpha_pi-agent-state
  fake_volume pi-agents-ws-alpha_pi-agent-state /tmp/workspaces/alpha agent 2026-08-08T12:30:00Z
  fake_volume pi-agents-ws-zeta_pi-agent-state /tmp/workspaces/zeta agent 2026-08-08T13:30:00Z
  fake_volume "$ALPHA_EXTRA" /tmp/workspaces/alpha agent-extra 2026-08-09T12:30:00Z
  fake_volume "$DELTA_EXTRA" /tmp/workspaces/delta agent 2026-08-09T13:30:00Z
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
  printf 'STACK: %s\n  status: %s\n  workspace: %s\n  project: %s\n  created: %s\n  started: %s\n  agent-state: %s\n  active-state: %s\n  extra-state: %s\n  markers: %s\n' "$@"
}

expected_list() {
  stack_block pi-agents-pi-alpha running /tmp/workspaces/alpha '' \
    2026-08-08T08:00:00.000000000Z 2026-08-08T09:15:00.000000000Z \
    pi-agents-ws-alpha_pi-agent-state normal "$ALPHA_EXTRA" "$1"
  stack_block pi-agents-pi-delta running /tmp/workspaces/delta pi-agents-pi-delta \
    2026-08-08T07:00:00.000000000Z 2026-08-08T07:30:00.000000000Z \
    "$DELTA_EXTRA" extra "$DELTA_EXTRA" -
  stack_block pi-agents-pi-no-agent-state paused /tmp/workspaces/no-agent-state pi-agents-pi-no-agent-state \
    2026-08-08T09:00:00.000000000Z 2026-08-08T09:30:00.000000000Z none none none -
  stack_block pi-agents-pi-unresolvable created /tmp/workspaces/unresolvable pi-agents-pi-unresolvable \
    2026-08-08T09:30:00.000000000Z never none none none -
  stack_block pi-agents-pi-zeta exited /tmp/workspaces/zeta pi-agents-pi-zeta \
    2026-08-08T10:00:00.000000000Z never pi-agents-ws-zeta_pi-agent-state normal none "$2"
}

# Delta's extra volume is newer than every normal volume yet is never latest.
list_stacks
printf '%s\n' pi-agents-ws-alpha_pi-agent-state > "$SEED_FILE"
run_pi "$WS" list
assert_status 0
assert_eq "$(cat -- "$OUTPUT_LOG")" "$(expected_list seed latest)" 'list output'
assert_read_only_docker_calls

printf '%s\n' pi-agents-ws-zeta_pi-agent-state > "$SEED_FILE"
run_pi "$WS" list
assert_eq "$(cat -- "$OUTPUT_LOG")" "$(expected_list - 'seed, latest')" 'list output, zeta seed'
assert_read_only_docker_calls

# A legacy seed pointer naming an extra volume is not shown as the seed.
printf '%s\n' "$DELTA_EXTRA" > "$SEED_FILE"
run_pi "$WS" list
assert_eq "$(cat -- "$OUTPUT_LOG")" "$(expected_list - latest)" 'list output, extra seed'
assert_read_only_docker_calls

# An inherited missing PI_WORKSPACE does not affect listing.
printf '%s\n' pi-agents-ws-alpha_pi-agent-state > "$SEED_FILE"
EXTRA_ENV=(PI_WORKSPACE=/missing)
run_pi "$WS" list
EXTRA_ENV=()
assert_status 0
assert_eq "$(cat -- "$OUTPUT_LOG")" "$(expected_list seed latest)" 'list output with a missing PI_WORKSPACE'
assert_read_only_docker_calls

reset_docker
run_pi "$WS" list
assert_status 0
assert_eq "$(cat -- "$OUTPUT_LOG")" 'No Pi stacks found.' 'empty list output'
assert_read_only_docker_calls

pass
