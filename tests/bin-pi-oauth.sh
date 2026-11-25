#!/usr/bin/env bash
# --oauth port parsing, availability, binding reuse, and override contents.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.bash"
source "$ROOT/tests/lib/launcher.bash"

WS=$(make_workspace "$TEST_HOME/projects/alpha")
NAME=pi-agents-pi-alpha
FILES="-f $ROOT/compose.yml -f $ROOT/compose.oauth.yml"
KNOWN_BINDINGS=$'127.0.0.1:1455:1455/tcp\n::1:1455:1455/tcp\n127.0.0.1:53692:53692/tcp\n::1:53692:53692/tcp\n127.0.0.1:51121:51121/tcp\n::1:51121:51121/tcp'

# existing_stack [BINDING...]: this workspace's initialized running stack,
# publishing exactly BINDINGS (HostIp:HostPort:port/tcp).
existing_stack() {
  local binding
  reset_docker
  fake_image "$NAME"
  fake_state "$WS" 2026-01-01T00:00:00Z
  fake_container "$NAME" "$WS" running
  for binding in "$@"; do printf 'port=%s\n' "$binding" >> "$FAKE_DOCKER_STATE/containers/$NAME"; done
}

# expect_ports PORT...: the service publishes exactly the known callbacks and
# PORTS on IPv4 and IPv6 loopback.
expect_ports() {
  local port expected=$KNOWN_BINDINGS$'\n'
  for port in "$@"; do expected+="127.0.0.1:$port:$port/tcp"$'\n'"::1:$port:$port/tcp"$'\n'; done
  assert_eq "$(container_field "$NAME" port | LC_ALL=C sort)" "$(printf '%s' "$expected" | LC_ALL=C sort)" 'published OAuth ports'
}

# assert_override_ports PORTS...: the override publishes exactly these ports on
# IPv4 and IPv6 loopback, in order.
assert_override_ports() {
  local expected=$'services:\n  pi:\n    ports:' port actual
  for port in "$@"; do
    expected+=$'\n'"      - \"127.0.0.1:$port:$port\""
    expected+=$'\n'"      - \"[::1]:$port:$port\""
  done
  actual=$(sed -n 's/^compose-override-content //p' "$DOCKER_LOG" | awk '!seen[$0]++')
  assert_eq "$actual" "$expected" 'override contents'
  assert_log_lacks 'pi-oauth.XXXXXX'
  expect_ports "$@"
}

assert_no_override() {
  assert_log_lacks 'compose-override '
}

assert_override_removed() {
  [[ -z $(find "$TMP_DIR/tmp" -name 'pi-oauth.*') ]] || fail 'temporary OAuth override was not removed after exit'
}

# expect_invalid MESSAGE ARGS...: status 2 and no Docker call.
expect_invalid() {
  local message=$1
  shift
  run_pi "$WS" "$@"
  assert_status 2
  assert_output_has "$message"
  [[ ! -s $DOCKER_LOG ]] || fail 'invalid ports must fail before Docker'$'\n'"$(show_run)"
}

# The known callbacks need no override and are published through the static
# compose.oauth.yml, for the persistent service and Pi's own command. A stack
# without them is recreated to publish them.
existing_stack
run_pi "$WS" --oauth --version
assert_status 0
assert_log_has "-f $ROOT/compose.oauth.yml -f $ROOT/compose.shell-rc.yml up --detach --force-recreate pi"
assert_log_has "--env PI_HOST_RC_FILE=/tmp/pi-host-shellrc/rc $NAME pi-shell-launch pi-session-log --version"
assert_no_override
assert_override_removed
expect_ports

# A stack that publishes exactly this launch's callbacks is reused as-is.
run_pi "$WS" --oauth --version
assert_status 0
assert_log_lacks ' up '
expect_ports

# A launch without --oauth recreates a stack that still publishes callback
# ports, so they are free again; a stack without them is reused.
run_pi "$WS" --version
assert_status 0
assert_log_has ' up --detach --force-recreate pi'
assert_log_lacks 'compose.oauth.yml'
assert_eq "$(container_field "$NAME" port)" '' 'published ports after a launch without --oauth'
run_pi "$WS" --version
assert_status 0
assert_log_lacks ' up '

# Custom ports get an override that publishes each on IPv4 and IPv6 loopback,
# removed after the wrapper exits.
run_pi "$WS" --oauth 7000,7001
assert_status 0
assert_override_ports 7000 7001
assert_override_removed

