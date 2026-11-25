#!/usr/bin/env bash
# pi shell: container selection, pickers, new projects, and recreate rules.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.bash"
source "$ROOT/tests/lib/launcher.bash"

WS=$(make_workspace "$TEST_HOME/projects/current")
OTHER=$(make_workspace "$TEST_HOME/projects/other")
SECOND=$(make_workspace "$TEST_HOME/projects/second")
MISSING=$TEST_HOME/projects/new-project
CANCELLED=$TEST_HOME/projects/cancel-project
NAME=pi-agents-pi-current
SHELL_LAUNCH_ENV='--env PI_HOST_SHELL=bash --env PI_HOST_RC_FILE=/tmp/pi-host-shellrc/rc --env PI_NO_RC_CONFIG=0'

# fresh_docker: no Pi containers or state; the current image is built.
fresh_docker() {
  reset_docker
  fake_image "$NAME"
  fake_state "$WS" 2026-01-01T00:00:00Z
}

assert_attached() {
  assert_log_has "docker exec -it $1$SHELL_LAUNCH_ENV $2 pi-shell-launch"
}

# A current running workspace container is selected without a picker or Compose.
fresh_docker
fake_container "$NAME" "$WS" running
run_pi "$WS" shell
assert_status 0
assert_attached '' "$NAME"
assert_log_lacks 'docker start'
assert_log_lacks 'docker compose'
assert_output_lacks 'Choose a Pi container:'

run_pi "$WS" shell -r
assert_status 0
assert_attached '--user 0 ' "$NAME"

# A current stack renamed by a basename collision is still the current
# workspace's stack: --rebuild recreates it under its real project.
RENAMED=pi-agents-pi-current-0123456789ab
fresh_docker
fake_image "$RENAMED"
fake_container "$RENAMED" "$WS" running
run_pi "$WS" --rebuild shell
assert_status 0
assert_log_has "docker compose --project-name $RENAMED"
assert_log_lacks "compose --project-name $NAME "
assert_log_has ' build pi'
assert_log_has ' up --detach --force-recreate pi'
assert_attached '' "$RENAMED"

# Another workspace's stack keeps its mounts, even without the rc mount.
fresh_docker
fake_container pi-agents-pi-other "$OTHER" running -mount./tmp/pi-host-shellrc
INPUT='1\n'
run_pi "$WS" shell
INPUT=''
assert_status 0
assert_log_lacks ' up '
assert_attached '' pi-agents-pi-other

# Multiple containers for the current workspace are offered in the picker
# without a new project, but the selected workspace must resolve to exactly
# one stack.
fresh_docker
fake_container pi-agents-pi-first "$WS" running
fake_container pi-agents-pi-second "$WS" running
INPUT='0\n'
run_pi "$WS" shell
assert_status 2
assert_output_lacks '0) Start a new project'
assert_output_has 'invalid container selection: 0'
INPUT='2\n'
run_pi "$WS" shell
INPUT=''
assert_status 2
assert_output_has 'Choose a Pi container:'
assert_output_has "pi-container: multiple stacks found for workspace: $WS"
assert_log_lacks 'docker exec'

# A current stopped workspace container is started through Compose before a
# normal-user shell.
fresh_docker
fake_container "$NAME" "$WS" exited
run_pi "$WS" shell
assert_status 0
assert_log_has "compose --project-name $NAME"
assert_log_has ' start pi'
assert_log_lacks 'docker start'
assert_log_lacks ' up '
assert_attached '' "$NAME"
assert_output_lacks 'extra state volume'

# Starting the current stack warns about an extra state volume, reporting
# whether the started container runs on it.
EXTRA=$(extra_volume "$WS")
fresh_docker
fake_volume "$EXTRA" "$WS" agent 2026-01-02T00:00:00Z
fake_container "$NAME" "$WS" exited "mount./home/node/.pi/agent=$EXTRA"
run_pi "$WS" shell
assert_status 0
assert_log_has ' start pi'
assert_output_has "pi-container: warning: using the extra state volume $EXTRA; the normal state volume $(agent_volume "$WS") is untouched"

fresh_docker
fake_volume "$EXTRA" "$WS" agent 2026-01-02T00:00:00Z
fake_container "$NAME" "$WS" exited
run_pi "$WS" shell
assert_status 0
assert_output_has "pi-container: warning: an extra state volume $EXTRA exists and is not in use"

# Reusing an already running container does not start the stack or warn.
fresh_docker
fake_volume "$EXTRA" "$WS" agent 2026-01-02T00:00:00Z
fake_container "$NAME" "$WS" running "mount./home/node/.pi/agent=$EXTRA"
run_pi "$WS" shell
assert_status 0
assert_log_lacks 'docker start'
assert_output_lacks 'extra state volume'

