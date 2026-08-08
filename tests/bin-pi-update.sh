#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN" "$TMP_DIR/workspace" "$TMP_DIR/cli-workspace"
WORKSPACE="$(cd -P -- "$TMP_DIR/workspace" && pwd)"
CLI_WORKSPACE="$(cd -P -- "$TMP_DIR/cli-workspace" && pwd)"
DOCKER_LOG="$TMP_DIR/docker.log"
OUTPUT_LOG="$TMP_DIR/output.log"
export DOCKER_LOG

cat > "$FAKE_BIN/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "volume" ]]; then
  if [[ "${2:-}" == "ls" ]]; then
    exit 0
  fi
  if [[ "${2:-}" == "create" ]]; then
    exit 0
  fi
  exit 1
fi
if [[ "${1:-}" == "ps" ]]; then
  exit 0
fi
if [[ "${1:-}" == "run" ]]; then
  printf '%s\n' "$*" >> "$DOCKER_LOG"
  exit 0
fi
printf '%s\n' "$*" >> "$DOCKER_LOG"
if [[ "${1:-}" == "compose" ]]; then
  compose_args=("$@")
  for ((index = 1; index < ${#compose_args[@]} - 1; index++)); do
    if [[ "${compose_args[$index]}" == "--file" ]]; then
      override_file="${compose_args[$((index + 1))]}"
      case "$override_file" in
        */compose.yml|*/compose.oauth.yml) ;;
        *)
          printf 'OAUTH_OVERRIDE_CONTENT\n' >> "$DOCKER_LOG"
          cat "$override_file" >> "$DOCKER_LOG"
          ;;
      esac
    fi
  done
fi
if [[ -v PI_WORKSPACE ]]; then
  printf 'PI_WORKSPACE=%s\n' "$PI_WORKSPACE" >> "$DOCKER_LOG"
fi
unset PI_WORKSPACE
FAKE_DOCKER
chmod +x "$FAKE_BIN/docker"

run_wrapper() {
  : > "$DOCKER_LOG"
  (
    cd "$TMP_DIR/workspace"
    env -u PI_WORKSPACE PI_AGENT_CONTAINERS_CONFIG_PATH="$TMP_DIR/state-registry" HOME="$TMP_DIR/home" PATH="$FAKE_BIN:$PATH" "$ROOT/bin/pi" "$@"
  )
}

assert_log() {
  expected="$1"
  actual="$(cat "$DOCKER_LOG")"
  if [[ "$actual" != "$expected" ]]; then
    printf 'expected:\n%s\nactual:\n%s\n' "$expected" "$actual" >&2
    exit 1
  fi
}

assert_log_has_line() {
  expected="$1"
  if ! grep -Fqx -- "$expected" "$DOCKER_LOG"; then
    printf 'missing log line:\n%s\nactual:\n%s\n' "$expected" "$(cat "$DOCKER_LOG")" >&2
    exit 1
  fi
}

assert_log_has_fragment() {
  expected="$1"
  if ! grep -Fq -- "$expected" "$DOCKER_LOG"; then
    printf 'missing log fragment:\n%s\nactual:\n%s\n' "$expected" "$(cat "$DOCKER_LOG")" >&2
    exit 1
  fi
}

assert_log_lacks_fragment() {
  unexpected="$1"
  if grep -Fq -- "$unexpected" "$DOCKER_LOG"; then
    printf 'unexpected log fragment:\n%s\nactual:\n%s\n' "$unexpected" "$(cat "$DOCKER_LOG")" >&2
    exit 1
  fi
}

assert_log_line_count() {
  expected="$1"
  actual="$(wc -l < "$DOCKER_LOG")"
  if [[ "$actual" -ne "$expected" ]]; then
    printf 'expected %s log lines, got %s:\n%s\n' "$expected" "$actual" "$(cat "$DOCKER_LOG")" >&2
    exit 1
  fi
}

run_wrapper_capture() {
  : > "$DOCKER_LOG"
  : > "$OUTPUT_LOG"
  (
    cd "$TMP_DIR/workspace"
    env -u PI_WORKSPACE PI_AGENT_CONTAINERS_CONFIG_PATH="$TMP_DIR/state-registry" HOME="$TMP_DIR/home" PATH="$FAKE_BIN:$PATH" "$ROOT/bin/pi" "$@"
  ) >"$OUTPUT_LOG" 2>&1
}

assert_output() {
  expected="$1"
  actual="$(cat "$OUTPUT_LOG")"
  if [[ "$actual" != "$expected" ]]; then
    printf 'expected output:\n%s\nactual output:\n%s\n' "$expected" "$actual" >&2
    exit 1
  fi
}

run_wrapper_with_workspace() {
  local workspace="$1"
  shift
  : > "$DOCKER_LOG"
  (
    cd "$TMP_DIR/workspace"
    env PI_WORKSPACE="$workspace" PI_AGENT_CONTAINERS_CONFIG_PATH="$TMP_DIR/state-registry" HOME="$TMP_DIR/home" PATH="$FAKE_BIN:$PATH" "$ROOT/bin/pi" "$@"
  )
}

assert_persistent_logged_exec() {
  expected_exec="$1"
  assert_log_line_count 7
  assert_log_has_fragment "--project-directory $ROOT --file $ROOT/compose.yml up --detach pi"
  assert_log_has_fragment "--project-directory $ROOT --file $ROOT/compose.yml exec pi pi install npm:pi-agent-browser-native"
  assert_log_has_fragment "$expected_exec"

  workspace_line="PI_WORKSPACE=$WORKSPACE"
  workspace_count="$(grep -Fxc -- "$workspace_line" "$DOCKER_LOG" || true)"
  if [[ "$workspace_count" -ne 3 ]]; then
    printf 'expected 3 workspace propagation lines, got %s:\n%s\n' "$workspace_count" "$(cat "$DOCKER_LOG")" >&2
    exit 1
  fi
}

run_wrapper_capture --help
DETAILED_HELP="$(cat "$OUTPUT_LOG")"
assert_log ""
[[ "$DETAILED_HELP" == *'Containerized Pi wrapper'* ]]
[[ "$DETAILED_HELP" == *'pi-agent-browser-native package'* ]]
[[ "$DETAILED_HELP" == *'pi --replace'* ]]
[[ "$DETAILED_HELP" == *'pi --keep-existing'* ]]
[[ "$DETAILED_HELP" == *'--workspace PATH'* ]]
[[ "$DETAILED_HELP" == *'Takes precedence over PI_WORKSPACE'* ]]
[[ "$DETAILED_HELP" == *'pi update --extensions'* ]]
[[ "$DETAILED_HELP" == *'# Update Pi-managed extensions.'* ]]
[[ "$DETAILED_HELP" == *'pi update --models'* ]]
[[ "$DETAILED_HELP" == *"# Update Pi's model catalogs."* ]]
[[ "$DETAILED_HELP" == *'pi list'* ]]
[[ "$DETAILED_HELP" == *'List running and stopped persistent Pi stacks with workspace, project,'* ]]
[[ "$DETAILED_HELP" == *'Docker creation/start timestamps, agent-state volume, and seed/latest markers.'* ]]
[[ "$DETAILED_HELP" == *$'  list\n      List running and stopped persistent Pi stacks with workspace, project,\n      Docker creation/start timestamps, agent-state volume, and seed/latest markers.'* ]]
[[ "$DETAILED_HELP" == *'pi list                             # Inventory persistent Pi stacks without changing Docker state.'* ]]
[[ "$DETAILED_HELP" == *'list accepts no positional arguments and does not change Docker state.'* ]]
[[ "$DETAILED_HELP" == *'pi remove --all'* ]]
[[ "$DETAILED_HELP" == *'# Also remove Pi and browser persisted state.'* ]]
[[ "$DETAILED_HELP" == *'--new-state'* ]]
[[ "$DETAILED_HELP" == *'pi --new-state'* ]]
[[ "$DETAILED_HELP" == *'from the workspace currently designated as the'* ]]
[[ "$DETAILED_HELP" == *'seed. Workspace sessions remain isolated.'* ]]
[[ "$DETAILED_HELP" == *'from an existing'* ]]
[[ "$DETAILED_HELP" == *'normal workspace state volume'* ]]
[[ "$DETAILED_HELP" == *'--seed'* ]]
[[ "$DETAILED_HELP" == *'--latest-state'* ]]
[[ "$DETAILED_HELP" == *"provisions the workspace's named volumes"* ]]
[[ "$DETAILED_HELP" == *'~/.config/pi-agent-containers/seed'* ]]
[[ "$DETAILED_HELP" == *'PI_AGENT_CONTAINERS_CONFIG_PATH overrides the seed-pointer directory when needed.'* ]]
[[ "$DETAILED_HELP" == *'oldest managed state volume'* ]]
[[ "$DETAILED_HELP" == *'--oauth'* ]]
[[ "$DETAILED_HELP" == *'Known fixed callbacks 1455 (OpenAI Codex), 53692'* ]]
[[ "$DETAILED_HELP" == *'(Anthropic), and 51121 (pi-antigravity) are always published.'* ]]
[[ "$DETAILED_HELP" == *'PI_OAUTH_CALLBACK_PORTS adds ports from the'* ]]
[[ "$DETAILED_HELP" == *'pi --oauth 7000,7001'* ]]
[[ "$DETAILED_HELP" == *'pi install npm:pi-web-access'* ]]
[[ "$DETAILED_HELP" == *'Wrapper commands take precedence when names collide'* ]]
[[ "$DETAILED_HELP" == *'pi shell [--root|-r]'* ]]
[[ "$DETAILED_HELP" == *'Open a shell in the current workspace container'* ]]
[[ "$DETAILED_HELP" == *'--root'* ]]
[[ "$DETAILED_HELP" == *'pi shell --root'* ]]
[[ "$DETAILED_HELP" == *'pi copy [--from] [--to]'* ]]
[[ "$DETAILED_HELP" == *'--sessions, -s'* ]]
[[ "$DETAILED_HELP" == *'--auth, -a'* ]]
[[ "$DETAILED_HELP" == *'--extensions, -e'* ]]
[[ "$DETAILED_HELP" == *'--override replaces duplicates automatically.'* ]]
[[ "$DETAILED_HELP" == *'pi - PI_ARGS...'* ]]
[[ "$DETAILED_HELP" == *'pi - list'* ]]
[[ "$DETAILED_HELP" == *'0) Start a new project'* ]]
[[ "$DETAILED_HELP" == *'X) Press Esc to cancel'* ]]
[[ "$DETAILED_HELP" == *'Existing running and stopped containers are both considered during collision'* ]]
[[ "$DETAILED_HELP" == *'Persistent Pi session records are streamed as readable, colored events'* ]]
[[ "$DETAILED_HELP" == *'The session volume remains the'* ]]
[[ "$DETAILED_HELP" == *'durable JSONL source.'* ]]
[[ "$DETAILED_HELP" == *'PI_SESSION_LOG_FORMAT=raw'* ]]
[[ "$DETAILED_HELP" == *'PI_SESSION_LOG_COLOR=never'* ]]

run_wrapper_capture -h
assert_output "$DETAILED_HELP"
assert_log ""

run_wrapper_capture --rm --help
assert_output "$(cat <<'EOF'
Usage:
  pi [-h|--help]
  pi [--oauth [PORTS...]] [--replace] [--keep-existing] [PI_ARGS...]
  pi --oauth [PORTS...] --rm [PI_ARGS...]
  pi stop
  pi update [--extensions] [--models]
  pi list
  pi remove [--all]
  pi shell [--root|-r]
  pi copy [--from] [--to] [--sessions, -s] [--auth, -a] [--extensions, -e] [--all] [--override]
  pi - PI_ARGS...

Options:
  -h, --help        Show detailed help when used alone.
  --rm              Run Pi in a disposable one-off container.
  --replace         Force-recreate the current workspace container.
  --keep-existing   Preserve an existing colliding workspace container.
  --workspace PATH  Use PATH as the workspace; it overrides PI_WORKSPACE.
  --new-state       Start empty; skip copying agent-state files from the seed workspace.
  --seed            Promote this workspace's state to the default seed state.
  --latest-state    Copy the newest Docker-managed state when initializing.
  --oauth [PORTS...] Publish known callback ports 1455/53692/51121; add comma- or
                     space-separated custom ports.

  State volumes     Private per workspace; existing contents are preserved and
                    permissions are repaired before Pi starts.
  Browser integration Ensures pi-agent-browser-native is installed by default.
  Logging           Streams pretty colored session events to Docker logs by
                    default; use PI_SESSION_LOG_FORMAT=raw for JSONL.
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
EOF
)"
assert_log ""
BRIEF_USAGE="$(cat "$OUTPUT_LOG")"

