#!/usr/bin/env bash
# Agent state: seed pointer, --seed, --new-state, --latest-state, initialization markers, pending recovery, missing-pointer confirmation, and permission repair.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.bash"
source "$ROOT/tests/lib/launcher.bash"

UNLABEL=(-label.com.pi-agents.managed -label.com.pi-agents.workspace -label.com.pi-agents.project -label.com.pi-agents.state-kind)

# Keep each auth/settings probe script so it can run against a real directory.
mv "$FAKE_BIN/docker" "$FAKE_BIN/docker-fake"
cat > "$FAKE_BIN/docker" <<'PROBE_CAPTURE'
#!/usr/bin/env bash
if [[ ${1:-} == run && $* == *'exit 42'* ]]; then printf '%s' "${@: -1}" > "${DOCKER_LOG%/*}/auth-probe.sh"; fi
exec "$(dirname -- "$0")/docker-fake" "$@"
PROBE_CAPTURE
chmod +x "$FAKE_BIN/docker"

# The agent-state volume of the last Compose call.
target_volume() {
  grep -F 'compose-env ' "$DOCKER_LOG" | tail -n 1 | sed -E 's/.* agent=([^ ]*) .*/\1/'
}

assert_source() {
  assert_log_has "$1:/state-source:ro"
}

assert_no_source_copy() {
  assert_log_lacks ':/state-source:ro'
}

# The first log line containing $1 precedes the first containing $2.
assert_log_order() {
  local first second
  first=$(grep -nF -- "$1" "$DOCKER_LOG" | head -n 1 | cut -d: -f1)
  second=$(grep -nF -- "$2" "$DOCKER_LOG" | head -n 1 | cut -d: -f1)
  [[ -n $first && -n $second && $first -lt $second ]] || fail "expected $1 before $2"$'\n'"$(show_run)"
}

set_seed() {
  mkdir -p "$CONFIG_DIR"
  printf '%s\n' "$1" > "$SEED_FILE"
}

snapshot() { rm -rf -- "$TMP_DIR/snapshot-$1"; cp -R -- "$FAKE_DOCKER_STATE" "$TMP_DIR/snapshot-$1"; }
restore() { rm -rf -- "$FAKE_DOCKER_STATE"; cp -R -- "$TMP_DIR/snapshot-$1" "$FAKE_DOCKER_STATE"; }

# --- Seeding a new workspace from the seed pointer ---
WS=$(make_workspace "$TEST_HOME/projects/workspace")
TARGET=$(agent_volume "$WS")
SOURCE=pi-agents-ws-source_pi-agent-state

# seed_source: an initialized seed volume of another workspace and the pointer to it.
seed_source() {
  reset_docker
  fake_volume "$SOURCE" /elsewhere agent 2026-08-01T12:00:00Z
  fake_volume_file "$SOURCE" .container-initialized complete
  fake_volume_file "$SOURCE" auth.json '{"provider":{}}'
  set_seed "$SOURCE"
}

seed_source
run_pi "$WS" - --version
assert_status 0
assert_source "$SOURCE"
volume_has_file "$TARGET" auth.json || fail 'the seed state must be copied'
# State permissions are repaired for the persisted session volume.
assert_log_has '--user 0:0'
assert_log_has ':/sessions'
# New state volumes are provisioned with Docker metadata.
assert_log_has '--label com.pi-agents.managed=true'
assert_log_has '--label com.pi-agents.state-kind=agent'
assert_log_has '--label com.pi-agents.state-kind=sessions'
assert_log_has '--label com.pi-agents.state-kind=browser'
# Helpers run the configured Pi service image with an explicit user.
assert_log_lacks 'alpine'
if grep -E '^docker run ' "$DOCKER_LOG" | grep -Fv -- '--user ' | grep -q .; then
  fail "helper containers must use the Pi image with an explicit user"$'\n'"$(show_run)"
