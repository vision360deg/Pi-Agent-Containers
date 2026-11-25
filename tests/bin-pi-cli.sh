#!/usr/bin/env bash
# Help output, brief usage, option conflicts, and workspace resolution for bin/pi.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.bash"
source "$ROOT/tests/lib/launcher.bash"

WS_A=$(make_workspace "$TEST_HOME/projects/alpha")
WS_B=$(make_workspace "$TEST_HOME/projects/beta")
PROJECT_A=pi-agents-pi-alpha
COMPOSE_A="--project-name $PROJECT_A -f $ROOT/compose.yml -f $ROOT/compose.shell-rc.yml"
# Piped standard input: every exec keeps stdin open without a terminal and
# carries this launch's shell settings.
EXEC_A="docker exec -i --env PI_HOST_SHELL=bash --env PI_NO_RC_CONFIG=0 --env PI_HOST_RC_FILE=/tmp/pi-host-shellrc/rc $PROJECT_A"

assert_no_docker() {
  [[ ! -s $DOCKER_LOG ]] || fail "docker must not run"$'\n'"$(show_run)"
}

# help_has TEXT: TEXT, which may span lines, is in the output.
help_has() {
  [[ $(cat -- "$OUTPUT_LOG") == *"$1"* ]] || fail "output lacks: $1"$'\n'"$(show_run)"
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

# Every Compose call carries this workspace.
assert_workspace_propagated() {
  local calls
  calls=$(grep -c '^docker compose ' "$DOCKER_LOG" || true)
  assert_file_count "$DOCKER_LOG" "workspace=$1 agent=" "$calls"
}

# A fresh persistent launch in WS_A: new state is initialized and repaired, the
# service starts, host aliases are wired, the browser extension is installed,
# and Pi runs with ARGUMENTS through the logged launcher.
expect_persistent_launch() {
  assert_status 0
  assert_eq "$(docker_actions)" $'run\nrun\ncompose up --detach\nexec\nexec\nexec' 'docker actions'
  assert_log_has "$COMPOSE_A up --detach pi"
  assert_log_lacks ' up --build '
  assert_log_has "$EXEC_A sh -c"
  assert_log_has 'pi-agents managed host shell aliases'
  assert_log_has "$EXEC_A pi-shell-launch pi-session-log --forward-output install npm:pi-agent-browser-native"
  assert_log_has "$EXEC_A pi-shell-launch pi-session-log $*"
  assert_workspace_propagated "$WS_A"
}

fresh_stack() {
  reset_docker
  fake_image "$PROJECT_A"
}

# Exact -h/--help prints detailed help locally.
run_pi "$WS_A" --help
assert_status 0
assert_no_docker
DETAILED_HELP=$(cat -- "$OUTPUT_LOG")
assert_eq "$(grep -E '^[A-Z][A-Za-z ]*:$' "$OUTPUT_LOG" | tr '\n' ' ')" \
  'Usage: Options: Commands: Examples: Restrictions: Passthrough and help: ' 'detailed help sections'
help_has 'Containerized Pi wrapper'
help_has $'  pi [--workspace PATH] [--bash|--zsh] [--no-rc-config] [--rebuild] [--oauth [PORTS...]]\n     [--replace|--keep-existing] [--new-state|[--seed] [--latest-state]] [- PI_ARGS...]'
help_has $'[--oauth [PORTS...]]\n     --rm [- PI_ARGS...]'
help_has $'pi [--workspace PATH] --host [PI_ARGS...]\n  pi PI_ARGS...\n  pi [--workspace PATH] stop\n'
help_has 'pi [--workspace PATH] update [--extensions] [--models]'
help_has $'\n  pi list\n'
help_has 'pi [--workspace PATH] shell [--root|-r]'
help_has $'pi [--workspace PATH] copy [--from|--to] [-s|--sessions] [-a|--auth] [-e|--extensions]\n     [--all] [--override]'
assert_output_lacks 'pi [--workspace PATH] - PI_ARGS...'
help_has 'it overrides PI_WORKSPACE. Relative paths resolve from the'
help_has '--workspace=PATH also works.'
help_has $'  --rm                Run Pi in a disposable container instead of the persistent\n                      service; the workspace state volumes are still used. Its session\n                      records are forwarded to that container\'s Docker log until it is\n                      removed on exit.\n'
help_has '${PI_CODING_AGENT_DIR:-~/.pi/agent}/bin/pi'
help_has 'curl -fsSL https://pi.dev/install.sh | sh'
help_has $'which uses the host\'s ~/.pi/agent state, not workspace volumes.\n                      Arguments that match no wrapper option or command run native\n                      Pi the same way.\n'
help_has 'Build the image with the Docker build cache before this launch;'
help_has 'give this workspace a disambiguated name.'
help_has "Run on this workspace's extra agent-state volume, created empty"
help_has 'Launches warn while the extra volume exists.'
help_has 'The pointer is ~/.config/pi-agent-containers/seed;'
help_has 'PI_AGENT_CONTAINERS_CONFIG_PATH overrides its directory.'
help_has 'Once the workspace has state, it only warns.'
help_has '--bash, --zsh       Use Bash or zsh for Pi and shell processes'
help_has '--no-rc-config      Start the selected shell without the generated host startup'
help_has $'1455\n                      (OpenAI Codex), 53692 (Anthropic), and 51121 (pi-antigravity),'
help_has 'PI_OAUTH_CALLBACK_PORTS.'
help_has 'but a --rm run'
help_has $'cannot share them. The persistent container is recreated when the\n                      callback ports it publishes differ, so a launch without --oauth\n                      frees them.\n'
help_has 'Fails when the workspace has no stack.'
help_has 'Rebuild the image with a fresh pull and no build cache, then'
help_has "update --extensions Start the persistent service and run Pi's extension update."
help_has "update --models     Start the persistent service and update Pi's model catalogs."
help_has $'seed/latest markers, then state volumes left without a stack.\n                      It does not change Docker state.'
help_has 'a warning names a kept extra state volume.'
help_has 'the oldest remaining managed state becomes the'
help_has 'whether to leave them (default), delete all, or delete some.'
help_has 'first reconciled with Compose up.'
help_has '`0) Start a new project`'
help_has '`X) Cancel (or Esc)`'
help_has "(root) instead of the image's node user."
help_has $'copy                Copy agent state between Pi workspace state volumes through a\n                      disposable helper container; neither workspace needs a container.'
help_has $'The current workspace is the destination and a picker of the\n                      other managed state volumes selects the source (--from); --to'
help_has $'A warning names each running container that mounts the\n                      destination state; restart it to pick up copied auth or extensions.'
help_has 'sessions, provider auth, and extensions are'
help_has 'duplicates prompt r=replace, s=skip, a=replace all, q=cancel,'
help_has 'and --override replaces them.'
help_has 'exits with status 3.'
help_has $'In the shell and copy pickers a choice is a single key; with ten or more\n  entries, a choice starting with 1-9 is a number confirmed with Enter. Each\n  picker ends with `X) Cancel (or Esc)`.'
help_has 'pi --host update                 # Update the native Pi installation.'
help_has 'pi - "Inspect this project"      # Start Pi with an initial prompt.'
help_has "pi - install npm:pi-web-access   # Pi's install command: add a package."
help_has "pi --version                     # Native Pi's version; no container."
assert_output_lacks 'pi "Inspect this project"'
help_has "pi - update                      # Pi's update command, run in the container."
help_has '--bash and --zsh are mutually exclusive.'
help_has '--replace and --keep-existing are mutually exclusive.'
help_has '--new-state cannot be combined with --seed or --latest-state.'
help_has $'--rm cannot be combined with stop, update, remove, list, shell, copy, --replace,\n  --keep-existing, --seed, or --latest-state.'
help_has $'--rebuild cannot be combined with stop, update, remove, list, or copy; with\n  shell it can only rebuild the current workspace\'s image.'
help_has $'--replace, --keep-existing, --new-state, --seed, --latest-state, and --oauth\n  cannot be combined with stop, remove, list, shell, or copy.'
help_has '--host accepts only --workspace among wrapper options;'
help_has 'Launches, --rm, update, shell, and copy refuse the home directory as a workspace.'
help_has 'list accepts no arguments, rejects --workspace, and does not change Docker state.'
help_has '--from and --to are mutually exclusive.'
help_has 'prompts for action and defaults to cancel.'
help_has $'  Arguments that match no wrapper option or command run native Pi on the host, as\n  with --host (`pi --version`). With wrapper options, the remaining arguments go\n  to containerized Pi; a leading `-` sends everything after it to containerized\n  Pi, even a wrapper command name (`pi - update`).\n'
help_has 'Exact `pi -h` or `pi --help` shows this help; a help flag with other arguments'
help_has '`pi --host - --help` shows native Pi'
run_pi "$WS_A" -h
assert_status 0
assert_eq "$(cat -- "$OUTPUT_LOG")" "$DETAILED_HELP" '-h prints the same detailed help'
assert_no_docker

# Help combined with any other wrapper argument prints the brief usage.
run_pi "$WS_A" --rm --help
assert_status 0
assert_no_docker
assert_eq "$(cat -- "$OUTPUT_LOG")" "$(cat <<'BRIEF'
Usage:
  pi [-h|--help]
  pi [--workspace PATH] [--bash|--zsh] [--no-rc-config] [--rebuild] [--oauth [PORTS...]]
     [--replace|--keep-existing] [--new-state|[--seed] [--latest-state]] [- PI_ARGS...]
  pi [--workspace PATH] [--bash|--zsh] [--no-rc-config] [--rebuild] [--oauth [PORTS...]]
     --rm [- PI_ARGS...]
  pi [--workspace PATH] --host [PI_ARGS...]
  pi PI_ARGS...
  pi [--workspace PATH] stop
  pi [--workspace PATH] update [--extensions] [--models]
  pi list
  pi [--workspace PATH] remove [--all]
  pi [--workspace PATH] shell [--root|-r]
  pi [--workspace PATH] copy [--from|--to] [-s|--sessions] [-a|--auth] [-e|--extensions]
     [--all] [--override]

Commands:
  stop              Stop the current workspace's persistent stack.
  update            Rebuild the image, or update Pi extensions and model catalogs.
  list              List persistent Pi stacks without changing Docker state.
  remove [--all]    Remove the current stack; --all also removes its state volumes.
  shell [--root|-r] Open a shell in the current or selected Pi container.
  copy              Copy agent state between Pi workspaces.

Run `pi --help` for detailed usage.
BRIEF
)" 'brief usage'
BRIEF_USAGE=$(cat -- "$OUTPUT_LOG")
[[ $DETAILED_HELP == *"$(sed -n '/^Usage:/,/^$/p' "$OUTPUT_LOG")"* ]] || fail 'detailed help must repeat the brief usage synopsis'
expect_brief_usage() {
  run_pi "$WS_A" "$@"
  assert_status 0
  assert_eq "$(cat -- "$OUTPUT_LOG")" "$BRIEF_USAGE" "pi $* prints the brief usage"
  assert_no_docker
}
for option in -h --rm --replace --keep-existing --workspace --new-state --seed --latest-state --oauth \
  --bash --zsh --no-rc-config --rebuild --host; do
  expect_brief_usage "$option" --help