run_wrapper_capture --replace --help
assert_output "$BRIEF_USAGE"
assert_log ""

run_wrapper_capture --keep-existing --help
assert_output "$BRIEF_USAGE"
assert_log ""

run_wrapper_capture --workspace --help
assert_output "$BRIEF_USAGE"
assert_log ""

run_wrapper_capture update --help
assert_output "$BRIEF_USAGE"
assert_log ""

run_wrapper_capture list --help
assert_output "$BRIEF_USAGE"
assert_log ""

run_wrapper_capture stop --help
assert_output "$BRIEF_USAGE"
assert_log ""

run_wrapper_capture remove --help
assert_output "$BRIEF_USAGE"
assert_log ""

run_wrapper_capture remove --all --help
assert_output "$BRIEF_USAGE"
assert_log ""

run_wrapper_capture --new-state --help
assert_output "$BRIEF_USAGE"
assert_log ""

run_wrapper_capture --seed --help
assert_output "$BRIEF_USAGE"
assert_log ""

run_wrapper_capture --latest-state --help
assert_output "$BRIEF_USAGE"
assert_log ""

run_wrapper_capture --oauth --help
assert_output "$BRIEF_USAGE"
assert_log ""

run_wrapper_capture --help --rm
assert_output "$BRIEF_USAGE"
assert_log ""