fi
assert_log_has 'config --images pi'
assert_log_matches '^docker run .* pi-agents-pi-workspace-pi sh -c'
# The seed is recorded as pending before copying and completed afterwards.
assert_log_has "state-initialization pending $SOURCE"
assert_log_has 'state-initialization complete'
assert_log_order "state-initialization pending $SOURCE" "$SOURCE:/state-source:ro"
assert_log_order "$SOURCE:/state-source:ro" 'state-initialization complete'
assert_eq "$(cat -- "$FAKE_DOCKER_STATE/volume-data/$TARGET/.container-initialized")" complete 'target marker'
! volume_has_file "$TARGET" .container-initialization-pending || fail 'pending marker must be cleared'
assert_eq "$(seed_value)" "$SOURCE" 'inheriting must not move the seed'
assert_log_lacks 'pi-agents_pi-agent-state'

# A labelled state volume that belongs to another workspace is refused.
seed_source
fake_volume "$TARGET" /elsewhere agent 2026-08-02T12:00:00Z
run_pi "$WS" - --version
assert_status 2
assert_output_has "state volume workspace label does not match: $TARGET"
assert_log_lacks ' up '

# A state volume labelled with another kind is refused.
seed_source
fake_volume "$TARGET" "$WS" browser 2026-08-02T12:00:00Z
run_pi "$WS" - --version
assert_status 2
assert_output_has "state volume kind label does not match: $TARGET"
assert_log_lacks ' up '

# Agent, session, and browser volumes without the managed labels are refused
# before anything starts.
for volume in "$TARGET" "$(session_volume "$WS")" "$(browser_volume "$WS")"; do
  seed_source
  fake_volume "$volume" "$WS" agent 2026-08-02T12:00:00Z "${UNLABEL[@]}"
  run_pi "$WS" - --version
  assert_status 2
  assert_output_has "state volume is not managed: $volume"
  assert_log_lacks ' up '
  assert_log_lacks 'docker run '
done

# An existing pre-marker volume with useful state is not seeded again.
seed_source
fake_volume "$TARGET" "$WS" agent 2026-08-02T12:00:00Z
fake_volume_file "$TARGET" auth.json '{"provider":{}}'
run_pi "$WS" - --version
assert_status 0
assert_no_source_copy

# An existing volume without useful state is seeded.
seed_source
fake_volume "$TARGET" "$WS" agent 2026-08-02T12:00:00Z
run_pi "$WS" - --version
assert_status 0
assert_source "$SOURCE"

# Initialization probe failures stop the launch.
seed_source
fake_volume "$TARGET" "$WS" agent 2026-08-02T12:00:00Z
EXTRA_ENV=(FAKE_INIT_PROBE_STATUS=43)
run_pi "$WS" - --version
EXTRA_ENV=()
assert_status 2
assert_output_has 'pi: could not inspect agent-state initialization status'
assert_no_source_copy
assert_log_lacks ' up '

# An unmanaged seed pointer is replaced by the launched workspace when no
# other managed state exists.
reset_docker
fake_volume "$SOURCE" /elsewhere agent 2026-08-01T12:00:00Z label.com.pi-agents.managed=false
set_seed "$SOURCE"
run_pi "$WS" - --version
assert_status 0
assert_output_lacks 'use it as the seed for this new workspace'
assert_no_source_copy
assert_eq "$(seed_value)" "$TARGET" 'invalid seed is replaced on launch'

# Without a seed, a new workspace starts empty on its own volume and never
# touches the old shared default volume.
reset_docker
run_pi "$WS" - --version
assert_status 0
assert_eq "$(target_volume)" "$TARGET" 'agent state volume'
assert_no_source_copy
assert_log_lacks 'pi-agents_pi-agent-state'

# The auth probe stays quiet on a fresh volume without auth.json.
[[ -s $TMP_DIR/auth-probe.sh ]] || fail 'auth probe was never run'
PROBE_STATE=$TMP_DIR/probe-state
mkdir -p "$PROBE_STATE"
probe_status=0
sh -c "$(sed "s#/state#$PROBE_STATE#g" "$TMP_DIR/auth-probe.sh")" 2> "$TMP_DIR/probe.err" || probe_status=$?
[[ $probe_status -eq 42 && ! -s $TMP_DIR/probe.err ]] ||
  fail "auth probe on empty state: status $probe_status, stderr:"$'\n'"$(cat -- "$TMP_DIR/probe.err")"