# Space-separated lists, trailing commas, --oauth=, and known ports in the list.
run_pi "$WS" --oauth 7002 7003, 1455
assert_status 0
assert_override_ports 7002 7003
run_pi "$WS" --oauth 7002,7003 7004 --version
assert_status 0
assert_override_ports 7002 7003 7004
assert_log_has 'pi-session-log --version'
run_pi "$WS" --oauth=7004,7005
assert_status 0
assert_override_ports 7004 7005
run_pi "$WS" --oauth=7006,
assert_status 0
assert_override_ports 7006
run_pi "$WS" --oauth=
assert_status 0
assert_log_has '/compose.oauth.yml'
assert_no_override
expect_ports

# PI_OAUTH_CALLBACK_PORTS adds comma- or space-separated ports to the CLI list.
EXTRA_ENV=(PI_OAUTH_CALLBACK_PORTS='7010, 7011 7012')
run_pi "$WS" --oauth 7013
assert_status 0
assert_override_ports 7013 7010 7011 7012
assert_override_removed
EXTRA_ENV=(PI_OAUTH_CALLBACK_PORTS='7000,7001')
run_pi "$WS" --oauth --version
assert_status 0
assert_override_ports 7000 7001
EXTRA_ENV=(PI_OAUTH_CALLBACK_PORTS='7005 7006')
run_pi "$WS" --oauth --version
assert_status 0
assert_override_ports 7005 7006
EXTRA_ENV=()

# Invalid ports fail before Docker; the environment list is ignored without --oauth.
expect_invalid 'pi: invalid OAuth callback port list: 1,,2' --oauth=1,,2
expect_invalid 'pi: invalid OAuth callback port list: x' --oauth=x
expect_invalid 'pi: OAuth callback port must be between 1 and 65535 in --oauth: 0' --oauth 0
expect_invalid 'pi: OAuth callback port must be between 1 and 65535 in --oauth: 70000' --oauth 70000 --version
EXTRA_ENV=(PI_OAUTH_CALLBACK_PORTS=abc)
expect_invalid 'PI_OAUTH_CALLBACK_PORTS' --oauth
existing_stack
run_pi "$WS"
assert_status 0
assert_log_lacks 'compose.oauth.yml'
assert_log_lacks ' up '
EXTRA_ENV=()

# Ports this workspace's running stack already publishes are reused although
# they appear busy on the host.
mapfile -t known_bindings <<< "$KNOWN_BINDINGS"
existing_stack "${known_bindings[@]}"
EXTRA_ENV=(FAKE_BUSY_PORTS='1455 53692 51121')
run_pi "$WS" --oauth
assert_status 0
assert_log_lacks ' up '
assert_output_lacks 'already in use'

# A port that anything else listens on is refused before anything starts.
EXTRA_ENV=(FAKE_BUSY_PORTS='1455 53692 51121 7000')
run_pi "$WS" --oauth 7000
assert_status 2
assert_output_has 'pi: OAuth callback port is already in use: 7000'
assert_log_lacks ' up '

# A disposable --rm run cannot share the stack's ports.
EXTRA_ENV=(FAKE_BUSY_PORTS='1455 53692 51121')
run_pi "$WS" --rm --oauth
assert_status 2
assert_output_has 'pi: OAuth callback port is already in use: 1455'
assert_log_lacks 'run --rm --service-ports'
EXTRA_ENV=()

# A port this stack publishes on only one loopback address is still its own
# and is reused, even though it appears busy on the host.
for binding in '127.0.0.1:7000:7000/tcp' '::1:7000:7000/tcp'; do
  existing_stack "$binding"
  EXTRA_ENV=(FAKE_BUSY_PORTS='7000')
  run_pi "$WS" --oauth 7000
  EXTRA_ENV=()
  assert_status 0
  assert_output_lacks 'already in use'
  assert_log_has 'up --detach --force-recreate pi'
  assert_override_ports 7000
done

# A disposable --rm run cannot reuse the stack's custom port.
existing_stack '127.0.0.1:7000:7000/tcp'
EXTRA_ENV=(FAKE_BUSY_PORTS='7000')
run_pi "$WS" --rm --oauth 7000
EXTRA_ENV=()
assert_status 2
assert_output_has 'pi: OAuth callback port is already in use: 7000'
assert_log_lacks 'run --rm'
assert_override_removed

pass
