#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

grep -Eq '^[[:space:]]+zsh \\$' "$ROOT/Dockerfile" || fail 'Dockerfile must install zsh'
grep -Fqx 'COPY bin/pi-shell-launch /usr/local/bin/pi-shell-launch' "$ROOT/Dockerfile" || fail 'Dockerfile must copy the launcher'
grep -Fq '/usr/local/bin/pi-shell-launch' "$ROOT/Dockerfile" || fail 'Dockerfile must chmod the launcher'

grep -Fqx '      PI_HOST_SHELL: ${PI_HOST_SHELL:-bash}' "$ROOT/compose.yml" || fail 'Compose must expose PI_HOST_SHELL'
grep -Fqx '      PI_HOST_RC_FILE: ${PI_HOST_RC_FILE:-/tmp/pi-host-shellrc}' "$ROOT/compose.yml" || fail 'Compose must expose PI_HOST_RC_FILE'
grep -Fqx '      - ${PI_HOST_RC_SOURCE:-/dev/null}:/tmp/pi-host-shellrc:ro' "$ROOT/compose.yml" || fail 'Compose must mount the generated rc read-only'
grep -Fqx '    command: ["bash", "-lc", "pi-session-forwarder & exec sleep infinity"]' "$ROOT/compose.yml" || fail 'persistent service command changed'

printf 'compose shell tests passed\n'
