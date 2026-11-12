#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN" "$TMP_DIR/workspace" "$TMP_DIR/cli-workspace" "$TMP_DIR/home"
: > "$TMP_DIR/home/.bash_profile"
: > "$TMP_DIR/home/.bashrc"
: > "$TMP_DIR/home/.zshenv"
: > "$TMP_DIR/home/.zprofile"
: > "$TMP_DIR/home/.zshrc"
: > "$TMP_DIR/home/.zlogin"
WORKSPACE="$(cd -P -- "$TMP_DIR/workspace" && pwd)"
CLI_WORKSPACE="$(cd -P -- "$TMP_DIR/cli-workspace" && pwd)"
DOCKER_LOG="$TMP_DIR/docker.log"
OUTPUT_LOG="$TMP_DIR/output.log"
export DOCKER_LOG

cat > "$FAKE_BIN/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
set -euo pipefail
log_docker_command() {
  local logged_command="$*"
  logged_command=${logged_command//$'\n'/\\n}
  printf '%s\n' "$logged_command" >> "$DOCKER_LOG"
}
if [[ "${1:-}" == "volume" ]]; then
  if [[ "${2:-}" == "ls" ]]; then
    exit 0
  fi
  if [[ "${2:-}" == "create" ]]; then
    exit 0
  fi
  if [[ "${2:-}" == "inspect" && "$*" == *com.pi-agents.managed* ]]; then
    exit 0
  fi
  exit 1
fi
if [[ "${1:-}" == "ps" ]]; then
  # stop and remove look up this workspace's own stack; report one.
  if [[ "$*" == *'label=com.pi-agents.workspace='* ]]; then
    stack_workspace="$*"
    stack_workspace="${stack_workspace#*label=com.pi-agents.workspace=}"
    printf '%s\n' "${stack_workspace%% --*}" > "$DOCKER_LOG.stack"
    printf 'stack-id\tpi-agents-pi-workspace\tpi-agents-pi-workspace\n'
  fi
  exit 0
fi
if [[ "${1:-}" == "inspect" && "$*" == *com.pi-agents.managed* ]]; then
  printf '/pi-agents-pi-workspace\037true\037%s\037pi-agents-pi-workspace\037pi\037False\n' "$(cat "$DOCKER_LOG.stack")"
  exit 0
fi
# Identity and helper-image lookups are not part of the asserted sequence.
if [[ "${1:-}" == "container" && "${2:-}" == "inspect" ]]; then
  exit 1
fi
if [[ "${1:-}" == "image" && "${2:-}" == "inspect" ]]; then
  exit 0
fi
if [[ "${1:-}" == "compose" && "$*" == *' config --images pi' ]]; then
  exit 0
fi
if [[ "${1:-}" == "run" ]]; then
  log_docker_command "$@"
  exit 0
fi
log_docker_command "$@"
if [[ "${1:-}" == "compose" ]]; then
  compose_args=("$@")
  for ((index = 1; index < ${#compose_args[@]} - 1; index++)); do
    if [[ "${compose_args[$index]}" == "--file" ]]; then
      override_file="${compose_args[$((index + 1))]}"
      case "$override_file" in
        */compose.yml|*/compose.oauth.yml|*/compose.shell-rc.yml) ;;
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

cat > "$FAKE_BIN/lsof" <<'FAKE_LSOF'
#!/usr/bin/env bash
# No OAuth callback port has a listener.
exit 1
FAKE_LSOF
chmod +x "$FAKE_BIN/lsof"

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
  candidates=("$expected")
  if [[ "$expected" == *"--file $ROOT/compose.yml "* ]]; then
    candidates+=("${expected/--file $ROOT\/compose.yml /--file $ROOT\/compose.yml --file $ROOT\/compose.shell-rc.yml }")
  fi
  if [[ "$expected" == *"--file $ROOT/compose.oauth.yml "* ]]; then
    candidates+=("${expected/--file $ROOT\/compose.oauth.yml /--file $ROOT\/compose.oauth.yml --file $ROOT\/compose.shell-rc.yml }")
  fi
  for candidate in "${candidates[@]}"; do
    if grep -Fq -- "$candidate" "$DOCKER_LOG"; then
      return 0
    fi
  done
  printf 'missing log fragment:\n%s\nactual:\n%s\n' "$expected" "$(cat "$DOCKER_LOG")" >&2
  exit 1
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
  expect_shell_alias_setup="${2:-false}"
  # The run lines include marking the new agent state initialized.
  expected_line_count=10
  expected_workspace_count=4
  if [[ "$expect_shell_alias_setup" == true ]]; then
    expected_line_count=12
    expected_workspace_count=5
  fi
  assert_log_line_count "$expected_line_count"
  assert_log_has_fragment "--project-directory $ROOT --file $ROOT/compose.yml up --detach pi"
  assert_log_lacks_fragment ' up --build '
  assert_log_has_fragment "--project-directory $ROOT --file $ROOT/compose.yml exec pi pi-shell-launch pi-session-log --forward-output install npm:pi-agent-browser-native"
  assert_log_has_fragment "$expected_exec"
  if [[ "$expect_shell_alias_setup" == true ]]; then
    assert_log_has_fragment "--project-directory $ROOT --file $ROOT/compose.yml exec -T pi sh -c"
    assert_log_has_fragment 'pi-agents managed host shell aliases'
  fi

  workspace_line="PI_WORKSPACE=$WORKSPACE"
  workspace_count="$(grep -Fxc -- "$workspace_line" "$DOCKER_LOG" || true)"
  if [[ "$workspace_count" -ne "$expected_workspace_count" ]]; then
    printf 'expected %s workspace propagation lines, got %s:\n%s\n' "$expected_workspace_count" "$workspace_count" "$(cat "$DOCKER_LOG")" >&2
    exit 1
  fi
}

run_wrapper update
assert_log_line_count 10
assert_log_has_fragment "--project-directory $ROOT --file $ROOT/compose.yml build --pull --no-cache pi"
assert_log_has_fragment "--project-directory $ROOT --file $ROOT/compose.yml up --detach --force-recreate pi"
assert_log_lacks_fragment ' up --build '
assert_log_has_fragment "--project-directory $ROOT --file $ROOT/compose.yml exec pi pi-shell-launch pi-session-log --forward-output install npm:pi-agent-browser-native"
assert_log_has_line "PI_WORKSPACE=$WORKSPACE"

run_wrapper update --extensions
assert_persistent_logged_exec "--project-directory $ROOT --file $ROOT/compose.yml exec pi pi-shell-launch pi-session-log --forward-output update --extensions"

run_wrapper update --models
assert_persistent_logged_exec "--project-directory $ROOT --file $ROOT/compose.yml exec pi pi-shell-launch pi-session-log --forward-output update --models"

run_wrapper update --extensions --models
assert_persistent_logged_exec "--project-directory $ROOT --file $ROOT/compose.yml exec pi pi-shell-launch pi-session-log --forward-output update --extensions --models"

run_wrapper stop
assert_log_has_fragment "--project-directory $ROOT --file $ROOT/compose.yml stop"

run_wrapper remove
assert_log_has_fragment "--project-directory $ROOT --file $ROOT/compose.yml down"
assert_log_lacks_fragment 'down --volumes'

run_wrapper remove --all
assert_log_has_fragment "--project-directory $ROOT --file $ROOT/compose.yml down"
assert_log_lacks_fragment 'down --volumes'

run_wrapper --rm --version
assert_log_line_count 6
assert_log_has_fragment "--project-directory $ROOT --file $ROOT/compose.yml run --rm --entrypoint /bin/sh pi -c"
assert_log_has_fragment "--project-directory $ROOT --file $ROOT/compose.yml run --rm --service-ports pi pi-shell-launch pi --version"
assert_log_lacks_fragment ' run --build '
assert_log_has_line "PI_WORKSPACE=$WORKSPACE"

run_wrapper --rebuild --version
# --rebuild builds the service image once before Compose recreates from it.
assert_log_line_count 14
assert_log_has_fragment "--project-directory $ROOT --file $ROOT/compose.yml build pi"
assert_log_has_fragment "--project-directory $ROOT --file $ROOT/compose.yml up --detach pi"
assert_log_lacks_fragment ' up --build '
assert_log_has_fragment "--project-directory $ROOT --file $ROOT/compose.yml exec pi pi-shell-launch pi-session-log --forward-output install npm:pi-agent-browser-native"
assert_log_has_fragment "--project-directory $ROOT --file $ROOT/compose.yml exec pi pi-shell-launch pi-session-log --version"

run_wrapper --rebuild --rm --version
assert_log_has_fragment "--project-directory $ROOT --file $ROOT/compose.yml build pi"
assert_log_has_fragment "--project-directory $ROOT --file $ROOT/compose.yml run --rm --entrypoint /bin/sh pi -c"
assert_log_has_fragment "--project-directory $ROOT --file $ROOT/compose.yml run --rm --service-ports pi pi-shell-launch pi --version"
assert_log_lacks_fragment ' run --build '

run_wrapper --new-state --version
assert_log_has_fragment "--project-directory $ROOT --file $ROOT/compose.yml up --detach --force-recreate pi"

run_wrapper --oauth --version
assert_log_has_fragment "--project-directory $ROOT --file $ROOT/compose.yml --file $ROOT/compose.oauth.yml exec pi pi-shell-launch pi-session-log --version"

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

printf 'bin/pi wrapper tests passed\n'
