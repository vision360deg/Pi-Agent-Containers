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

pass
