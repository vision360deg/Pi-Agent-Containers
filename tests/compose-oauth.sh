#!/usr/bin/env bash
# Compose files: the static OAuth callback override and the state-copy helper in the image.
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.bash"

grep -Fq 'COPY bin/pi-state-copy /usr/local/bin/pi-state-copy' "$ROOT/Dockerfile"
grep -Fq '/usr/local/bin/pi-state-copy' "$ROOT/Dockerfile"

if grep -Fq '127.0.0.1:1455:1455' "$ROOT/compose.yml" ||
  grep -Fq '[::1]:1455:1455' "$ROOT/compose.yml"; then
  fail 'base Compose file must not publish the OAuth callback port'
fi

grep -Fqx '      - "127.0.0.1:1455:1455"' "$ROOT/compose.oauth.yml"
grep -Fqx '      - "[::1]:1455:1455"' "$ROOT/compose.oauth.yml"
grep -Fqx '      - "127.0.0.1:53692:53692"' "$ROOT/compose.oauth.yml"
grep -Fqx '      - "[::1]:53692:53692"' "$ROOT/compose.oauth.yml"
grep -Fqx '      - "127.0.0.1:51121:51121"' "$ROOT/compose.oauth.yml"
grep -Fqx '      - "[::1]:51121:51121"' "$ROOT/compose.oauth.yml"

if docker compose --project-name pi-agents-pi-example --project-directory "$ROOT" \
  --file "$ROOT/compose.yml" config | grep -Fq 'tty: true'; then
  fail 'persistent service must not allocate a TTY for Docker log forwarding'
fi

docker compose --project-name pi-agents-pi-example --project-directory "$ROOT" \
  --file "$ROOT/compose.yml" config | grep -Fqx '      PI_SESSION_LOG_FORMAT: pretty'
docker compose --project-name pi-agents-pi-example --project-directory "$ROOT" \
  --file "$ROOT/compose.yml" config | grep -Fqx '      PI_SESSION_LOG_COLOR: always'

if ! PI_WORKSPACE_PROJECT=pi-agents-pi-example \
  docker compose --project-name pi-agents-pi-example --project-directory "$ROOT" \
  --file "$ROOT/compose.yml" config | grep -Fqx '    name: pi-agents-pi-example'; then
  fail 'Compose network must follow the resolved project name'
fi

if ! PI_WORKSPACE=/tmp/example \
  PI_WORKSPACE_PROJECT=pi-agents-pi-example \
  PI_AGENT_STATE_VOLUME_NAME=pi-agents-ws-example_pi-agent-state \
  PI_SESSION_STATE_VOLUME_NAME=pi-agents-ws-example_pi-sessions \
  PI_BROWSER_STATE_VOLUME_NAME=pi-agents-ws-example_agent-browser-state \
  docker compose --project-name pi-agents-pi-example --project-directory "$ROOT" \
  --file "$ROOT/compose.yml" config | grep -Fq '    external: true'; then
  fail 'persisted volumes must be external to Compose'
fi

pass
