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
assert_attached '' "$RENAMED"

# Multiple containers for the current workspace require an explicit choice.
fresh_docker
fake_container pi-agents-pi-first "$WS" running
fake_container pi-agents-pi-second "$WS" running
INPUT='2\n'
run_pi "$WS" shell
INPUT=''
assert_status 0
assert_attached '' pi-agents-pi-second
assert_output_has 'Choose a Pi container:'

# A current stopped workspace container is started before a normal-user shell.
fresh_docker
fake_container "$NAME" "$WS" exited
run_pi "$WS" shell
assert_status 0
assert_log_has "docker start $NAME"
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
assert_log_has "docker start $NAME"
assert_output_has "pi: warning: using the extra state volume $EXTRA; the normal state volume $(agent_volume "$WS") is untouched"

fresh_docker
fake_volume "$EXTRA" "$WS" agent 2026-01-02T00:00:00Z
fake_container "$NAME" "$WS" exited
run_pi "$WS" shell
assert_status 0
assert_output_has "pi: warning: an extra state volume $EXTRA exists and is not in use"

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
assert_log_has 'docker start pi-agents-pi-other'
assert_attached '--user 0 ' pi-agents-pi-other
assert_output_has 'Choose a Pi container:'
assert_output_has '0) Start a new project'
assert_output_has '1) pi-agents-pi-other'

INPUT='2\n'
run_pi "$WS" shell
assert_status 0
assert_log_lacks 'docker start'
assert_attached '' pi-agents-pi-second

INPUT='3\n'
run_pi "$WS" shell
assert_status 2
assert_output_has 'invalid container selection: 3'

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
assert_output_has 'X) Press Esc to cancel'
assert_log_has 'up --detach pi'
assert_log_lacks 'up --build'
assert_log_has 'docker volume create'
assert_log_has 'docker run'
assert_log_has 'exec pi pi-shell-launch pi-session-log --forward-output install npm:pi-agent-browser-native'
assert_attached '' pi-agents-pi-new-project
# The new project's state volumes are created, initialized, and repaired
# before the service starts.
first_line() { grep -nF -- "$1" "$DOCKER_LOG" | head -n 1 | cut -d: -f1; }
(( $(first_line 'docker volume create') < $(first_line 'docker run ') )) || fail 'volumes must exist before the setup run'
(( $(first_line 'state-initialization complete') < $(first_line ' up --detach pi') )) || fail 'state must be initialized before up'
(( $(first_line 'chown -R 1000:1000 "$path"') < $(first_line ' up --detach pi') )) || fail 'permissions must be repaired before up'

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

reset_docker
run_pi "$WS" --workspace "$CANCELLED" shell
assert_status 2
[[ ! -d $CANCELLED ]] || fail 'a cancelled new project must not be created'
assert_output_has 'X) Press Esc to cancel'
assert_output_has 'container selection cancelled'
assert_log_lacks 'docker compose'

# A workspace with no current container offers new-project and cancellation.
INPUT='x'
run_pi "$WS" shell
INPUT=''
assert_status 2
assert_output_has '0) Start a new project'
assert_output_has 'X) Press Esc to cancel'
assert_output_has 'container selection cancelled'
assert_log_lacks 'docker compose'

pass
