#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

grep -Eq '^[[:space:]]+zsh \\$' "$ROOT/Dockerfile" || fail 'Dockerfile must install zsh'
grep -Fqx 'COPY bin/pi-shell-launch /usr/local/bin/pi-shell-launch' "$ROOT/Dockerfile" || fail 'Dockerfile must copy the launcher'
grep -Fq '/usr/local/bin/pi-shell-launch' "$ROOT/Dockerfile" || fail 'Dockerfile must chmod the launcher'

grep -Fqx '      PI_HOST_SHELL: ${PI_HOST_SHELL:-bash}' "$ROOT/compose.yml" || fail 'Compose must expose PI_HOST_SHELL'
grep -Fqx '      PI_HOST_RC_FILE: ${PI_HOST_RC_FILE:-/tmp/pi-host-shellrc/rc}' "$ROOT/compose.yml" || fail 'Compose must expose PI_HOST_RC_FILE'
grep -Fqx '      PI_NO_RC_CONFIG: ${PI_NO_RC_CONFIG:-0}' "$ROOT/compose.yml" || fail 'Compose must expose PI_NO_RC_CONFIG'
if grep -Fq 'PI_HOST_RC_SOURCE' "$ROOT/compose.yml"; then fail 'base Compose must not mount the generated rc'; fi
grep -Fqx '      - ${PI_HOST_RC_SOURCE:?PI_HOST_RC_SOURCE is required when rc loading is enabled}:/tmp/pi-host-shellrc:ro' "$ROOT/compose.shell-rc.yml" || fail 'rc Compose override must mount the generated rc read-only'
grep -Fqx '    command: ["bash", "-lc", "pi-session-forwarder & exec sleep infinity"]' "$ROOT/compose.yml" || fail 'persistent service command changed'

printf 'compose shell tests passed\n'