run_wrapper_capture shell --help
assert_output "$BRIEF_USAGE"
assert_log ""

run_wrapper update
assert_log_line_count 7
assert_log_has_fragment "--project-directory $ROOT --file $ROOT/compose.yml build --pull --no-cache pi"
assert_log_has_fragment "--project-directory $ROOT --file $ROOT/compose.yml up --detach --force-recreate pi"
assert_log_has_fragment "--project-directory $ROOT --file $ROOT/compose.yml exec pi pi install npm:pi-agent-browser-native"
assert_log_has_line "PI_WORKSPACE=$WORKSPACE"

run_wrapper update --extensions
assert_persistent_logged_exec "--project-directory $ROOT --file $ROOT/compose.yml exec pi pi-session-log update --extensions"

run_wrapper update --models
assert_persistent_logged_exec "--project-directory $ROOT --file $ROOT/compose.yml exec pi pi-session-log update --models"

run_wrapper update --extensions --models
assert_persistent_logged_exec "--project-directory $ROOT --file $ROOT/compose.yml exec pi pi-session-log update --extensions --models"

if run_wrapper update --unknown; then
  printf 'unsupported update argument unexpectedly succeeded\n' >&2
  exit 1
else
  status=$?
  if [[ "$status" -ne 2 ]]; then
    printf 'unsupported update argument returned status %s, expected 2\n' "$status" >&2
    exit 1
  fi
