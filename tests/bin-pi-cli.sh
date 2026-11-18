#!/usr/bin/env bash
# Help output, brief usage, option conflicts, and workspace resolution for bin/pi.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.bash"
source "$ROOT/tests/lib/launcher.bash"

WS_A=$(make_workspace "$TEST_HOME/projects/alpha")
WS_B=$(make_workspace "$TEST_HOME/projects/beta")
PROJECT_A=pi-agents-pi-alpha
COMPOSE_A="--project-name $PROJECT_A --project-directory $ROOT --file $ROOT/compose.yml --file $ROOT/compose.shell-rc.yml"

assert_no_docker() {
  [[ ! -s $DOCKER_LOG ]] || fail "docker must not run"$'\n'"$(show_run)"
}

# help_has TEXT: TEXT, which may span lines, is in the output.
help_has() {
  [[ $(cat -- "$OUTPUT_LOG") == *"$1"* ]] || fail "output lacks: $1"$'\n'"$(show_run)"
}

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
  assert_eq "$(docker_actions)" $'run\nrun\ncompose up --detach\ncompose exec -T\ncompose exec pi\ncompose exec pi' 'docker actions'
  assert_log_has "$COMPOSE_A up --detach pi"
  assert_log_lacks ' up --build '
  assert_log_has "$COMPOSE_A exec -T pi sh -c"
  assert_log_has 'pi-agents managed host shell aliases'
  assert_log_has "$COMPOSE_A exec pi pi-shell-launch pi-session-log --forward-output install npm:pi-agent-browser-native"
  assert_log_has "$COMPOSE_A exec pi pi-shell-launch pi-session-log $*"
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
help_has $'  pi [--workspace PATH] [--bash|--zsh] [--no-rc-config] [--rebuild] [--oauth [PORTS...]]\n     [--replace|--keep-existing] [--new-state|[--seed] [--latest-state]] [PI_ARGS...]'
help_has $'[--oauth [PORTS...]]\n     --rm [PI_ARGS...]'
help_has 'pi [--workspace PATH] --host [PI_ARGS...]'
help_has 'pi [--workspace PATH] update [--extensions] [--models]'
help_has $'\n  pi list\n'
help_has 'pi [--workspace PATH] shell [--root|-r]'
help_has $'pi [--workspace PATH] copy [--from|--to] [-s|--sessions] [-a|--auth] [-e|--extensions]\n     [--all] [--override]'
help_has 'pi [--workspace PATH] - PI_ARGS...'
help_has 'it overrides PI_WORKSPACE. Relative paths resolve from the'
help_has '--workspace=PATH also works.'
help_has 'the workspace state volumes are still used.'
help_has '${PI_CODING_AGENT_DIR:-~/.pi/agent}/bin/pi'
help_has 'curl -fsSL https://pi.dev/install.sh | sh'
help_has "which uses the host's ~/.pi/agent state, not workspace volumes."
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
help_has 'pi install npm:pi-web-access'
help_has "pi - update                      # Pi's update command, run in the container."
help_has '--bash and --zsh are mutually exclusive.'
help_has '--replace and --keep-existing are mutually exclusive.'
help_has '--new-state cannot be combined with --seed or --latest-state.'
help_has $'--rm cannot be combined with stop, update, remove, list, shell, copy, --replace,\n  --keep-existing, --seed, or --latest-state.'
help_has $'--rebuild cannot be combined with stop, update, remove, list, or copy; with\n  shell it can only rebuild the current workspace\'s image.'
help_has $'--replace, --keep-existing, --new-state, --seed, --latest-state, and --oauth\n  cannot be combined with stop, remove, list, shell, or copy.'
help_has '--host accepts only --workspace among wrapper options;'
help_has 'list accepts no arguments, rejects --workspace, and does not change Docker state.'
help_has '--from and --to are mutually exclusive.'
help_has 'prompts for action and defaults to cancel.'
help_has 'a leading `-` sends'
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
     [--replace|--keep-existing] [--new-state|[--seed] [--latest-state]] [PI_ARGS...]
  pi [--workspace PATH] [--bash|--zsh] [--no-rc-config] [--rebuild] [--oauth [PORTS...]]
     --rm [PI_ARGS...]
  pi [--workspace PATH] --host [PI_ARGS...]
  pi [--workspace PATH] stop
  pi [--workspace PATH] update [--extensions] [--models]
  pi list
  pi [--workspace PATH] remove [--all]
  pi [--workspace PATH] shell [--root|-r]
  pi [--workspace PATH] copy [--from|--to] [-s|--sessions] [-a|--auth] [-e|--extensions]
     [--all] [--override]
  pi [--workspace PATH] - PI_ARGS...

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

