#!/usr/bin/env bash
# Launch flow, stack naming, basename collisions, workspace identity, one-off containers, and --rm.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.bash"
source "$ROOT/tests/lib/launcher.bash"

WS=$(make_workspace "$TEST_HOME/projects/alpha")
PROJECT=pi-agents-pi-alpha
FILES="--project-name $PROJECT -f $ROOT/compose.yml -f $ROOT/compose.shell-rc.yml"
EXEC_ENV='--env PI_HOST_SHELL=bash --env PI_NO_RC_CONFIG=0 --env PI_HOST_RC_FILE=/tmp/pi-host-shellrc/rc'
RM_RUN=' run --detach --rm --service-ports --name '

# disposable_name PROJECT: the name the --rm run gave its one-off, which is
# PROJECT-pi-run- and 12 random hex digits, like Compose's own.
disposable_name() {
  local name
  name=$(grep -oE -- "--name $1-pi-run-[0-9a-f]{12} pi\$" "$DOCKER_LOG" | head -n 1 | cut -d' ' -f2)
  [[ -n $name ]] || fail "no --rm one-off named for project $1"$'\n'"$(show_run)"
  printf '%s' "$name"
}

assert_no_disposable_left() {
  ! compgen -G "$FAKE_DOCKER_STATE/containers/*-pi-run-*" >/dev/null || fail "$1"$'\n'"$(show_run)"
}

# The Compose subcommands (first two words), execs, and helper containers the
# last run started, in order; read-only `compose config` lookups are left out.
docker_actions() {
  local line
  while IFS= read -r line; do
    case $line in
      'docker compose '*)
        line=$(sed -E 's/^docker compose (--project-name [^ ]+ |-f [^ ]+ )+//' <<< "$line")
        [[ $line == config* ]] || printf 'compose %s\n' "$(cut -d' ' -f1-2 <<< "$line")"
        ;;
      'docker run '*) printf 'run\n' ;;
      'docker exec '*) printf 'exec\n' ;;
    esac
  done < "$DOCKER_LOG"
}

assert_actions() {
  assert_eq "$(docker_actions)" "$1" 'docker actions'
}

# Every Compose call carries this workspace.
assert_workspace_propagated() {
  local calls
  calls=$(grep -c '^docker compose ' "$DOCKER_LOG" || true)
  assert_file_count "$DOCKER_LOG" "workspace=$1 agent=" "$calls"
}

fresh_stack() {
  reset_docker
  fake_image "$PROJECT"
}

# --rm initializes and repairs state, then starts one detached one-off of the
# service with its own command, which runs the session forwarder. The alias
# setup, the extension install, and Pi itself are exec'd into it with the
# persistent exec's environment, and the one-off is removed once Pi exits.
fresh_stack
run_pi "$WS" --rm --version
assert_status 0
assert_actions $'run\nrun\ncompose run --detach\nexec\nexec\nexec'
assert_eq "$(grep -c '^docker compose .* run ' "$DOCKER_LOG")" 1 'one compose run'
name=$(disposable_name "$PROJECT")
assert_log_has "$FILES$RM_RUN$name pi"
assert_log_has "docker exec -i $EXEC_ENV $name sh -c"
assert_log_has 'pi-agents managed host shell aliases'
assert_log_has "docker exec -i $EXEC_ENV $name pi-shell-launch pi-session-log --forward-output install npm:pi-agent-browser-native"
assert_log_has "docker exec -i $EXEC_ENV $name pi-shell-launch pi-session-log --version"
assert_log_lacks 'docker exec -i -t'
assert_log_has "docker rm -f $name"
(( $(grep -n 'docker exec ' "$DOCKER_LOG" | tail -n 1 | cut -d: -f1) < $(grep -n 'docker rm -f' "$DOCKER_LOG" | cut -d: -f1) )) ||
  fail 'the one-off must be removed after Pi exits'$'\n'"$(show_run)"
assert_no_disposable_left '--rm must remove its one-off container'
assert_log_lacks ' run --build '
assert_workspace_propagated "$WS"
# Each run picks a new name.
run_pi "$WS" --rm
first_name=$(disposable_name "$PROJECT")
run_pi "$WS" --rm
name=$(disposable_name "$PROJECT")
[[ $name != "$first_name" ]] || fail 'each --rm run must pick a new one-off name'

# With a terminal as standard input and output, the exec allocates one.
IN_TERMINAL=true
run_pi "$WS" --rm
IN_TERMINAL=false
assert_status 0
name=$(disposable_name "$PROJECT")
assert_log_has "docker exec -i -t $EXEC_ENV $name pi-shell-launch pi-session-log"

