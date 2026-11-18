#!/usr/bin/env bash
# pi copy: copy direction, flags, pickers, session volumes, and permission repair.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.bash"
source "$ROOT/tests/lib/launcher.bash"

WS=$(make_workspace "$TEST_HOME/projects/current")
OTHER=$(make_workspace "$TEST_HOME/projects/other")
LABELLED_SESSIONS=pi-agents-ws-labelled_pi-sessions
UNLABEL=(-label.com.pi-agents.managed -label.com.pi-agents.workspace -label.com.pi-agents.project -label.com.pi-agents.state-kind)

# workspace_state WORKSPACE: the workspace's labelled agent and session volumes.
workspace_state() {
  fake_volume "$(agent_volume "$1")" "$1" agent 2026-01-01T00:00:00Z
  fake_volume "$(session_volume "$1")" "$1" sessions 2026-01-01T00:00:00Z
}

# two_stacks [KEY=VALUE...]: the running current stack and a stopped other
# stack, each on its own state; the keys apply to both containers.
two_stacks() {
  reset_docker
  workspace_state "$WS"
  workspace_state "$OTHER"
  fake_container pi-agents-pi-current "$WS" running "$@"
  fake_container pi-agents-pi-other "$OTHER" exited "$@"
}

copy_with() {
  INPUT=$1
  shift
  run_pi "$WS" copy "$@"
  INPUT=''
}

copy_with_slow_input() {
  INPUT_COMMAND=$1
  shift
  run_pi "$WS" copy "$@"
  INPUT_COMMAND=''
}

two_stacks
fake_volume_file "$(session_volume "$OTHER")" old-session.jsonl '{}'
copy_with 1 --from --sessions --all
assert_status 0
assert_log_has 'pi-state-copy'
assert_log_has 'bash /usr/local/bin/pi-state-copy'
# The copy helper must not inherit Compose capability drops.
assert_log_lacks '--no-deps'
assert_log_has 'docker run --rm -i --user 0'
assert_log_has "$(agent_volume "$OTHER"):/state-source:ro"
assert_log_has "$(agent_volume "$WS"):/state-target"
# Sessions live in a separate volume found by its workspace label; the
# target's is repaired.
assert_log_has "$(session_volume "$OTHER"):/state-source/sessions:ro"
assert_log_has "$(session_volume "$WS"):/state-target/sessions"
assert_log_has "$(session_volume "$WS"):/sessions"
volume_has_file "$(session_volume "$WS")" old-session.jsonl || fail 'the session must be copied'

# A labelled session volume is located by its workspace label, whatever its name.
two_stacks
rm -- "$FAKE_DOCKER_STATE/volumes/$(session_volume "$OTHER")"
fake_volume "$LABELLED_SESSIONS" "$OTHER" sessions 2026-01-02T00:00:00Z
copy_with 1 --from --sessions --all
assert_status 0
assert_log_has "$LABELLED_SESSIONS:/state-source/sessions:ro"

# A session volume without the managed labels is not found, and two labelled
# session volumes are ambiguous; both fail before the helper runs.
two_stacks
fake_volume "$(session_volume "$OTHER")" "$OTHER" sessions 2026-01-01T00:00:00Z "${UNLABEL[@]}"
copy_with 1 --from --sessions --all
assert_status 2
assert_output_has "expected one managed session volume for workspace: $OTHER"
assert_log_lacks 'pi-state-copy'
two_stacks
fake_volume "$LABELLED_SESSIONS" "$OTHER" sessions 2026-01-02T00:00:00Z
copy_with 1 --from --sessions --all
assert_status 2
assert_output_has "expected one managed session volume for workspace: $OTHER"
assert_log_lacks 'pi-state-copy'

# Auth-only copies do not need session volumes.
copy_with 1 --to --auth --all
assert_status 0
assert_output_has 'Choose a destination Pi container:'
assert_log_has "$(agent_volume "$WS"):/state-source:ro"
assert_log_has "$(agent_volume "$OTHER"):/state-target"
assert_log_lacks '_pi-sessions:/'

# With ten or more entries the picker waits for Enter after a leading 1-9,
# so a slowly typed 10 selects item 10 rather than item 1.
two_stacks
for index in 01 02 03 04 05 06 07 08 09 10; do
  fake_container "pi-agents-pi-extra-$index" "/extra-$index" exited
done
copy_with_slow_input 'printf 1; sleep 0.3; printf "0\n"' --auth --all
assert_status 0
assert_output_has 'Choice (number, then Enter): '
assert_output_has '10) pi-agents-pi-extra-10'
assert_log_has "$(agent_volume /extra-10):/state-source:ro"

# Shorter lists keep single-key selection.
two_stacks
copy_with 1 --auth --all
assert_status 0
assert_output_has 'Choice: '
assert_log_has "$(agent_volume "$OTHER"):/state-source:ro"

# Cancelling the picker exits 3 and copies nothing; invalid choices exit 2.
for cancel in x X '\033' ''; do
  copy_with "$cancel" --auth --all
  assert_status 3
  assert_log_lacks '/state-source'
done
copy_with 9 --auth --all
assert_status 2

pass