# --- --new-state ---
NORMAL=$(agent_volume "$WS")
EXTRA=$(extra_volume "$WS")

# --new-state creates the extra volume with its own kind label and always
# recreates the service on it, while sessions and browser state stay on the
# normal volumes.
reset_docker
run_pi "$WS" --new-state
assert_status 0
assert_eq "$(target_volume)" "$EXTRA" 'agent state volume'
assert_log_has 'com.pi-agents.state-kind=agent-extra'
assert_log_has "com.pi-agents.workspace=$WS --label com.pi-agents.project=pi-agents-pi-workspace --label com.pi-agents.state-kind=agent-extra $EXTRA"
assert_log_lacks "$NORMAL"
assert_log_has "sessions=$(session_volume "$WS")"
assert_log_has 'up --detach --force-recreate pi'
assert_log_lacks 'up --build'
assert_eq "$(container_field pi-agents-pi-workspace mount./home/node/.pi/agent)" "$EXTRA" 'container must mount the extra state volume'
assert_eq "$(container_field pi-agents-pi-workspace mount./home/node/.pi/agent/sessions)" "$(session_volume "$WS")" 'sessions stay normal'
volume_has_file "$EXTRA" .container-initialized || fail 'extra state volume must be marked initialized'

# Each start on the extra volume says so and names the untouched normal state;
# the extra volume is never initialized again.
run_pi "$WS" --new-state
assert_status 0
assert_output_has "pi: warning: using the extra state volume $EXTRA; the normal state volume $NORMAL is untouched"
assert_log_lacks 'com.pi-agents.state-kind=agent-extra'
assert_log_lacks 'state-initialization'
assert_no_source_copy
assert_log_has 'up --detach --force-recreate pi'

# Omitting --new-state moves a container mounted on the extra volume back to
# the normal state and warns that the extra volume is unused.
run_pi "$WS"
assert_status 0
assert_eq "$(target_volume)" "$NORMAL" 'agent state volume'
assert_log_has 'up --detach --force-recreate pi'
assert_eq "$(container_field pi-agents-pi-workspace mount./home/node/.pi/agent)" "$NORMAL" 'mounted agent state'
assert_output_has "pi: warning: an extra state volume $EXTRA exists and is not in use; use it with --new-state, or remove it with \`pi remove --all\` (also removes the normal state volumes)"
volume_exists "$EXTRA" || fail 'switching back must keep the extra state volume'

# A container already on the normal volume is reused, still with the warning.
run_pi "$WS"
assert_status 0
assert_log_lacks ' up '
assert_log_lacks 'force-recreate'
assert_output_has "pi: warning: an extra state volume $EXTRA exists and is not in use"

# Disposable runs honour and warn about the extra state volume too.
run_pi "$WS" --rm --new-state
assert_status 0
assert_eq "$(target_volume)" "$EXTRA" 'agent state volume'
assert_output_has "pi: warning: using the extra state volume $EXTRA; the normal state volume $NORMAL is untouched"
run_pi "$WS" --rm
assert_status 0
assert_eq "$(target_volume)" "$NORMAL" 'agent state volume'
assert_output_has "pi: warning: an extra state volume $EXTRA exists and is not in use"

# The extra state volume is not offered by copy.
OTHER_WS=$(make_workspace "$TEST_HOME/projects/other")
INPUT='x'
run_pi "$OTHER_WS" copy --from
INPUT=''
assert_status 3
assert_output_has ") $NORMAL"$'\n'"   workspace: $WS"
assert_output_lacks "$EXTRA"

# Without an extra volume there is no warning.
reset_docker
run_pi "$WS"
run_pi "$WS"
assert_status 0
assert_output_lacks 'extra state volume'

