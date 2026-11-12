#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
FAKE_BIN="$TMP_DIR/bin"
WORKSPACE="$TMP_DIR/workspace"
mkdir -p "$FAKE_BIN" "$WORKSPACE" "$TMP_DIR/home"
OUTPUT_LOG="$TMP_DIR/output.log"
DOCKER_LOG="$TMP_DIR/docker.log"
OTHER_WORKSPACE="$TMP_DIR/other-workspace"
mkdir -p "$OTHER_WORKSPACE"
CURRENT_PATH="$(cd -P -- "$WORKSPACE" && pwd)"
OTHER_PATH="$(cd -P -- "$OTHER_WORKSPACE" && pwd)"
export DOCKER_LOG

cat > "$FAKE_BIN/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker %s\n' "$*" >> "$DOCKER_LOG"
case "${1:-}" in
  ps)
    printf 'current-id\tpi-agents-pi-current\tUp 1 minute\trunning\t%s\n' "$FAKE_CURRENT_WORKSPACE"
    printf 'other-id\tpi-agents-pi-other\tExited (0) 1 hour ago\texited\t%s\n' "$FAKE_OTHER_WORKSPACE"
    # FAKE_EXTRA_CONTAINERS adds that many more stacks to the picker.
    for ((index = 1; index <= ${FAKE_EXTRA_CONTAINERS:-0}; index++)); do
      printf 'extra-%s-id\tpi-agents-pi-extra-%s\tExited (0) 1 hour ago\texited\t/extra-%s\n' "$index" "$index" "$index"
    done
    ;;
  inspect)
    if [[ "$*" == *'/home/node/.pi/agent/sessions'* ]]; then
      [[ "${FAKE_NO_SESSION_MOUNT-}" == 1 ]] && exit 0
      case "${@: -1}" in
        pi-agents-pi-current) printf 'pi-agents-ws-current_pi-sessions\n' ;;
        pi-agents-pi-other) printf 'pi-agents-ws-other_pi-sessions\n' ;;
        *) exit 1 ;;
      esac
      exit 0
    fi
    case "${@: -1}" in
      pi-agents-pi-current) printf 'pi-agents-ws-current_pi-agent-state\n' ;;
      pi-agents-pi-other) printf 'pi-agents-ws-other_pi-agent-state\n' ;;
      pi-agents-pi-extra-*) name="${@: -1}"; printf 'pi-agents-ws-extra-%s_pi-agent-state\n' "${name##*-}" ;;
      *) exit 1 ;;
    esac
    ;;
  volume)
    if [[ "${2:-}" == ls && "$*" == *'state-kind=sessions'* && -n "${FAKE_LABELLED_SESSIONS_WORKSPACE-}" &&
      "$*" == *"com.pi-agents.workspace=$FAKE_LABELLED_SESSIONS_WORKSPACE "* ]]; then
      printf 'pi-agents-ws-labelled_pi-sessions\n'
    fi
    exit 0
    ;;
  compose|run) exit 0 ;;
  *) exit 0 ;;
esac
FAKE_DOCKER
chmod +x "$FAKE_BIN/docker"

run_capture() {
  : > "$OUTPUT_LOG"
  (cd "$WORKSPACE" && env -u PI_WORKSPACE HOME="$TMP_DIR/home" PATH="$FAKE_BIN:$PATH" "$ROOT/bin/pi" "$@") >"$OUTPUT_LOG" 2>&1 || return $?
}

: > "$DOCKER_LOG"
export FAKE_CURRENT_WORKSPACE="$CURRENT_PATH" FAKE_OTHER_WORKSPACE="$OTHER_PATH"
printf '1' | run_capture copy --from --sessions --all
grep -Fq -- 'pi-state-copy' "$DOCKER_LOG"
grep -Fq -- 'bash /usr/local/bin/pi-state-copy' "$DOCKER_LOG"
if grep -Fq -- '--no-deps' "$DOCKER_LOG"; then
  printf 'copy helper must not inherit Compose capability drops\n' >&2
  exit 1