# Pi's exit status propagates, and the one-off is still removed.
EXTRA_ENV=(FAKE_EXEC_STATUS=7)
run_pi "$WS" --rm
EXTRA_ENV=()
assert_status 7
name=$(disposable_name "$PROJECT")
assert_log_has "docker rm -f $name"
assert_no_disposable_left 'a failed run must remove its one-off container'

# An interrupted wrapper removes the one-off too.
for signal in HUP:129 INT:130 TERM:143; do
  EXTRA_ENV=("FAKE_EXEC_SIGNAL=${signal%%:*}")
  run_pi "$WS" --rm
  EXTRA_ENV=()
  assert_status "${signal#*:}"
  name=$(disposable_name "$PROJECT")
  assert_log_has "docker rm -f $name"
  assert_no_disposable_left "SIG${signal%%:*} must remove the one-off container"
done

# A failed removal is reported without changing Pi's exit status.
EXTRA_ENV=(FAKE_EXEC_STATUS=3 FAKE_RM_STATUS=1)
run_pi "$WS" --rm
EXTRA_ENV=()
assert_status 3
name=$(disposable_name "$PROJECT")
assert_output_has "pi: could not remove disposable container $name"

# A compose run that fails after creating the one-off still has it removed by
# name, and the wrapper fails with Compose's status.
fresh_stack
EXTRA_ENV=(FAKE_COMPOSE_RUN_CREATED_STATUS=6)
run_pi "$WS" --rm
EXTRA_ENV=()
assert_status 6
assert_log_lacks 'docker exec'
name=$(disposable_name "$PROJECT")
assert_log_has "docker rm -f $name"
assert_no_disposable_left 'a failed compose run must not leave its one-off container'

# A compose run that fails before creating anything fails with its status;
# removing the unused name is a quiet no-op.
fresh_stack
EXTRA_ENV=(FAKE_COMPOSE_RUN_STATUS=5)
run_pi "$WS" --rm
EXTRA_ENV=()
assert_status 5
assert_log_lacks 'docker exec'
assert_output_lacks 'could not remove'

# --rebuild builds the service image once before Compose recreates from it.
fresh_stack
run_pi "$WS" --rebuild --version
assert_status 0
assert_actions $'compose build pi\nrun\nrun\ncompose up --detach\nexec\nexec\nexec'
assert_log_has "$FILES build pi"
assert_log_lacks ' build --pull'
assert_log_has "$FILES up --detach pi"
assert_log_lacks ' up --build '
assert_log_has "docker exec -i $EXEC_ENV $PROJECT pi-shell-launch pi-session-log --forward-output install npm:pi-agent-browser-native"
assert_log_has "docker exec -i $EXEC_ENV $PROJECT pi-shell-launch pi-session-log --version"

# With a terminal as standard input and output, the exec allocates one.
IN_TERMINAL=true
run_pi "$WS" - --version
IN_TERMINAL=false
assert_status 0
assert_log_has "docker exec -i -t $EXEC_ENV $PROJECT pi-shell-launch pi-session-log --version"

# A running stack with matching mounts is reused as-is.
run_pi "$WS" - --continue
assert_status 0
assert_log_lacks ' up '
assert_log_lacks ' build '
assert_log_lacks ' start '
assert_log_has "docker exec -i $EXEC_ENV $PROJECT pi-shell-launch pi-session-log --continue"

# Another shell needs no new container; the exec carries it.
run_pi "$WS" --zsh --version
assert_status 0
assert_log_lacks ' up '
assert_log_has "docker exec -i --env PI_HOST_SHELL=zsh --env PI_NO_RC_CONFIG=0 --env PI_HOST_RC_FILE=/tmp/pi-host-shellrc/rc $PROJECT pi-shell-launch pi-session-log --version"

# A stopped stack is started rather than recreated.
run_pi "$WS" stop
assert_status 0
assert_eq "$(container_field "$PROJECT" state)" exited 'stop must stop the stack'
run_pi "$WS" - --version
assert_status 0
assert_log_has "$FILES start pi"
assert_log_lacks ' up '
assert_eq "$(container_field "$PROJECT" state)" running 'a stopped stack must be started'

# --replace force-recreates; --rebuild builds with cache and goes through up.
run_pi "$WS" --replace --version
assert_status 0
assert_log_has "$FILES up --detach --force-recreate pi"
run_pi "$WS" --rebuild --version
assert_status 0
assert_file_count "$DOCKER_LOG" ' build pi' 1
assert_log_has "$FILES up --detach pi"
assert_log_lacks '--force-recreate'

