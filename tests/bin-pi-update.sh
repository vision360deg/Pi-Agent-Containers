#!/usr/bin/env bash
# pi update: pull and no-cache rebuild, --extensions, and --models.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.bash"
source "$ROOT/tests/lib/launcher.bash"

WS=$(make_workspace "$TEST_HOME/projects/alpha")
PROJECT=pi-agents-pi-alpha
COMPOSE_FILES="--project-name $PROJECT --project-directory $ROOT --file $ROOT/compose.yml --file $ROOT/compose.shell-rc.yml"
LOGGED_PI='exec pi pi-shell-launch pi-session-log --forward-output'

# The Compose subcommands (first two words) and helper containers the last run
# started, in order; read-only `compose config` lookups are left out.
docker_actions() {
  local line
  while IFS= read -r line; do
    case $line in
      'docker compose '*)
        line=$(sed -E 's/^docker compose (--(project-name|project-directory|file) [^ ]+ )+//' <<< "$line")
        [[ $line == config* ]] || printf 'compose %s\n' "$(cut -d' ' -f1-2 <<< "$line")"
        ;;
      'docker run '*) printf 'run\n' ;;
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
assert_actions $'compose build --pull\nrun\nrun\ncompose up --detach\ncompose exec pi'
assert_log_has "$COMPOSE_FILES build --pull --no-cache pi"
assert_log_has "$COMPOSE_FILES up --detach --force-recreate pi"
assert_log_lacks ' up --build '
assert_log_has "$COMPOSE_FILES $LOGGED_PI install npm:pi-agent-browser-native"
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
  assert_actions $'run\nrun\ncompose up --detach\ncompose exec pi\ncompose exec pi'
  assert_log_has "$COMPOSE_FILES up --detach pi"
  assert_log_lacks ' up --build '
  assert_log_lacks ' build '
  assert_log_has "$COMPOSE_FILES $LOGGED_PI install npm:pi-agent-browser-native"
  assert_log_has "$COMPOSE_FILES $LOGGED_PI update $arguments"
  assert_workspace_propagated "$WS"
done

pass
