#!/usr/bin/env bash
# pi copy: copy direction, flags, the state-volume picker, session volumes,
# running-destination warnings, and permission repair.
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

# two_states: the current and another workspace's state, with no containers.
two_states() {
  reset_docker
  workspace_state "$WS"
  workspace_state "$OTHER"
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

# output_has_block TEXT: the output contains TEXT, newlines included.
output_has_block() {
  [[ $(cat -- "$OUTPUT_LOG") == *"$1"* ]] || fail "output lacks: $1"$'\n'"$(show_run)"
}

line_of() { grep -nF -- "$1" "$2" | head -n 1 | cut -d: -f1; }

# The default direction copies from a picked state volume into the current
# workspace; no container is needed on either side.
two_states
fake_volume_file "$(session_volume "$OTHER")" old-session.jsonl '{}'
copy_with 1 --sessions --all
assert_status 0
output_has_block $'Choose a source Pi state volume:\n1) '"$(agent_volume "$OTHER")"$'\n   workspace: '"$OTHER"$'\n   created: 2026-01-01T00:00:00Z\nX) Cancel (or Esc)\nChoice: '
# The current workspace's own state volume is not offered.
assert_output_lacks ") $(agent_volume "$WS")"
assert_output_lacks '2) '
assert_output_has "pi: copying agent state from $(agent_volume "$OTHER") to $(agent_volume "$WS")"
assert_output_has 'pi: agent-state copy complete'
assert_output_lacks 'warning'
assert_log_has 'bash /usr/local/bin/pi-state-copy --source /state-source --target /state-target --sessions --all'
# The copy helper must not inherit Compose capability drops.
assert_log_lacks '--no-deps'
assert_log_has 'docker run --rm -i --user 0'
assert_log_has "$(agent_volume "$OTHER"):/state-source:ro"
assert_log_has "$(agent_volume "$WS"):/state-target"
# Sessions live in a separate volume found by its workspace label; the
# target's is repaired before and after the copy.
assert_log_has "$(session_volume "$OTHER"):/state-source/sessions:ro"
assert_log_has "$(session_volume "$WS"):/state-target/sessions"
assert_eq "$(grep -cF -- "$(session_volume "$WS"):/sessions" "$DOCKER_LOG")" 2 'target session repairs'
volume_has_file "$(session_volume "$WS")" old-session.jsonl || fail 'the session must be copied'
(( $(line_of 'pi: copying agent state' "$OUTPUT_LOG") < $(line_of 'pi: agent-state copy complete' "$OUTPUT_LOG") )) ||
  fail 'the copying message must precede the completion message'

# Without a category, nothing is forwarded and sessions are mounted alongside
# configuration state.
two_states
copy_with 1
assert_status 0
assert_log_has 'bash /usr/local/bin/pi-state-copy --source /state-source --target /state-target'
assert_log_lacks 'pi-state-copy --source /state-source --target /state-target --'
assert_log_has "$(session_volume "$OTHER"):/state-source/sessions:ro"
assert_log_has "$(session_volume "$WS"):/state-target/sessions"

# copy needs no host shell configuration, so any host shell works.
EXTRA_ENV=(SHELL=/usr/bin/fish)
copy_with 1
EXTRA_ENV=()
assert_status 0
assert_output_lacks 'unsupported host shell'
assert_log_has 'pi-state-copy --source /state-source --target /state-target'

# --from with categories and flags forwards them; non-session copies skip
# session mounts.
two_states
copy_with 1 --from -a -e --all --override
assert_status 0
assert_log_has 'pi-state-copy --source /state-source --target /state-target --auth --extensions --all --override'
assert_log_has "$(agent_volume "$OTHER"):/state-source:ro"
assert_log_has "$(agent_volume "$WS"):/state-target"
assert_log_lacks ':/state-source/sessions'
assert_log_lacks ':/state-target/sessions'

# --to --sessions copies the current workspace's sessions into the picked
# destination's.
two_states
copy_with 1 --to --sessions
assert_status 0
assert_output_has 'Choose a destination Pi state volume:'
assert_log_has "$(agent_volume "$WS"):/state-source:ro"
assert_log_has "$(session_volume "$WS"):/state-source/sessions:ro"
assert_log_has "$(agent_volume "$OTHER"):/state-target"
assert_log_has "$(session_volume "$OTHER"):/state-target/sessions"
assert_log_has 'pi-state-copy --source /state-source --target /state-target --sessions'

# The current workspace's volumes are created before the picker when missing.
reset_docker
workspace_state "$OTHER"
copy_with 1 --auth --all
assert_status 0
assert_log_has "docker volume create --label com.pi-agents.managed=true --label com.pi-agents.state-kind=agent --label com.pi-agents.workspace=$WS"
volume_exists "$(agent_volume "$WS")" || fail 'the current agent volume must be created'
volume_exists "$(session_volume "$WS")" || fail 'the current session volume must be created'
assert_log_has "$(agent_volume "$WS"):/state-target"

# Only managed agent-state volumes are offered: extra, session, and unlabelled
# volumes are not.
two_states
fake_volume "$(extra_volume "$OTHER")" "$OTHER" agent-extra 2026-01-01T00:00:00Z
fake_volume pi-agents-ws-legacy_pi-agent-state /legacy agent 2026-01-01T00:00:00Z "${UNLABEL[@]}"
fake_volume pi-agents-ws-stray_pi-agent-state "$OTHER" agent 2026-01-01T00:00:00Z label.com.pi-agents.managed=false
copy_with 1 --auth --all
assert_status 0
assert_output_lacks "$(extra_volume "$OTHER")"
assert_output_lacks 'pi-agents-ws-legacy_pi-agent-state'
assert_output_lacks 'pi-agents-ws-stray_pi-agent-state'
assert_output_lacks "1) $(session_volume "$OTHER")"
assert_output_lacks '2) '

# Without another state volume there is nothing to pick.
reset_docker
workspace_state "$WS"
copy_with 1 --auth --all
assert_status 2
assert_output_has 'pi: no other managed Pi state volumes are available'
assert_log_lacks 'pi-state-copy'

# A labelled session volume is located by its workspace label, whatever its name.
two_states
rm -- "$FAKE_DOCKER_STATE/volumes/$(session_volume "$OTHER")"
fake_volume "$LABELLED_SESSIONS" "$OTHER" sessions 2026-01-02T00:00:00Z
copy_with 1 --sessions --all
assert_status 0
assert_log_has "$LABELLED_SESSIONS:/state-source/sessions:ro"

# A session copy requires exactly one session volume per workspace: a missing
# or unlabelled one is not found, and two labelled ones are ambiguous; all fail
# before the helper runs.
two_states
rm -- "$FAKE_DOCKER_STATE/volumes/$(session_volume "$OTHER")"
copy_with 1 --sessions
assert_status 2
assert_output_has "pi: expected one managed session volume for state volume: $(agent_volume "$OTHER")"
assert_log_lacks 'pi-state-copy'
two_states
fake_volume "$(session_volume "$OTHER")" "$OTHER" sessions 2026-01-01T00:00:00Z "${UNLABEL[@]}"
copy_with 1 --sessions --all
assert_status 2
assert_output_has "pi: expected one managed session volume for state volume: $(agent_volume "$OTHER")"
assert_log_lacks 'pi-state-copy'
two_states
fake_volume "$LABELLED_SESSIONS" "$OTHER" sessions 2026-01-02T00:00:00Z
copy_with 1 --all
assert_status 2
assert_output_has "pi: expected one managed session volume for state volume: $(agent_volume "$OTHER")"
assert_log_lacks 'pi-state-copy'

# --to picks the destination; auth-only copies do not need session volumes.
copy_with 1 --to --auth --all
assert_status 0
output_has_block $'Choose a destination Pi state volume:\n1) '"$(agent_volume "$OTHER")"
assert_output_has "pi: copying agent state from $(agent_volume "$WS") to $(agent_volume "$OTHER")"
assert_log_has "$(agent_volume "$WS"):/state-source:ro"
assert_log_has "$(agent_volume "$OTHER"):/state-target"
assert_log_has "$(agent_volume "$OTHER"):/state "
assert_log_lacks '_pi-sessions:/'

# A running container that mounts the destination agent volume is named in a
# warning after the copy; a stopped one is not.
two_states
fake_container pi-agents-pi-current "$WS" running
fake_container pi-agents-pi-other "$OTHER" running
copy_with 1 --auth --all
assert_status 0
assert_output_has "pi: warning: $(agent_volume "$WS") is mounted by running container pi-agents-pi-current; restart it to pick up copied auth or extensions"
assert_output_lacks 'pi-agents-pi-other;'
(( $(line_of 'pi: agent-state copy complete' "$OUTPUT_LOG") < $(line_of 'pi: warning:' "$OUTPUT_LOG") )) ||
  fail 'the warning must follow the completion message'
two_states
fake_container pi-agents-pi-current "$WS" exited
copy_with 1 --auth --all
assert_status 0
assert_output_lacks 'warning'

# The helper's status is returned to the caller, with no completion message.
two_states
EXTRA_ENV=(FAKE_STATE_COPY_STATUS=3)
copy_with 1 --auth --all
EXTRA_ENV=()
assert_status 3
assert_output_lacks 'pi: agent-state copy complete'

# With ten or more entries the picker waits for Enter after a leading 1-9,
# so a slowly typed 10 selects item 10 rather than item 1.
two_states
for index in 01 02 03 04 05 06 07 08 09 10; do
  workspace_state "/extra-$index"
done
copy_with_slow_input 'printf 1; sleep 0.3; printf "0\n"' --auth --all
assert_status 0
output_has_block $'X) Cancel (or Esc)\nChoice (number, then Enter): '
output_has_block "$(agent_volume /extra-10)"$'\n   workspace: /extra-10'
selected=$(sed -n "s|^10) ||p" "$OUTPUT_LOG")
assert_log_has "$selected:/state-source:ro"

# Shorter lists keep single-key selection.
two_states
copy_with 1 --auth --all
assert_status 0
assert_output_has 'Choice: '
assert_log_has "$(agent_volume "$OTHER"):/state-source:ro"

# x, X, Esc, and end of input cancel with status 3 and copy nothing; any other
# choice is invalid and exits 2.
for cancel in x X '\033' ''; do
  copy_with "$cancel" --auth --all
  assert_status 3
  assert_output_has 'pi: copy cancelled'
  assert_log_lacks '/state-source'
done
for invalid in 9 0 q one; do
  copy_with "$invalid\n" --auth --all
  assert_status 2
  assert_output_has "pi: invalid state volume selection: $invalid"
  assert_log_lacks '/state-source'
done

pass