# A changed shell-rc mount source forces recreation, in both directions.
run_pi "$WS" --no-rc-config --version
assert_status 0
assert_log_has ' up --detach --force-recreate pi'
run_pi "$WS" - --version
assert_status 0
assert_log_has "$FILES up --detach --force-recreate pi"

fresh_stack
run_pi "$WS" --rebuild --rm --version
assert_status 0
assert_log_has "$FILES build pi"
assert_log_has "$RM_RUN"
name=$(disposable_name "$PROJECT")
assert_log_has "docker exec -i $EXEC_ENV $name pi-shell-launch pi-session-log --version"
assert_log_lacks ' run --build '


# --- Naming and collisions between workspaces that share a basename ---
PATH_1=$(make_workspace "$TEST_HOME/path-1/workspace")
PATH_2=$(make_workspace "$TEST_HOME/path-2/workspace")
BASE=pi-agents-pi-workspace
TARGET_1=pi-agents-pi-path-1-workspace-$(workspace_hash "$PATH_1")
TARGET_2=pi-agents-pi-path-2-workspace-$(workspace_hash "$PATH_2")

# stack_1 [STATE [KEY=VALUE...]]: PATH_1's stack under the basename project.
stack_1() {
  reset_docker
  fake_container "$BASE" "$PATH_1" "${1:-running}" "${@:2}"
}

# oneoff_of WORKSPACE: a `pi --rm` container in the basename project.
oneoff_of() {
  fake_container "$BASE-pi-run-0123abcd" "$1" running "label.com.docker.compose.project=$BASE" label.com.docker.compose.oneoff=True
}

# A fresh workspace creates labeled state volumes, marks its agent state
# initialized, and becomes the seed.
reset_docker
run_pi "$PATH_1"
assert_status 0
for volume_kind in "$(agent_volume "$PATH_1"):agent" "$(session_volume "$PATH_1"):sessions" "$(browser_volume "$PATH_1"):browser"; do
  assert_log_has "volume create --label com.pi-agents.managed=true --label com.pi-agents.workspace=$PATH_1 --label com.pi-agents.project=$BASE --label com.pi-agents.state-kind=${volume_kind##*:} ${volume_kind%:*}"
done
volume_has_file "$(agent_volume "$PATH_1")" .container-initialized || fail 'fresh state must be marked initialized'
assert_eq "$(seed_value)" "$(agent_volume "$PATH_1")" 'first workspace must become the seed'
assert_eq "$(container_field "$BASE" state)" running 'fresh stack must be running'
assert_log_has "--project-name $BASE "
assert_log_lacks '--project-name pi-agents-ws-'
assert_log_has "compose-env project=$BASE container=$BASE network=$BASE workspace=$PATH_1 "
assert_log_matches ' agent=pi-agents-ws-[a-z0-9]+_pi-agent-state sessions=pi-agents-ws-[a-z0-9]+_pi-sessions browser=pi-agents-ws-[a-z0-9]+_agent-browser-state '

# Compose project names cannot contain dots, so a dotted basename is mapped
# to hyphens and the launch proceeds.
DOTTED=$(make_workspace "$TEST_HOME/src/my.project")
run_pi "$DOTTED"
assert_status 0
assert_log_has '--project-name pi-agents-pi-my-project '
assert_log_has 'container=pi-agents-pi-my-project '
assert_log_has 'up --detach pi'

# A running stack of another workspace with the same basename: cancelling
# changes nothing, renaming moves it aside.
stack_1
INPUT='c\n'
run_pi "$PATH_2"
assert_status 2
assert_output_has 'Workspace container collision detected.'
assert_output_has "  $PATH_2"
assert_output_has "workspace: $PATH_1"
assert_output_has 'status: Up 2 minutes'
assert_output_has '¡¡¡ WARNING !!! Renaming/recreating the existing container may interrupt processes currently running inside it.'
assert_output_has $'Choose:\n  [r] Rename/recreate the existing container\n  [k] Keep it unchanged and disambiguate this workspace\n  [c] Cancel\n\nChoice [c]: '
assert_output_has 'pi: workspace container collision cancelled'
assert_log_lacks 'rename'
assert_log_lacks ' up '

# End of input cancels as well.
INPUT=''
run_pi "$PATH_2"
assert_status 2
assert_output_has 'pi: workspace container collision cancelled'
assert_log_lacks 'rename'
assert_log_lacks ' up '