# Without a current match, the picker numbers containers after the
# `0) Start a new project` entry; the displayed number selects that container.
# Root mode adds Docker's user override.
fresh_docker
fake_container pi-agents-pi-other "$OTHER" exited
fake_container pi-agents-pi-second "$SECOND" running
INPUT='1\n'
run_pi "$WS" shell --root
assert_status 0
assert_log_has 'compose --project-name pi-agents-pi-other'
assert_log_has ' start pi'
assert_log_lacks ' up '
assert_eq "$(container_field pi-agents-pi-other state)" running 'selected stopped stack must be started'
assert_attached '--user 0 ' pi-agents-pi-other
assert_output_has 'Choose a Pi container:'
assert_output_has '0) Start a new project'
assert_output_has '1) pi-agents-pi-other'
assert_output_has '   status: Exited (0) 3 hours ago'
assert_output_has "   workspace: $OTHER"
# The selected workspace's host rc is regenerated, in a 0755 directory.
OTHER_RC=$CONFIG_DIR/shell-rc/pi-agents-ws-$(workspace_hash "$OTHER")
[[ -f $OTHER_RC/rc ]] || fail 'the selected workspace rc must be regenerated'
assert_eq "$(stat -f %Lp "$OTHER_RC" 2>/dev/null || stat -c %a "$OTHER_RC")" 755 'rc directory mode'
[[ ! -e $CONFIG_DIR/shell-rc/pi-agents-ws-$(workspace_hash "$WS") ]] || fail 'the unselected current workspace rc must not be generated'

INPUT='2\n'
run_pi "$WS" shell
assert_status 0
assert_log_lacks 'docker start'
assert_attached '' pi-agents-pi-second

# Cancel, end of input, and invalid choices do not open a shell.
for input in X x '\033' ''; do
  INPUT=$input
  run_pi "$WS" shell
  assert_status 2
  assert_output_has 'container selection cancelled'
  assert_log_lacks 'docker exec'
done
for input in 9 3 q; do
  INPUT="$input\n"
  run_pi "$WS" shell
  assert_status 2
  assert_output_has "invalid container selection: $input"
  assert_log_lacks 'docker exec'
done

# --rebuild cannot rebuild another workspace's stack.
INPUT='2\n'
run_pi "$WS" --rebuild shell
INPUT=''
assert_status 2
assert_output_has 'pi-container: --rebuild can only build the current workspace image; run `pi --rebuild shell` from the selected workspace'
assert_log_lacks 'docker exec'
assert_log_lacks ' build'

# Starting another workspace's stack that runs on its extra state volume keeps
# that volume and says so.
OTHER_EXTRA=$(extra_volume "$OTHER")
fresh_docker
fake_volume "$OTHER_EXTRA" "$OTHER" agent-extra 2026-01-02T00:00:00Z
fake_container pi-agents-pi-other "$OTHER" exited "mount./home/node/.pi/agent=$OTHER_EXTRA"
INPUT='1\n'
run_pi "$WS" shell
INPUT=''
assert_status 0
assert_log_has ' start pi'
assert_log_lacks ' up '
assert_output_has "pi-container: warning: using the extra state volume $OTHER_EXTRA; the normal state volume $(agent_volume "$OTHER") is untouched"
assert_attached '' pi-agents-pi-other

# A missing workspace offers project creation and Escape cancellation.
reset_docker
fake_image pi-agents-pi-new-project
fake_container pi-agents-pi-existing "$OTHER" running
INPUT='0\n'
run_pi "$WS" --workspace "$MISSING" shell
INPUT=''
assert_status 0
[[ -d $MISSING ]] || fail 'the new project directory must be created'
assert_output_has '0) Start a new project'
assert_output_has '1) pi-agents-pi-existing'
assert_output_has 'X) Cancel (or Esc)'
assert_log_has 'up --detach pi'
assert_log_lacks 'up --build'
assert_log_has 'docker volume create'
assert_log_has 'docker run'
assert_log_has 'docker exec -i --env PI_HOST_SHELL=bash --env PI_NO_RC_CONFIG=0 --env PI_HOST_RC_FILE=/tmp/pi-host-shellrc/rc pi-agents-pi-new-project pi-shell-launch pi-session-log --forward-output install npm:pi-agent-browser-native'
assert_attached '' pi-agents-pi-new-project
# The new project's state volumes are created, initialized, and repaired
# before the service starts.
first_line() { grep -nF -- "$1" "$DOCKER_LOG" | head -n 1 | cut -d: -f1; }
(( $(first_line 'docker volume create') < $(first_line 'docker run ') )) || fail 'volumes must exist before the setup run'
(( $(first_line 'state-initialization complete') < $(first_line ' up --detach pi') )) || fail 'state must be initialized before up'
(( $(first_line 'chown -R 1000:1000 "$path"') < $(first_line ' up --detach pi') )) || fail 'permissions must be repaired before up'