# --- Lineage across workspaces ---
reset_docker
for letter in a b c d e f g h i; do
  declare "WS_${letter^^}=$(make_workspace "$TEST_HOME/lineage/workspace-$letter")"
done

run_pi "$WS_A" - --version
assert_status 0
FIRST=$(target_volume)
assert_eq "$(seed_value)" "$FIRST" 'seed after the first workspace'

run_pi "$WS_B" - --version
assert_status 0
SECOND=$(target_volume)
assert_source "$FIRST"
assert_eq "$(seed_value)" "$FIRST" 'seed after a seeded workspace'

run_pi "$WS_C" --latest-state --version
assert_status 0
THIRD=$(target_volume)
assert_source "$SECOND"
assert_eq "$(seed_value)" "$FIRST" 'seed after --latest-state'

# --latest-state only applies during first initialization.
run_pi "$WS_B" --latest-state --version
assert_status 0
assert_output_has 'pi: warning: --latest-state has no effect; this workspace already has initialized agent state'
assert_no_source_copy

# A rejected --seed --new-state does not move the seed.
run_pi "$WS_D" --seed --new-state --version
assert_fails_with 2 'pi: --new-state and --seed are mutually exclusive; the extra state volume is never a seed'
assert_eq "$(seed_value)" "$FIRST" 'rejected --seed --new-state must not move the seed'

run_pi "$WS_D" --new-state --version
assert_status 0
FOURTH=$(target_volume)
[[ $FOURTH == pi-agents-new-ws-*_pi-agent-state ]] || fail "--new-state target: $FOURTH"
assert_no_source_copy
assert_log_has "--label com.pi-agents.workspace=$WS_D --label com.pi-agents.project=pi-agents-pi-$(workspace_slug "$WS_D") --label com.pi-agents.state-kind=agent-extra"
assert_log_has 'state-initialization complete'
assert_eq "$(seed_value)" "$FIRST" 'seed after --new-state'

# The newest volume is the extra one, but --latest-state skips it.
run_pi "$WS_E" --latest-state --version
assert_status 0
FIFTH=$(target_volume)
assert_source "$THIRD"
assert_log_lacks "$FOURTH:/state-source:ro"

run_pi "$WS_F" --seed --version
assert_status 0
SIXTH=$(target_volume)
assert_source "$FIRST"
assert_eq "$(seed_value)" "$SIXTH" 'seed after --seed'
snapshot lineage

# A pre-marker volume holding auth or model settings is migrated in place, and
# --latest-state has no effect on it.
rm -f -- "$FAKE_DOCKER_STATE/volume-data/$SIXTH/.container-initialized"
fake_volume_file "$SIXTH" auth.json '{"provider":{}}'
run_pi "$WS_F" --latest-state --version
assert_status 0
assert_no_source_copy
assert_output_has '--latest-state has no effect'
assert_log_has 'state-initialization complete'

# Initialized volumes are recognized by their marker alone.
restore lineage
run_pi "$WS_F" - --version
assert_status 0
assert_no_source_copy
assert_log_lacks 'state-initialization'

# An interrupted seed resumes from the source recorded in the pending marker,
# even though the seed pointer now names a different volume.
restore lineage
rm -f -- "$FAKE_DOCKER_STATE/volume-data/$SIXTH/.container-initialized"
fake_volume_file "$SIXTH" .container-initialization-pending "$SECOND"
run_pi "$WS_F" - --version
assert_status 0
assert_source "$SECOND"
assert_log_has "state-initialization pending $SECOND"
assert_log_has 'state-initialization complete'
volume_has_file "$SIXTH" .container-initialized || fail 'resumed initialization must complete'
! volume_has_file "$SIXTH" .container-initialization-pending || fail 'resumed initialization must clear the pending marker'
# State probes run as root so they can read any volume contents.
assert_log_has "docker run --rm --user 0:0 -v $SIXTH:/state:ro pi-agents-pi-workspace-f-pi sh -c [ -d /state ] || exit 43; [ ! -f /state/.container-initialized ]"
assert_log_has "docker run --rm --user 0:0 -v $SIXTH:/state:ro pi-agents-pi-workspace-f-pi cat /state/.container-initialization-pending"

