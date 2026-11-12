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

# help_has TEXT / help_lacks TEXT: TEXT, which may span lines, is (not) in the output.
help_has() {
  [[ $(cat -- "$OUTPUT_LOG") == *"$1"* ]] || fail "output lacks: $1"$'\n'"$(show_run)"
}

help_lacks() {
  [[ $(cat -- "$OUTPUT_LOG") != *"$1"* ]] || fail "output unexpectedly has: $1"$'\n'"$(show_run)"
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
  assert_eq "$(docker_actions)" $'run\nrun\ncompose up --detach\ncompose exec -T\ncompose exec -T\ncompose exec pi\ncompose exec pi' 'docker actions'
  assert_log_has "$COMPOSE_A up --detach pi"
  assert_log_lacks ' up --build '
  assert_log_has "$COMPOSE_A exec -T pi test -x /usr/local/bin/pi-shell-launch"
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
help_has 'Containerized Pi wrapper'
help_has 'pi-agent-browser-native package'
help_has 'pi --replace'
help_has 'pi --keep-existing'
help_has '--workspace PATH'
help_has 'Takes precedence over PI_WORKSPACE'
help_has 'pi update --extensions'
help_has '# Update Pi-managed extensions.'
help_has 'pi update --models'
help_has "# Update Pi's model catalogs."
help_has 'pi list'
help_has 'List running and stopped persistent Pi stacks with workspace, project,'
help_has 'Docker creation/start timestamps, agent-state volume, and seed/latest markers.'
help_has $'  list\n      List running and stopped persistent Pi stacks with workspace, project,\n      Docker creation/start timestamps, agent-state volume, and seed/latest markers.'
help_has 'pi list                             # Inventory persistent Pi stacks without changing Docker state.'
help_has 'list accepts no positional arguments and does not change Docker state.'
help_has 'pi remove --all'
help_has '# Also remove Pi and browser persisted state.'
help_has '--new-state'
help_has 'pi --new-state'
help_has 'Run this workspace against its extra agent-state volume,'
help_has 'The extra volume starts empty and is never seeded, never becomes'
help_has 'active-state says whether the container mounts the normal or extra agent'
help_has 'browser state volumes, including the extra state volume.'
help_has 'from an existing'
help_has 'normal workspace state volume'
help_has '--seed'
help_has '--latest-state'
help_has "provisions the workspace's named volumes"
help_has '~/.config/pi-agent-containers/seed'
help_has 'PI_AGENT_CONTAINERS_CONFIG_PATH overrides the seed-pointer directory when needed.'
help_has 'oldest managed state volume'
help_has '--oauth'
help_has 'Known fixed callbacks 1455 (OpenAI Codex), 53692'
help_has '(Anthropic), and 51121 (pi-antigravity) are always published.'
help_has 'PI_OAUTH_CALLBACK_PORTS adds ports from the'
help_has 'pi --oauth 7000,7001'
help_has 'pi install npm:pi-web-access'
help_has 'Wrapper commands take precedence when names collide'
help_has 'pi [--workspace PATH] shell [--root|-r]'
help_has 'Open a shell in the current workspace container'
help_has '--root'
help_has 'pi shell --root'
help_has 'pi [--workspace PATH] copy [--from|--to]'
help_has '[--replace|--keep-existing] [--new-state|[--seed] [--latest-state]] [PI_ARGS...]'
help_has '[--oauth [PORTS...]] --rm [PI_ARGS...]'
help_has $'--rm cannot be combined with stop, update, remove, list, shell, copy, --replace,\n  --keep-existing, --seed, or --latest-state.'
help_has '--replace and --keep-existing are mutually exclusive.'
help_has '--oauth cannot be combined with stop or remove.'
help_has '--from and --to are mutually exclusive.'
help_has $'remove,\n  shell, and copy are handled by this wrapper'
help_has 'rc mount is reconciled with Compose up'
help_has '--sessions, -s'
help_has '--auth, -a'
help_has '--extensions, -e'
help_has '--override replaces duplicates automatically.'
help_has 'pi [--workspace PATH] - PI_ARGS...'
help_has 'pi - list'
help_has '0) Start a new project'
help_has 'X) Press Esc to cancel'
help_has 'Existing running and stopped containers are both considered during collision'
help_has 'Persistent Pi session records are streamed as readable, colored events'
help_has 'The session volume remains the'
help_has 'durable JSONL source.'
help_has 'Wrapper-managed package and model'
help_has 'so ~/src/my.project becomes pi-agents-pi-my-project.'
help_has $'pointer is missing while managed state volumes exist, pi lists them with\n  their creation times, warns, proposes the oldest managed state volume as the\n  seed, and asks for confirmation (y or yes) before initializing a new\n  workspace, even with --latest-state. Launching an already-initialized\n  workspace leaves a missing pointer unset unless --seed is given.'
help_has $'list ten or more containers, a choice starting with 1-9 is a number\n      confirmed with Enter (prompt: Choice (number, then Enter)).'
help_has 'update output is mirrored there too.'
help_has 'PI_SESSION_LOG_FORMAT=raw'
help_has 'PI_SESSION_LOG_COLOR=never'
help_has '--bash'
help_has '--zsh'
help_has '--no-rc-config'
help_has '--rebuild'
help_has '.bash_profile'
help_has '.bashrc'
help_has '.zshenv'
help_has '.zprofile'
help_has '.zshrc'
help_has '.zlogin'
help_has 'recursively'
help_has 'service bootstrap remains Bash'
help_has 'Use --rebuild to explicitly build the image with the cache.'
help_has 'pi update performs a pull and no-cache rebuild.'
help_has 'A stale image is reported'
help_has 'use pi update or --rebuild to recover.'
help_has '--rebuild cannot be combined with update, stop, remove, list, or copy.'
help_has 'pi [--workspace PATH] --host [PI_ARGS...]'
help_has 'Run native Pi on the host instead of Docker'
help_has '${PI_CODING_AGENT_DIR:-~/.pi/agent}/bin/pi'
help_has 'curl -fsSL https://pi.dev/install.sh | sh'
help_has 'pi --host update'
help_has 'pi --host - --help'
help_has '(list, stop, remove, copy) do'
help_has '--host accepts only --workspace'
help_has '--new-state cannot be combined with stop, remove, --seed, or --latest-state.'
help_has 'Before starting, pi refuses a selected port that something else already'
[[ $DETAILED_HELP == *'exits'*'with status 3.'* ]] || fail 'detailed help lacks the picker cancel status'
help_lacks 'without creating Compose resources'
help_has 'pi copy'
help_has '--override'
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
  pi [--workspace PATH] [--bash|--zsh] [--no-rc-config] [--rebuild] [--oauth [PORTS...]] --rm [PI_ARGS...]
  pi [--workspace PATH] --host [PI_ARGS...]
  pi [--workspace PATH] stop
  pi [--workspace PATH] update [--extensions] [--models]
  pi list
  pi [--workspace PATH] remove [--all]
  pi [--workspace PATH] shell [--root|-r]
  pi [--workspace PATH] copy [--from|--to] [--sessions, -s] [--auth, -a] [--extensions, -e] [--all] [--override]
  pi [--workspace PATH] - PI_ARGS...

Options:
  -h, --help        Show detailed help when used alone.
  --rm              Run Pi in a disposable one-off container.
  --host            Run native host Pi without Docker; offers to install it if missing.
  --replace         Force-recreate the current workspace container.
  --rebuild         Build the image with cache for this launch.
  --keep-existing   Preserve an existing colliding workspace container.
  --workspace PATH  Use PATH as the workspace; it overrides PI_WORKSPACE.
  --new-state       Use a separate, empty extra agent-state volume; normal state is kept.
                    Cannot be combined with --seed or --latest-state.
  --seed            Promote this workspace's state to the default seed state.
  --latest-state    Copy the newest Docker-managed state when initializing.
  --oauth [PORTS...] Publish known callback ports 1455/53692/51121; add comma- or
                     space-separated custom ports. Ports already in use are refused.
  --bash, --zsh      Force Bash or zsh instead of detecting SHELL.
  --no-rc-config     Start the selected shell without host startup files or an rc mount.

  Shell image        Reuses existing images; Compose builds if missing.
                     `--rebuild` uses cache; `pi update` pulls and rebuilds without cache.

  State volumes     Private per workspace; existing contents are preserved and
                    permissions are repaired before Pi starts.
  Browser integration Ensures pi-agent-browser-native is installed by default.
  Logging           Streams session events and wrapper package/model update output
                     to Docker logs; use PI_SESSION_LOG_FORMAT=raw for JSONL.
  Shell             Detects Bash/zsh from SHELL and recursively resolves the
                    matching host startup files into a read-only generated rc.
  Pi passthrough     Other arguments are passed to Pi in the workspace container.
                     Example: pi install npm:pi-web-access
                     Use `pi - PI_ARGS...` to force wrapper command names through
                     to Pi, for example: pi - list

Commands:
  stop              Stop the current workspace's persistent project.
  update            Rebuild Pi or update extensions/models.
  list              List running and stopped persistent Pi stacks (read-only).
  remove [--all]    Remove the current stack; --all also removes persisted state.
  shell [--root|-r] Open a shell in the current or selected Pi container.
  copy              Copy selected agent state between existing Pi containers.

Run `pi --help` for detailed usage.
BRIEF
)" 'brief usage'
BRIEF_USAGE=$(cat -- "$OUTPUT_LOG")
help_has '--bash, --zsh'
help_has '--no-rc-config'
help_has '--rebuild'
help_has 'Shell'
help_has 'wrapper package/model update output'
help_has '--workspace PATH'
help_has '--replace'
help_has '--keep-existing'
help_has '--new-state'
help_has '--seed'
help_has '--latest-state'
help_has '--host'
expect_brief_usage() {
  run_pi "$WS_A" "$@"
  assert_status 0
  assert_eq "$(cat -- "$OUTPUT_LOG")" "$BRIEF_USAGE" "pi $* prints the brief usage"
  assert_no_docker
}
for option in --replace --keep-existing --workspace --new-state --seed --latest-state --oauth \
  --bash --zsh --no-rc-config --rebuild --host; do
  expect_brief_usage "$option" --help
done
for command in update list stop remove shell copy; do
  expect_brief_usage "$command" --help
done
expect_brief_usage remove --all --help
expect_brief_usage --new-state --latest-state --help
expect_brief_usage --workspace "$WS_B" --host --help
expect_brief_usage --help --rm
run_pi "$WS_A" copy --help
assert_output_has 'Run `pi --help` for detailed usage.'

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