INPUT='r\n'
run_pi "$PATH_2"
assert_status 0
assert_log_has "docker rename $BASE $TARGET_1"
assert_log_has "container=$TARGET_2 "
assert_log_has "compose --project-name $TARGET_2"
assert_log_has 'up --detach --force-recreate pi'
assert_log_lacks 'up --build'
container_exists "$TARGET_1" || fail "the other stack must be renamed to $TARGET_1"
container_exists "$TARGET_2" || fail "the new stack must be named $TARGET_2"
! container_exists "$BASE" || fail 'the basename must be released'
assert_eq "$(container_field "$TARGET_1" label.com.pi-agents.workspace)" "$PATH_1" 'renamed stack keeps its workspace'
assert_eq "$(container_field "$TARGET_2" label.com.pi-agents.workspace)" "$PATH_2" 'new stack uses the requested workspace'

# Each workspace then resolves to its own stack without prompting.
INPUT=''
run_pi "$PATH_1"
assert_status 0
assert_output_lacks 'collision'
assert_log_has "compose-env project=$BASE container=$TARGET_1 network=$BASE workspace=$PATH_1 "
assert_log_lacks 'rename'
run_pi "$PATH_2"
assert_status 0
assert_output_lacks 'collision'
assert_log_has "container=$TARGET_2 network=$TARGET_2 workspace=$PATH_2 "

# Every rename destination is validated before the first rename: a target
# name or project held by another workspace aborts without renaming anything.
INPUT='r\n'
stack_1
fake_container "$TARGET_1" "$TEST_HOME/elsewhere" running
run_pi "$PATH_2"
assert_status 2
assert_output_has "container identity does not match workspace: $TARGET_1"
assert_output_has "pi: disambiguated container name is occupied: $TARGET_1"
assert_output_lacks 'Choose:'
assert_log_lacks 'rename'
assert_log_lacks ' up '
stack_1
fake_container squatter "$TEST_HOME/elsewhere/other" running "label.com.docker.compose.project=$TARGET_2"
run_pi "$PATH_2"
assert_status 2
assert_output_has "pi: disambiguated Compose project is occupied: $TARGET_2"
assert_output_lacks 'Choose:'
assert_log_lacks 'rename'
assert_log_lacks ' up '
INPUT=''

# Identity mismatches fail closed.
stack_1 running label.com.docker.compose.service=other
run_pi "$PATH_2"
assert_status 2
assert_output_has "container identity does not match workspace: $BASE"
assert_output_has "pi: invalid managed container: $BASE"
assert_log_lacks ' up '
reset_docker
fake_container "$PROJECT" "$TEST_HOME/elsewhere/other" running -label.com.pi-agents.managed
run_pi "$WS"
assert_status 2
assert_output_has "pi: workspace container name is occupied: $PROJECT"
assert_log_lacks ' up '
reset_docker
fake_container squatter "$TEST_HOME/elsewhere/other" running "label.com.docker.compose.project=$PROJECT"
run_pi "$WS"
assert_status 2
assert_output_has "pi: workspace Compose project is occupied: $PROJECT"
assert_log_lacks ' up '

# Two stacks claiming the same workspace are ambiguous and refused.
stack_1
fake_container "$TARGET_1" "$PATH_1" exited
run_pi "$PATH_1"
[[ $STATUS -ne 0 ]] || fail 'duplicate workspace stacks unexpectedly succeeded'
assert_output_has "pi: multiple stacks found for workspace: $PATH_1"
assert_log_lacks ' up '

# `pi --rm` one-off containers live in the workspace's own project, so a
# running or leftover one-off of the same workspace does not block launches.
stack_1
oneoff_of "$PATH_1"
run_pi "$PATH_1"
assert_status 0
assert_log_lacks ' up '
assert_log_has "$BASE pi-shell-launch pi-session-log"
assert_output_lacks 'occupied'
run_pi "$PATH_1" --rm
assert_status 0
assert_log_has "$RM_RUN"
assert_output_lacks 'occupied'
reset_docker
oneoff_of "$PATH_1"
run_pi "$PATH_1"
assert_status 0
assert_log_has 'up --detach pi'
run_pi "$PATH_1" stop
assert_status 0
assert_output_lacks 'shared'
assert_log_has " stop"

# A one-off belonging to another workspace still marks the project occupied.
for arguments in '' --rm; do
  reset_docker
  oneoff_of "$PATH_2"
  # shellcheck disable=SC2086
  run_pi "$PATH_1" $arguments
  [[ $STATUS -ne 0 ]] || fail "foreign one-off container did not block pi $arguments"
  assert_output_has "workspace Compose project is occupied: $BASE"
  assert_log_lacks ' up '
  assert_log_lacks "$RM_RUN"