# --latest-state does not change the recorded source.
restore lineage
rm -f -- "$FAKE_DOCKER_STATE/volume-data/$SIXTH/.container-initialized"
fake_volume_file "$SIXTH" .container-initialization-pending "$SECOND"
run_pi "$WS_F" --latest-state --version
assert_status 0
assert_source "$SECOND"
assert_log_lacks "$FIFTH:/state-source:ro"

# A pending seed whose recorded source vanished, or is no longer a managed
# normal state volume, is refused, not restarted.
for pending_source in pi-agents-ws-gone_pi-agent-state "$FOURTH"; do
  restore lineage
  rm -f -- "$FAKE_DOCKER_STATE/volume-data/$SIXTH/.container-initialized"
  fake_volume_file "$SIXTH" .container-initialization-pending "$pending_source"
  run_pi "$WS_F" - --version
  assert_status 2
  assert_output_has "pi: pending agent-state initialization source is unavailable; restore it before retrying: $pending_source"
  assert_no_source_copy
  assert_log_lacks ' up '
done

# A seed pointer naming an extra state volume is treated as missing but kept,
# and the extra volume is not proposed even though it is the oldest.
restore lineage
fake_record "$FAKE_DOCKER_STATE/volumes/$FOURTH" created=2026-01-01T00:00:00Z
snapshot recovery
set_seed "$FOURTH"
INPUT='n\n'
run_pi "$WS_G" - --version
assert_status 2
assert_output_has "$FIRST"
assert_output_lacks "  $FOURTH"
assert_eq "$(seed_value)" "$FOURTH" 'an invalid seed pointer is never deleted as a side effect'
assert_log_lacks ' up '
# The warning comes first, then every managed normal state volume with its
# creation time, then the proposal and the question.
EXPECTED_PROMPT=$'pi: warning: the seed pointer was not found.\nManaged Pi state volumes:'
for file in "$TMP_DIR/snapshot-recovery/volumes"/*; do
  grep -qx 'label.com.pi-agents.state-kind=agent' "$file" || continue
  EXPECTED_PROMPT+=$'\n'"  ${file##*/}  ($(sed -n 's/^created=//p' "$file"))"
done
EXPECTED_PROMPT+=$'\npi: the oldest managed agent-state volume is:\n  '"$FIRST"
EXPECTED_PROMPT+=$'\npi: use it as the seed for this new workspace? [y/N] pi: seed selection cancelled; workspace was not started'
[[ $(cat -- "$OUTPUT_LOG") == *$'\n'"$EXPECTED_PROMPT" ]] ||
  fail "missing-seed prompt"$'\n'"expected:"$'\n'"$EXPECTED_PROMPT"$'\n'"$(show_run)"
assert_log_lacks 'volume create'

# A pointer naming a volume that is gone asks too; declining, or no answer,
# leaves the pointer and starts nothing.
for input in 'n\n' ''; do
  restore recovery
  set_seed pi-agents-ws-gone_pi-agent-state
  INPUT=$input
  run_pi "$WS_G" - --version
  INPUT=''
  assert_status 2
  assert_output_has 'pi: warning: the seed pointer was not found.'
  assert_output_has 'pi: seed selection cancelled; workspace was not started'
  assert_eq "$(seed_value)" pi-agents-ws-gone_pi-agent-state 'declined selection must not rewrite the seed'
  assert_log_lacks 'volume create'
  assert_log_lacks ' up '
done

# --latest-state still confirms a missing seed first; declining copies nothing
# and writes no pointer.
for input in 'n\n' ''; do
  restore recovery
  rm -f -- "$SEED_FILE"
  INPUT=$input
  run_pi "$WS_G" --latest-state --version
  INPUT=''
  assert_status 2
  assert_output_has 'pi: warning: the seed pointer was not found.'
  assert_output_has 'seed selection cancelled; workspace was not started'
  assert_no_source_copy
  [[ ! -e $SEED_FILE ]] || fail 'a declined --latest-state seed must not be written'$'\n'"$(show_run)"
