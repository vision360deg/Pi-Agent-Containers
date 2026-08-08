#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

if grep -Fq '127.0.0.1:1455:1455' "$ROOT/compose.yml" ||
  grep -Fq '[::1]:1455:1455' "$ROOT/compose.yml"; then
  printf 'base Compose file must not publish the OAuth callback port\n' >&2
  exit 1
fi

grep -Fqx '      - "127.0.0.1:1455:1455"' "$ROOT/compose.oauth.yml"
grep -Fqx '      - "[::1]:1455:1455"' "$ROOT/compose.oauth.yml"
grep -Fqx '      - "127.0.0.1:53692:53692"' "$ROOT/compose.oauth.yml"
grep -Fqx '      - "[::1]:53692:53692"' "$ROOT/compose.oauth.yml"
grep -Fqx '      - "127.0.0.1:51121:51121"' "$ROOT/compose.oauth.yml"
grep -Fqx '      - "[::1]:51121:51121"' "$ROOT/compose.oauth.yml"

if ! docker compose --project-name pi-agents-pi-example --project-directory "$ROOT" \
  --file "$ROOT/compose.yml" config | grep -Fqx '      - pi-session-forwarder & exec sleep infinity'; then
  printf 'persistent service must start the session forwarder beside sleep infinity\n' >&2
  exit 1
fi

if docker compose --project-name pi-agents-pi-example --project-directory "$ROOT" \
  --file "$ROOT/compose.yml" config | grep -Fq 'tty: true'; then
  printf 'persistent service must not allocate a TTY for Docker log forwarding\n' >&2
  exit 1
fi

docker compose --project-name pi-agents-pi-example --project-directory "$ROOT" \
  --file "$ROOT/compose.yml" config | grep -Fqx '      PI_SESSION_LOG_FORMAT: pretty'
docker compose --project-name pi-agents-pi-example --project-directory "$ROOT" \
  --file "$ROOT/compose.yml" config | grep -Fqx '      PI_SESSION_LOG_COLOR: always'

if ! PI_WORKSPACE_PROJECT=pi-agents-pi-example \
  docker compose --project-name pi-agents-pi-example --project-directory "$ROOT" \
  --file "$ROOT/compose.yml" config | grep -Fqx '    name: pi-agents-pi-example'; then
  printf 'Compose network must follow the resolved project name\n' >&2
  exit 1
fi

if ! PI_WORKSPACE=/tmp/example \
  PI_WORKSPACE_PROJECT=pi-agents-pi-example \
  PI_AGENT_STATE_VOLUME_NAME=pi-agents-ws-example_pi-agent-state \
  PI_SESSION_STATE_VOLUME_NAME=pi-agents-ws-example_pi-sessions \
  PI_BROWSER_STATE_VOLUME_NAME=pi-agents-ws-example_agent-browser-state \
  docker compose --project-name pi-agents-pi-example --project-directory "$ROOT" \
  --file "$ROOT/compose.yml" config | grep -Fq '    external: true'; then
  printf 'persisted volumes must be external to Compose\n' >&2
  exit 1
fi

printf 'Compose OAuth override tests passed\n'