fi
assert_log ""

if run_wrapper --rm update; then
  printf -- '--rm update unexpectedly succeeded\n' >&2
  exit 1
else
  status=$?
  if [[ "$status" -ne 2 ]]; then
    printf -- '--rm update returned status %s, expected 2\n' "$status" >&2
    exit 1
  fi
fi
assert_log ""

run_wrapper stop
assert_log_has_fragment "--project-directory $ROOT --file $ROOT/compose.yml stop"

run_wrapper remove
assert_log_has_fragment "--project-directory $ROOT --file $ROOT/compose.yml down"
assert_log_lacks_fragment 'down --volumes'

run_wrapper remove --all
assert_log_has_fragment "--project-directory $ROOT --file $ROOT/compose.yml down"
assert_log_lacks_fragment 'down --volumes'

if run_wrapper remove --unknown; then
  printf 'unsupported remove argument unexpectedly succeeded\n' >&2
  exit 1
else
  status=$?
  if [[ "$status" -ne 2 ]]; then
    printf 'unsupported remove argument returned status %s, expected 2\n' "$status" >&2
    exit 1
  fi
fi
assert_log ""

if run_wrapper stop extra; then
  printf 'stop with extra argument unexpectedly succeeded\n' >&2
  exit 1
else
  status=$?
  if [[ "$status" -ne 2 ]]; then
    printf 'stop with extra argument returned status %s, expected 2\n' "$status" >&2
    exit 1
  fi
fi
assert_log ""

if run_wrapper --rm stop; then
  printf -- '--rm stop unexpectedly succeeded\n' >&2
  exit 1
else
  status=$?
  if [[ "$status" -ne 2 ]]; then
    printf -- '--rm stop returned status %s, expected 2\n' "$status" >&2
    exit 1
  fi
fi
assert_log ""

if run_wrapper_with_workspace "$TMP_DIR/missing-workspace" --rm stop; then
  printf -- '--rm stop with invalid workspace unexpectedly succeeded\n' >&2
  exit 1
else
  status=$?
  if [[ "$status" -ne 2 ]]; then
    printf -- '--rm stop with invalid workspace returned status %s, expected 2\n' "$status" >&2
    exit 1
  fi
fi
assert_log ""

run_wrapper --rm --version
assert_log_line_count 5
assert_log_has_fragment "--project-directory $ROOT --file $ROOT/compose.yml run --rm pi pi install npm:pi-agent-browser-native"
assert_log_has_fragment "--project-directory $ROOT --file $ROOT/compose.yml run --rm --service-ports pi pi --version"
assert_log_has_line "PI_WORKSPACE=$WORKSPACE"