# 0 starts a new project for the current workspace; without a seed pointer
# it offers the oldest managed state.
THIRD=$(make_workspace "$TEST_HOME/projects/third")
reset_docker
fake_image pi-agents-pi-third
fake_state "$OTHER" 2026-01-01T00:00:00Z
fake_container pi-agents-pi-other "$OTHER" running
INPUT='0\ny\n'
run_pi "$THIRD" shell
INPUT=''
assert_status 0
assert_log_has "compose-env project=pi-agents-pi-third container=pi-agents-pi-third network=pi-agents-pi-third workspace=$THIRD "
assert_log_has 'up --detach pi'
assert_attached '' pi-agents-pi-third
volume_has_file "$(agent_volume "$THIRD")" .container-initialized || fail 'new project state must be initialized'
assert_output_has 'pi-container: use it as the seed for this new workspace? [y/N] '
assert_log_has "$(agent_volume "$OTHER"):/state-source:ro"
assert_eq "$(seed_value)" "$(agent_volume "$OTHER")" 'accepted oldest volume must become the seed'

# A missing workspace can still open an existing stack.
reset_docker
fake_container pi-agents-pi-other "$OTHER" running
INPUT='1\n'
run_pi "$WS" --workspace "$TEST_HOME/projects/absent" shell
INPUT=''
assert_status 0
assert_attached '' pi-agents-pi-other
[[ ! -e $TEST_HOME/projects/absent ]] || fail 'choosing an existing stack must not create the workspace'

# With ten or more containers the picker waits for Enter after a leading 1-9,
# so a slowly typed 10 selects item 10 rather than item 1; 0 and Escape stay
# single keys.
reset_docker
for index in 01 02 03 04 05 06 07 08 09 10; do
  fake_container "pi-agents-pi-c$index" "/many/c$index" running
done
INPUT_COMMAND='printf 1; sleep 0.3; printf "0\n"'
run_pi "$WS" shell
assert_status 0
assert_output_has 'Choice (number, then Enter): '
assert_attached '' pi-agents-pi-c10
INPUT_COMMAND='printf 3; sleep 0.3; printf "\n"'
run_pi "$WS" shell
assert_status 0
assert_attached '' pi-agents-pi-c03
INPUT_COMMAND=''
INPUT='\033'
run_pi "$WS" shell
assert_status 2
assert_output_has 'container selection cancelled'
assert_output_lacks 'Choice: '
INPUT=''
# A single 0 is still taken without Enter, so the later y answers the next
# prompt. Type only once the picker is waiting.
fake_image "$NAME"
fake_state "$OTHER" 2026-01-01T00:00:00Z
INPUT_COMMAND="for _ in \$(seq 200); do grep -q 'Choice' '$OUTPUT_LOG' && break; sleep 0.05; done; printf 0; sleep 0.3; printf 'y\\n'"
run_pi "$WS" shell
INPUT_COMMAND=''
assert_status 0
assert_attached '' "$NAME"

reset_docker
run_pi "$WS" --workspace "$CANCELLED" shell
assert_status 2
[[ ! -d $CANCELLED ]] || fail 'a cancelled new project must not be created'
assert_output_has 'X) Cancel (or Esc)'
assert_output_has 'container selection cancelled'
assert_log_lacks 'docker compose'

# A workspace with no current container offers new-project and cancellation.
INPUT='x'
run_pi "$WS" shell
INPUT=''
assert_status 2
assert_output_has '0) Start a new project'
assert_output_has 'X) Cancel (or Esc)'
assert_output_has 'container selection cancelled'
assert_log_lacks 'docker compose'

# An unsupported host shell, or conflicting shell flags, fail before the picker
# and before any rc is generated.
reset_docker
fake_container pi-agents-pi-other "$OTHER" running
fake_container pi-agents-pi-second "$SECOND" running
rm -rf -- "$CONFIG_DIR/shell-rc"
INPUT='1\n'
EXTRA_ENV=(SHELL=/bin/fish)
run_pi "$WS" shell
EXTRA_ENV=()
assert_status 2
assert_output_has 'pi-container: unsupported host shell: fish (supported: bash, zsh)'
assert_output_lacks 'Choose a Pi container:'
assert_log_lacks 'docker exec'
[[ ! -e $CONFIG_DIR/shell-rc ]] || fail 'an rc was generated before shell validation'
INPUT=''

pass