done
for command in update list stop remove shell copy; do
  expect_brief_usage "$command" --help
done
expect_brief_usage remove --all --help
expect_brief_usage --new-state --latest-state --help
expect_brief_usage --workspace "$WS_B" --host --help
expect_brief_usage --workspace "$WS_B" -h
expect_brief_usage --help --rm
expect_brief_usage --help list
expect_brief_usage --version --help
expect_brief_usage install npm:x -h
expect_brief_usage --bash --version --help

# Help after the passthrough marker belongs to Pi.
fresh_stack
run_pi "$WS_A" - --help
expect_persistent_launch --help
fresh_stack
run_pi "$WS_A" --rm - --help
assert_status 0
assert_log_has "$COMPOSE_A run --detach --rm --service-ports --name $PROJECT_A-pi-run-"
assert_log_matches "^docker exec -i .* $PROJECT_A-pi-run-[0-9a-f]{12} pi-shell-launch pi-session-log --help\$"

# Conflicting or unsupported options fail with status 2 before any Docker call.
# The message is the complete output; each line carries the wrapper prefix.
expect_conflict() {
  local message=$1 expected
  shift
  run_pi "$WS_A" "$@"
  assert_status 2
  expected=$(printf '%s\n' "$message" | sed 's/^/pi-container: /')
  assert_eq "$(cat -- "$OUTPUT_LOG")" "$expected" "pi $* output"
  assert_no_docker
}
expect_conflict '--bash and --zsh are mutually exclusive' --bash --zsh
expect_conflict '--replace and --keep-existing are mutually exclusive' --replace --keep-existing
expect_conflict '--new-state and --seed are mutually exclusive; the extra state volume is never a seed' --seed --new-state
expect_conflict '--new-state and --seed are mutually exclusive; the extra state volume is never a seed' --new-state --seed --latest-state
expect_conflict '--from and --to are mutually exclusive' copy --from --to
expect_conflict '--rm cannot be combined with --replace' --rm --replace
expect_conflict '--rm cannot be combined with --keep-existing' --rm --keep-existing
expect_conflict '--seed and --latest-state require a persistent workspace stack' --rm --seed
expect_conflict '--seed and --latest-state require a persistent workspace stack' --rm --latest-state
expect_conflict '--oauth cannot be combined with stop' --oauth stop
expect_conflict '--oauth cannot be combined with remove' --oauth remove
expect_conflict '--oauth cannot be combined with remove' --oauth=1455 remove --all
for option in --replace --keep-existing --new-state --seed --latest-state --oauth; do
  expect_conflict 'copy cannot be combined with launch, state, or OAuth options' "$option" copy