done

# The prompt also accepts yes/YES, and still runs with --latest-state.
for answer in yes YES; do
  restore recovery
  rm -f -- "$SEED_FILE"
  INPUT="$answer\\n"
  run_pi "$WS_G" --latest-state --version
  assert_status 0
  assert_output_has 'seed pointer was not found'
  assert_eq "$(seed_value)" "$FIRST" "seed after answering $answer"
  assert_source "$SIXTH"
done

restore recovery
rm -f -- "$SEED_FILE"
INPUT='y\n'
run_pi "$WS_G" - --version
INPUT=''
assert_status 0
assert_source "$FIRST"
assert_eq "$(seed_value)" "$FIRST" 'seed after answering y'

# The proposed volume is validated again after the answer.
restore recovery
rm -f -- "$SEED_FILE"
INPUT_COMMAND="until grep -Fq '[y/N]' '$OUTPUT_LOG'; do sleep 0.05; done; rm -f -- '$FAKE_DOCKER_STATE/volumes/$FIRST'; printf 'y\\n'"
run_pi "$WS_G" - --version
INPUT_COMMAND=''
assert_status 2
assert_output_has 'pi: selected seed volume is no longer valid'
[[ ! -e $SEED_FILE ]] || fail "an invalidated proposal became the seed: $(seed_value)"
assert_log_lacks ' up '

# Launching an already-initialized workspace while the pointer is missing, or
# names a volume that is gone, never makes it the seed, and the pointer file is
# left as it was so the next new workspace gets the confirmation.
for stale_pointer in '' pi-agents-ws-gone_pi-agent-state; do
  restore lineage
  rm -f -- "$SEED_FILE"
  [[ -z $stale_pointer ]] || set_seed "$stale_pointer"
  run_pi "$WS_F" - --version
  assert_status 0
  assert_eq "$(seed_value)" "$stale_pointer" 'seed pointer after launching an initialized workspace'
  assert_output_lacks 'seed pointer was not found'
done

# --seed still promotes it when the pointer is missing.
restore lineage
rm -f -- "$SEED_FILE"
run_pi "$WS_F" --seed --version
assert_status 0
assert_eq "$(seed_value)" "$SIXTH" 'seed after --seed without a pointer'

# State is created with labels, seeded and repaired before the service starts,
# for both a persistent launch and `pi update`.
for arguments in "$WS_H - --version" "$WS_I update"; do
  restore lineage
  set_seed "$FIRST"
  # shellcheck disable=SC2086
  run_pi $arguments
  assert_status 0
  assert_source "$FIRST"
  assert_log_lacks 'alpine'
  if grep -E '^docker run ' "$DOCKER_LOG" | grep -Fv -- '--user ' | grep -q .; then
    fail 'helper containers must run with an explicit user'$'\n'"$(show_run)"
  fi
  if grep -E '^docker run ' "$DOCKER_LOG" | grep -Ev -- ' pi-agents-pi-workspace-[hi]-pi ' | grep -q .; then
    fail 'helper containers must use the Pi service image'$'\n'"$(show_run)"
  fi
  assert_log_order 'docker volume create' 'docker run '
  assert_log_order "$FIRST:/state-source:ro" ' up '
  assert_log_order 'state-initialization complete' ' up '
  assert_log_order 'chown -R 1000:1000 "$path"' ' up '
  assert_log_order ' up ' 'install npm:pi-agent-browser-native'
done

# Running a workspace on its extra volume never records it as the seed.
reset_docker
run_pi "$WS_G" --new-state --version
assert_status 0
[[ $(target_volume) == pi-agents-new-ws-*_pi-agent-state ]] || fail "--new-state target: $(target_volume)"
[[ -z $(seed_value) ]] || fail "extra volume recorded as the seed: $(seed_value)"

pass
