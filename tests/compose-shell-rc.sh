#!/usr/bin/env bash
# Compose files: the host shell, rc mount, and launcher wiring in the image and services.
# Rendered with read-only `docker compose config`.
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.bash"

grep -Eq '^[[:space:]]+zsh \\$' "$ROOT/Dockerfile" || fail 'Dockerfile must install zsh'
grep -Fqx 'COPY bin/pi-shell-launch /usr/local/bin/pi-shell-launch' "$ROOT/Dockerfile" || fail 'Dockerfile must copy the launcher'
grep -Fq '/usr/local/bin/pi-shell-launch' "$ROOT/Dockerfile" || fail 'Dockerfile must chmod the launcher'

if ! docker compose version >/dev/null 2>&1; then
  printf 'SKIP: %s requires docker compose\n' "$TEST_NAME"
  exit 0
fi
command -v jq >/dev/null 2>&1 || fail 'jq is required'

BASE=$ROOT/compose.yml
OVERRIDE=$ROOT/compose.shell-rc.yml
RC_SOURCE=$TMP_DIR/shellrc
mkdir -p -- "$RC_SOURCE"
: > "$TMP_DIR/empty.env"

# config FILE... : renders the merged configuration as JSON into $TMP_DIR/config,
# isolated from the caller's environment and the repository .env file.
config() {
  local -a files=()
  local file
  for file in "$@"; do files+=(--file "$file"); done
  env -i PATH="$PATH" HOME="$HOME" ${DOCKER_HOST:+DOCKER_HOST="$DOCKER_HOST"} ${DOCKER_CONFIG:+DOCKER_CONFIG="$DOCKER_CONFIG"} \
    ${RC_SOURCE_ENV:+PI_HOST_RC_SOURCE="$RC_SOURCE_ENV"} \
    docker compose --env-file "$TMP_DIR/empty.env" --project-name pi-compose-test --project-directory "$ROOT" \
    "${files[@]}" config --format json > "$TMP_DIR/config" 2> "$TMP_DIR/config.err"
}

rc_mounts() {
  jq -c '[.services.pi.volumes[] | select(.target == "/tmp/pi-host-shellrc")]' "$TMP_DIR/config"
}

# The base file never mounts the rc, but points the container at its path.
RC_SOURCE_ENV='' config "$BASE" || fail "base config must render: $(cat "$TMP_DIR/config.err")"
assert_eq "$(rc_mounts)" '[]' 'base Compose must not mount the generated rc'
assert_eq "$(jq -r '.services.pi.environment.PI_HOST_RC_FILE' "$TMP_DIR/config")" /tmp/pi-host-shellrc/rc 'container rc path'
# Without a selection the container shell is bash with rc loading enabled.
assert_eq "$(jq -r '.services.pi.environment.PI_HOST_SHELL' "$TMP_DIR/config")" bash 'default host shell'
assert_eq "$(jq -r '.services.pi.environment.PI_NO_RC_CONFIG' "$TMP_DIR/config")" 0 'default rc loading'

# The override refuses to render without the generated rc directory.
if RC_SOURCE_ENV='' config "$BASE" "$OVERRIDE"; then fail 'override must require PI_HOST_RC_SOURCE'; fi
assert_file_has "$TMP_DIR/config.err" 'PI_HOST_RC_SOURCE is required when rc loading is enabled'

# With it, the directory is bind-mounted read-only at the expected path.
RC_SOURCE_ENV=$RC_SOURCE config "$BASE" "$OVERRIDE" || fail "override config must render: $(cat "$TMP_DIR/config.err")"
assert_eq "$(rc_mounts | jq -c '[.[] | {type, source, read_only}]')" \
  "$(jq -cn --arg source "$RC_SOURCE" '[{type: "bind", source: $source, read_only: true}]')" 'generated rc mount'

pass