done
expect_conflict '--rebuild cannot be combined with copy' --rebuild copy
expect_conflict '--rebuild, --replace, and --keep-existing cannot be combined with update' --rebuild update
expect_conflict '--rebuild, --replace, and --keep-existing cannot be combined with update' --replace update
expect_conflict '--rebuild cannot be combined with stop' --rebuild stop
expect_conflict '--rebuild cannot be combined with remove' --rebuild remove
expect_conflict '--replace, --keep-existing, --new-state, --seed, and --latest-state cannot be combined with stop' --new-state stop
expect_conflict '--replace, --keep-existing, --new-state, --seed, and --latest-state cannot be combined with remove' --seed remove
expect_conflict 'usage: pi list' --rebuild list
# --rm refuses every wrapper command with one message, before the command's
# own checks.
for command in stop update list remove shell copy; do
  expect_conflict "--rm cannot be combined with $command" --rm "$command"
done
expect_conflict '--rm cannot be combined with copy' --rm --rebuild copy
expect_conflict '--rm cannot be combined with --replace' --rm --replace update
expect_conflict '--seed and --latest-state require a persistent workspace stack' --rm --seed shell
expect_conflict $'unsupported update option: --unknown\nusage: pi update [--extensions] [--models]' update --unknown
expect_conflict $'unsupported remove option: --unknown\nusage: pi remove [--all]' remove --unknown
expect_conflict 'usage: pi stop' stop extra
expect_conflict $'unsupported shell option: --unknown\nusage: pi shell [--root|-r]' shell --unknown
expect_conflict $'unsupported shell option: --zsh\nusage: pi shell [--root|-r]' shell --zsh
expect_conflict $'shell cannot be combined with lifecycle, state, or OAuth options\nusage: pi shell [--root|-r]' --new-state shell
expect_conflict $'unsupported copy option: --unknown\nusage: pi copy [--from] [--to] [-s|--sessions] [-a|--auth] [-e|--extensions] [--all] [--override]' copy --unknown
expect_conflict $'- requires a Pi argument\nusage: pi - PI_ARGS...' -
expect_conflict $'--workspace requires a path\nusage: pi [--workspace PATH] [PI_ARGS...]' --workspace
expect_conflict $'--workspace requires a path\nusage: pi [--workspace PATH] [PI_ARGS...]' --workspace=