fi
grep -Fq -- 'docker run --rm -i --user 0' "$DOCKER_LOG"
grep -Fq -- 'pi-agents-ws-other_pi-agent-state:/state-source:ro' "$DOCKER_LOG"
grep -Fq -- 'pi-agents-ws-current_pi-agent-state:/state-target' "$DOCKER_LOG"
# Sessions live in a separate volume; legacy unlabelled volumes are found
# through each container's sessions mount, and the target's is repaired.
grep -Fq -- 'pi-agents-ws-other_pi-sessions:/state-source/sessions:ro' "$DOCKER_LOG"
grep -Fq -- 'pi-agents-ws-current_pi-sessions:/state-target/sessions' "$DOCKER_LOG"
grep -Fq -- 'pi-agents-ws-current_pi-sessions:/sessions' "$DOCKER_LOG"

# A labelled session volume is located by its workspace label.
: > "$DOCKER_LOG"
printf '1' | FAKE_LABELLED_SESSIONS_WORKSPACE="$OTHER_PATH" run_capture copy --from --sessions --all
grep -Fq -- 'pi-agents-ws-labelled_pi-sessions:/state-source/sessions:ro' "$DOCKER_LOG"

# A missing session volume fails before the helper runs.
: > "$DOCKER_LOG"
if printf '1' | FAKE_NO_SESSION_MOUNT=1 run_capture copy --from --sessions --all; then
  printf 'copy without a session volume unexpectedly succeeded\n' >&2
  exit 1
fi
grep -Fq -- 'no session volume found for workspace' "$OUTPUT_LOG"
if grep -Fq -- 'pi-state-copy' "$DOCKER_LOG"; then
  printf 'copy helper ran without a session volume\n' >&2
  exit 1
fi

# Auth-only copies do not need session volumes.
: > "$DOCKER_LOG"
printf '1' | FAKE_NO_SESSION_MOUNT=1 run_capture copy --to --auth --all
grep -Fq -- 'Choose a destination Pi container:' "$OUTPUT_LOG"
grep -Fq -- 'pi-agents-ws-current_pi-agent-state:/state-source:ro' "$DOCKER_LOG"
grep -Fq -- 'pi-agents-ws-other_pi-agent-state:/state-target' "$DOCKER_LOG"
if grep -Fq -- '_pi-sessions:/' "$DOCKER_LOG"; then
  printf 'auth-only copy mounted session volumes:\n%s\n' "$(cat "$DOCKER_LOG")" >&2
  exit 1
fi

# With ten or more entries the picker waits for Enter after a leading 1-9,
# so a slowly typed 10 selects item 10 rather than item 1.
: > "$DOCKER_LOG"
{ printf 1; sleep 0.3; printf '0\n'; } | FAKE_EXTRA_CONTAINERS=10 run_capture copy --auth --all
grep -Fq -- 'Choice (number, then Enter): ' "$OUTPUT_LOG"
grep -Fq -- 'pi-agents-ws-extra-9_pi-agent-state:/state-source:ro' "$DOCKER_LOG"

# Shorter lists keep single-key selection.
: > "$DOCKER_LOG"
printf '1' | run_capture copy --auth --all
grep -Fq -- 'Choice: ' "$OUTPUT_LOG"
grep -Fq -- 'pi-agents-ws-other_pi-agent-state:/state-source:ro' "$DOCKER_LOG"

# Cancelling the picker exits 3 and copies nothing; invalid choices exit 2.
for cancel in x X $'\e' ''; do
  : > "$DOCKER_LOG"
  status=0
  printf '%s' "$cancel" | run_capture copy --auth --all || status=$?
  if [[ "$status" -ne 3 ]] || grep -Fq -- '/state-source' "$DOCKER_LOG"; then
    printf 'picker cancel %q: expected status 3 without copy, got %s\n%s\n' "$cancel" "$status" "$(cat "$OUTPUT_LOG")" >&2
    exit 1
  fi
done
status=0
printf '9' | run_capture copy --auth --all || status=$?
[[ "$status" -eq 2 ]] || { printf 'invalid picker choice exited %s, expected 2\n' "$status" >&2; exit 1; }

printf 'bin/pi copy tests passed\n'