run_wrapper --version
assert_persistent_logged_exec "--project-directory $ROOT --file $ROOT/compose.yml exec pi pi-session-log --version"

run_wrapper - list
assert_persistent_logged_exec "--project-directory $ROOT --file $ROOT/compose.yml exec pi pi-session-log list"
assert_log_lacks_fragment 'exec pi pi-session-log - list'

run_wrapper - stop
assert_persistent_logged_exec "--project-directory $ROOT --file $ROOT/compose.yml exec pi pi-session-log stop"
assert_log_lacks_fragment ' stop$'

run_wrapper - update
assert_persistent_logged_exec "--project-directory $ROOT --file $ROOT/compose.yml exec pi pi-session-log update"
assert_log_lacks_fragment ' build --pull --no-cache pi'

run_wrapper - remove
assert_persistent_logged_exec "--project-directory $ROOT --file $ROOT/compose.yml exec pi pi-session-log remove"
assert_log_lacks_fragment ' down'

run_wrapper - shell
assert_persistent_logged_exec "--project-directory $ROOT --file $ROOT/compose.yml exec pi pi-session-log shell"

if run_wrapper -; then
  printf 'empty passthrough marker unexpectedly succeeded\n' >&2
  exit 1
else
  rc=$?
  [[ "$rc" -eq 2 ]]
fi
assert_log ""

run_wrapper - --help
assert_persistent_logged_exec "--project-directory $ROOT --file $ROOT/compose.yml exec pi pi-session-log --help"

run_wrapper --rm - list
assert_log_has_fragment "--project-directory $ROOT --file $ROOT/compose.yml run --rm --service-ports pi pi list"
assert_log_lacks_fragment 'run --rm --service-ports pi pi - list'

run_wrapper --rm - --help
assert_log_has_fragment "--project-directory $ROOT --file $ROOT/compose.yml run --rm --service-ports pi pi --help"

run_wrapper --new-state --version
assert_log_has_fragment "--project-directory $ROOT --file $ROOT/compose.yml up --detach --force-recreate pi"

run_wrapper --oauth --version
assert_log_has_fragment "--project-directory $ROOT --file $ROOT/compose.yml --file $ROOT/compose.oauth.yml exec pi pi-session-log --version"

PI_OAUTH_CALLBACK_PORTS='7000,7001' run_wrapper --oauth --version
assert_log_has_fragment 'OAUTH_OVERRIDE_CONTENT'
assert_log_lacks_fragment 'pi-oauth.XXXXXX'
assert_log_has_fragment '127.0.0.1:7000:7000'
assert_log_has_fragment '[::1]:7000:7000'
assert_log_has_fragment '127.0.0.1:7001:7001'
assert_log_has_fragment '[::1]:7001:7001'

PI_OAUTH_CALLBACK_PORTS='7005 7006' run_wrapper --oauth --version
assert_log_has_fragment '127.0.0.1:7005:7005'
assert_log_has_fragment '[::1]:7006:7006'

run_wrapper --oauth 7002,7003 7004 --version
assert_log_has_fragment '127.0.0.1:7002:7002'
assert_log_has_fragment '[::1]:7003:7003'
assert_log_has_fragment '127.0.0.1:7004:7004'

if run_wrapper --oauth 70000 --version; then
  printf 'out-of-range OAuth callback port unexpectedly succeeded\n' >&2
  exit 1
else
  status=$?
  if [[ "$status" -ne 2 ]]; then
    printf 'out-of-range OAuth callback port returned status %s, expected 2\n' "$status" >&2
    exit 1
  fi
fi

run_wrapper_with_workspace "$TMP_DIR/workspace" --workspace "$CLI_WORKSPACE" --version
assert_log_has_line "PI_WORKSPACE=$CLI_WORKSPACE"

run_wrapper_with_workspace "$TMP_DIR/workspace" --workspace=../cli-workspace --version
assert_log_has_line "PI_WORKSPACE=$CLI_WORKSPACE"

if run_wrapper --workspace; then
  printf 'missing --workspace path unexpectedly succeeded\n' >&2
  exit 1
else
  status=$?
  if [[ "$status" -ne 2 ]]; then
    printf 'missing --workspace path returned status %s, expected 2\n' "$status" >&2
    exit 1
  fi
fi
assert_log ""

printf 'bin/pi wrapper tests passed\n'