# list takes no arguments and no launch options; it prints only its usage.
for arguments in 'list extra' '--workspace . list' '--oauth list'; do
  # shellcheck disable=SC2086
  run_pi "$WS_A" $arguments
  assert_status 2
  assert_eq "$(cat -- "$OUTPUT_LOG")" 'pi-container: usage: pi list' "pi $arguments output"
  assert_no_docker
done

# --new-state with --latest-state is refused and leaves the seed pointer alone.
mkdir -p "$CONFIG_DIR"
printf '%s\n' "$(agent_volume "$WS_B")" > "$SEED_FILE"
expect_conflict '--new-state and --latest-state are mutually exclusive; the extra state volume is never seeded' --new-state --latest-state
assert_eq "$(seed_value)" "$(agent_volume "$WS_B")" 'seed pointer after a refused launch'

# Option guards run before workspace validation.
EXTRA_ENV=(PI_WORKSPACE="$TMP_DIR/missing-workspace")
expect_conflict '--rm cannot be combined with stop' --rm stop
EXTRA_ENV=()

# A missing workspace is an error for launches.
run_pi "$WS_A" --workspace "$TEST_HOME/projects/missing"
assert_status 1
assert_output_has "workspace does not exist: $TEST_HOME/projects/missing"
assert_no_docker