# Help after the passthrough marker belongs to Pi.
fresh_stack
run_pi "$WS_A" - --help
expect_persistent_launch --help
fresh_stack
run_pi "$WS_A" --rm - --help
assert_status 0
assert_log_has "$COMPOSE_A run --rm --service-ports pi pi-shell-launch pi --help"

# Conflicting or unsupported options fail with status 2 before any Docker call.
expect_conflict() {
  local message=$1
  shift
  run_pi "$WS_A" "$@"
  assert_status 2
  assert_output_has "$message"
  assert_no_docker
}
expect_conflict 'pi: --bash and --zsh are mutually exclusive' --bash --zsh
expect_conflict 'pi: --replace and --keep-existing are mutually exclusive' --replace --keep-existing
expect_conflict 'pi: --seed cannot be combined with --new-state' --seed --new-state
expect_conflict 'pi: --from and --to are mutually exclusive' copy --from --to
expect_conflict 'pi: --oauth cannot be combined with stop' --oauth stop
expect_conflict 'pi: --oauth cannot be combined with remove' --oauth remove
expect_conflict 'pi: --oauth cannot be combined with remove' --oauth=1455 remove --all
for option in --replace --keep-existing --new-state --seed --latest-state --oauth; do
  expect_conflict 'pi: copy cannot be combined with launch, state, or OAuth options' "$option" copy
done
expect_conflict 'pi: --rebuild cannot be combined with copy' --rebuild copy
expect_conflict 'pi: --rm cannot be combined with copy' --rm copy
expect_conflict 'pi: --rebuild, --replace, and --keep-existing cannot be combined with update' --rebuild update
expect_conflict 'pi: --rebuild cannot be combined with stop' --rebuild stop
expect_conflict 'pi: --rebuild cannot be combined with remove' --rebuild remove
expect_conflict 'pi: usage: pi list' --rebuild list
expect_conflict 'pi: --rm cannot be combined with update' --rm update
expect_conflict 'pi: --rm cannot be combined with stop' --rm stop
expect_conflict 'pi: unsupported update option: --unknown' update --unknown
expect_conflict 'pi: unsupported remove option: --unknown' remove --unknown
expect_conflict 'pi: usage: pi stop' stop extra
expect_conflict 'pi: unsupported shell option: --unknown' shell --unknown
assert_output_has 'pi: usage: pi shell [--root|-r]'
expect_conflict 'pi: unsupported copy option: --unknown' copy --unknown
assert_output_has 'pi: usage: pi copy'
expect_conflict 'pi: - requires a Pi command' -
expect_conflict 'pi: --workspace requires a path' --workspace

# list takes no arguments and no launch options; it prints only its usage.
for arguments in 'list extra' '--rm list'; do
  # shellcheck disable=SC2086
  run_pi "$WS_A" $arguments
  assert_status 2
  assert_eq "$(cat -- "$OUTPUT_LOG")" 'pi: usage: pi list' "pi $arguments output"
  assert_no_docker
done

# --new-state with --latest-state is refused and leaves the seed pointer alone.
mkdir -p "$CONFIG_DIR"
printf '%s\n' "$(agent_volume "$WS_B")" > "$SEED_FILE"
expect_conflict 'pi: --latest-state cannot be combined with --new-state' --new-state --latest-state
assert_eq "$(seed_value)" "$(agent_volume "$WS_B")" 'seed pointer after a refused launch'

# Option guards run before workspace validation.
EXTRA_ENV=(PI_WORKSPACE="$TMP_DIR/missing-workspace")
expect_conflict 'pi: --rm cannot be combined with stop' --rm stop
EXTRA_ENV=()

# The invocation directory is the default workspace.
fresh_stack
run_pi "$WS_A" --version
expect_persistent_launch --version

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
assert_log_has "$COMPOSE_A run --rm --service-ports pi pi-shell-launch pi list"
assert_log_lacks 'run --rm --service-ports pi pi-shell-launch pi - list'

# --workspace overrides PI_WORKSPACE, in both option forms; relative paths
# resolve from the invocation directory.
EXTRA_ENV=(PI_WORKSPACE="$WS_A")
fresh_stack
run_pi "$WS_A" --workspace "$WS_B" --version
assert_status 0
assert_log_has "container=pi-agents-pi-beta network=pi-agents-pi-beta workspace=$WS_B agent="
assert_log_lacks "workspace=$WS_A agent="
fresh_stack
run_pi "$WS_A" --workspace=../beta --version
assert_status 0
assert_log_has "container=pi-agents-pi-beta network=pi-agents-pi-beta workspace=$WS_B agent="
assert_log_lacks "workspace=$WS_A agent="
EXTRA_ENV=()

pass
