#!/usr/bin/env bash
# Launch flows of a fresh workspace: disposable --rm runs, --rebuild, and --new-state.
# Temporary home for cases moved off the old bin-pi-update.sh; phase B folds them into bin-pi-workspace.sh.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.bash"
source "$ROOT/tests/lib/launcher.bash"

WS=$(make_workspace "$TEST_HOME/projects/alpha")
PROJECT=pi-agents-pi-alpha
FILES="--project-name $PROJECT --project-directory $ROOT --file $ROOT/compose.yml --file $ROOT/compose.shell-rc.yml"

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

# --rm initializes and repairs state, then runs Pi in two one-off containers:
# the setup entrypoint and Pi itself.
fresh_stack
run_pi "$WS" --rm --version
assert_status 0
assert_actions $'run\nrun\ncompose run --rm\ncompose run --rm'
assert_log_has "$FILES run --rm --entrypoint /bin/sh pi -c"
assert_log_has "$FILES run --rm --service-ports pi pi-shell-launch pi --version"
assert_log_lacks ' run --build '
assert_workspace_propagated "$WS"

# --rebuild builds the service image once before Compose recreates from it.
fresh_stack
run_pi "$WS" --rebuild --version
assert_status 0
assert_actions $'compose build pi\nrun\nrun\ncompose up --detach\ncompose exec -T\ncompose exec -T\ncompose exec pi\ncompose exec pi'
assert_log_has "$FILES build pi"
assert_log_has "$FILES up --detach pi"
assert_log_lacks ' up --build '
assert_log_has "$FILES exec pi pi-shell-launch pi-session-log --forward-output install npm:pi-agent-browser-native"
assert_log_has "$FILES exec pi pi-shell-launch pi-session-log --version"

fresh_stack
run_pi "$WS" --rebuild --rm --version
assert_status 0
assert_log_has "$FILES build pi"
assert_log_has "$FILES run --rm --entrypoint /bin/sh pi -c"
assert_log_has "$FILES run --rm --service-ports pi pi-shell-launch pi --version"
assert_log_lacks ' run --build '


pass