# The invocation directory is the default workspace.
fresh_stack
run_pi "$WS_A" - --version
expect_persistent_launch --version

# Wrapper options keep the remaining arguments for containerized Pi, and no
# arguments launch the container.
fresh_stack
run_pi "$WS_A" --bash --version
expect_persistent_launch --version
fresh_stack
run_pi "$WS_A"
assert_status 0
assert_log_has "$COMPOSE_A up --detach pi"
assert_log_matches "pi-shell-launch pi-session-log\$"

# A leading - passes wrapper command names through to Pi.
for command in list stop update remove shell; do
  fresh_stack
  run_pi "$WS_A" - "$command"
  expect_persistent_launch "$command"
  assert_log_lacks "pi-session-log - $command"
done
fresh_stack
run_pi "$WS_A" - list
assert_output_lacks 'No Pi stacks found.'
fresh_stack
run_pi "$WS_A" - update
assert_log_lacks ' build --pull --no-cache pi'
fresh_stack
run_pi "$WS_A" - remove
assert_log_lacks ' down'
fresh_stack
run_pi "$WS_A" - stop
assert_log_lacks "$COMPOSE_A stop"
fresh_stack
run_pi "$WS_A" --rm - list
assert_status 0
assert_log_matches "^docker exec -i .* $PROJECT_A-pi-run-[0-9a-f]{12} pi-shell-launch pi-session-log list\$"
assert_log_lacks 'pi-session-log - list'

# PI_WORKSPACE overrides the invocation directory; --workspace overrides both.
EXTRA_ENV=(PI_WORKSPACE="$WS_B")
fresh_stack
run_pi "$WS_A" - --version
assert_status 0
assert_log_has "container=pi-agents-pi-beta network=pi-agents-pi-beta workspace=$WS_B agent="
assert_log_lacks "workspace=$WS_A agent="
EXTRA_ENV=(PI_WORKSPACE="$WS_A")
fresh_stack
run_pi "$WS_A" --workspace "$WS_B" --version
assert_status 0
assert_log_has "container=pi-agents-pi-beta network=pi-agents-pi-beta workspace=$WS_B agent="
assert_log_lacks "workspace=$WS_A agent="
EXTRA_ENV=()

# Relative paths resolve from the invocation directory, in both option forms.
fresh_stack
run_pi "$WS_A" --workspace ../beta --version
assert_status 0
assert_log_has "container=pi-agents-pi-beta network=pi-agents-pi-beta workspace=$WS_B agent="
fresh_stack
run_pi "$WS_B" --workspace=../alpha --version
assert_status 0
assert_log_has "container=pi-agents-pi-alpha network=pi-agents-pi-alpha workspace=$WS_A agent="

# Symlinked workspaces resolve to the physical directory.
ln -s "$WS_B" "$TEST_HOME/beta-link"
fresh_stack
run_pi "$TEST_HOME" --workspace beta-link --version
assert_status 0
assert_log_has "workspace=$WS_B agent="
assert_log_lacks 'beta-link'

# Container and project names come from a sanitized basename.
WS_MIXED=$(make_workspace "$TEST_HOME/projects/My Project!")
reset_docker
run_pi "$WS_MIXED" - --version
assert_status 0
assert_log_has "compose-env project=pi-agents-pi-my-project container=pi-agents-pi-my-project network=pi-agents-pi-my-project workspace=$WS_MIXED agent="

pass
