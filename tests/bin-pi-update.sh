#!/usr/bin/env bash
# pi update: pull and no-cache rebuild, --extensions, and --models.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.bash"
source "$ROOT/tests/lib/launcher.bash"

WS=$(make_workspace "$TEST_HOME/projects/alpha")
PROJECT=pi-agents-pi-alpha
COMPOSE_FILES="--project-name $PROJECT -f $ROOT/compose.yml -f $ROOT/compose.shell-rc.yml"
LOGGED_PI="docker exec -i --env PI_HOST_SHELL=bash --env PI_NO_RC_CONFIG=0 --env PI_HOST_RC_FILE=/tmp/pi-host-shellrc/rc $PROJECT pi-shell-launch pi-session-log --forward-output"

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

# Plain update pulls and rebuilds without cache, initializes new state,
# repairs it, recreates the service, and installs the browser extension.
fresh_stack
run_pi "$WS" update
assert_status 0
assert_actions $'compose build --pull\nrun\nrun\ncompose up --detach\nexec'
assert_log_has "$COMPOSE_FILES build --pull --no-cache pi"
assert_log_has "$COMPOSE_FILES up --detach --force-recreate pi"
assert_log_lacks ' up --build '
assert_log_has "$LOGGED_PI install npm:pi-agent-browser-native"
assert_workspace_propagated "$WS"
volume_has_file "$(agent_volume "$WS")" .container-initialized || fail 'update must initialize new state'
assert_eq "$(seed_value)" "$(agent_volume "$WS")" 'update records the seed'

# --extensions, --models, and both run Pi's own update through the logged
# launcher in the started service, without rebuilding or recreating it.
for arguments in --extensions --models '--extensions --models'; do
  fresh_stack
  # shellcheck disable=SC2086
  run_pi "$WS" update $arguments
  assert_status 0
  assert_actions $'run\nrun\ncompose up --detach\nexec\nexec'
  assert_log_has "$COMPOSE_FILES up --detach pi"
  assert_log_lacks ' up --build '
  assert_log_lacks ' build '
  assert_log_has "$LOGGED_PI install npm:pi-agent-browser-native"
  assert_log_has "$LOGGED_PI update $arguments"
  assert_workspace_propagated "$WS"
done

# Each flag is forwarded once, --extensions before --models.
fresh_stack
run_pi "$WS" update --models --extensions --models
assert_status 0
assert_log_matches "pi-session-log --forward-output update --extensions --models\$"

pass