done

# A container without the managed label is not this workspace's stack, and
# its name is not taken over.
stack_1 running -label.com.pi-agents.managed
run_pi "$PATH_1"
assert_status 2
assert_output_has "container identity does not match workspace: $BASE"
assert_log_lacks ' up '
for command in stop remove; do
  stack_1 running -label.com.pi-agents.managed
  run_pi "$PATH_1" "$command"
  assert_output_has "no stack found for workspace: $PATH_1"
  assert_log_lacks ' stop'
  assert_log_lacks ' down'
done

# A stopped colliding stack still asks, without the running-stack warning.
stack_1 exited
INPUT='c\n'
run_pi "$PATH_2"
INPUT=''
assert_status 2
assert_output_has 'status: Exited (0) 3 hours ago'
assert_log_lacks 'rename'
assert_output_lacks '¡¡¡ WARNING !!!'

# [k] leaves the other stack alone and disambiguates this one.
stack_1
INPUT='k\n'
run_pi "$PATH_2"
INPUT=''
assert_status 0
assert_log_lacks 'rename'
assert_log_has "compose-env project=$TARGET_2 container=$TARGET_2 "
assert_log_lacks '--force-recreate'
container_exists "$BASE" || fail '[k] must keep the other stack name'

# --keep-existing leaves the other stack alone and disambiguates this one.
stack_1
run_pi "$PATH_2" --keep-existing
assert_status 0
assert_output_lacks 'Choose:'
assert_log_lacks "rename $BASE"
assert_log_has "container=$TARGET_2 "
assert_log_has "compose --project-name $TARGET_2"
container_exists "$BASE" || fail '--keep-existing must keep the other stack name'

reset_docker
run_pi "$PATH_1" --replace
assert_status 0
assert_log_has 'up --detach --force-recreate pi'
assert_log_lacks 'up --build'

# --rm runs a one-off container in the workspace's own Compose project, so it
# uses the image `update` rebuilds, keeps state volumes, and leaves the
# persistent stack running.
stack_1
fake_state "$PATH_1" 2026-01-01T00:00:00Z
run_pi "$PATH_1" --rm --version
assert_status 0
assert_workspace_propagated "$PATH_1"
assert_log_has "compose-env project=$BASE container=$BASE network=$BASE workspace=$PATH_1 "
name=$(disposable_name "$BASE")
assert_log_has "docker exec -i $EXEC_ENV $name pi-shell-launch pi-session-log --version"
assert_log_lacks "project=$BASE-"
assert_log_lacks ' up '
assert_eq "$(container_field "$BASE" state)" running 'the persistent stack must keep running'
run_pi "$PATH_1" update
assert_status 0
assert_log_has "compose-env project=$BASE container=$BASE network=$BASE workspace=$PATH_1 "
assert_log_has ' build --pull --no-cache pi'

# Without a stack, --rm uses the project a launch would create.
reset_docker
run_pi "$PATH_1" --rm
assert_status 0
assert_log_has "compose-env project=$BASE container=$BASE network=$BASE workspace=$PATH_1 "
assert_log_has "$RM_RUN"
volume_exists "$(agent_volume "$PATH_1")" || fail '--rm must keep persistent state volumes'
! container_exists "$BASE" || fail '--rm must not leave a persistent container'

# A basename collision uses the disambiguated project without prompting,
# renaming, or touching the colliding stack.
stack_1
run_pi "$PATH_2" --rm
assert_status 0
assert_log_has "compose-env project=$TARGET_2 container=$TARGET_2 network=$TARGET_2 workspace=$PATH_2 "
assert_log_has "compose --project-name $TARGET_2"
assert_log_has "$RM_RUN"
name=$(disposable_name "$TARGET_2")
assert_log_has "docker exec -i $EXEC_ENV $name pi-shell-launch"
assert_log_lacks "compose --project-name $BASE "
assert_log_lacks ' up '
assert_log_lacks 'rename'
assert_output_lacks 'collision'
assert_eq "$(container_field "$BASE" state)" running 'colliding stack must be untouched'

# Pi's exit status is propagated.
EXTRA_ENV=(FAKE_EXEC_STATUS=7)
run_pi "$PATH_2" --rm
assert_status 7
EXTRA_ENV=()

# An occupied project is refused.
fake_container squatter "$TEST_HOME/elsewhere/other" running "label.com.docker.compose.project=$TARGET_2"
run_pi "$PATH_2" --rm
assert_status 2
assert_output_has "pi: disambiguated Compose project is occupied: $TARGET_2"
assert_log_lacks "$RM_RUN"

pass
