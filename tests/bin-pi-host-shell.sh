#!/usr/bin/env bash
# Host shell selection, rc generation and mounting, --no-rc-config, and Pi's alias wiring.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.bash"
source "$ROOT/tests/lib/launcher.bash"

WS=$(make_workspace "$TEST_HOME/projects/alpha")
NAME=pi-agents-pi-alpha
AGENT=$(agent_volume "$WS")
RC_SOURCE=$CONFIG_DIR/shell-rc/pi-agents-ws-$(workspace_hash "$WS")
SETTINGS=$FAKE_DOCKER_STATE/volume-data/$AGENT/settings.json
EXEC_PREFIX='docker exec -it'
EXEC_ENV='--env PI_HOST_RC_FILE=/tmp/pi-host-shellrc/rc'

assert_no_docker() {
  [[ ! -s $DOCKER_LOG ]] || fail "docker must not run"$'\n'"$(show_run)"
}

# Pi settings in the workspace's agent state that predate the wrapper's aliases.
existing_settings() {
  fake_volume "$AGENT" "$WS" agent 2026-01-01T00:00:00Z
  fake_volume_file "$AGENT" settings.json "$1"
}

existing_stack() {
  reset_docker
  fake_image "$NAME"
  fake_state "$WS" 2026-01-01T00:00:00Z
  fake_container "$NAME" "$WS" running "$@"
}

# stale_image: the service image and its container lack pi-shell-launch.
stale_image() {
  fake_image "$NAME" stale
  [[ ! -e $FAKE_DOCKER_STATE/containers/$NAME ]] || fake_record "$FAKE_DOCKER_STATE/containers/$NAME" image-id=stale
}

current_image() {
  fake_image "$NAME"
  [[ ! -e $FAKE_DOCKER_STATE/containers/$NAME ]] || fake_record "$FAKE_DOCKER_STATE/containers/$NAME" image-id=current
}

# expect_alias PREFIX RC_FILE TEXT: Pi's shell command prefix expands the host
# ll alias from RC_FILE, printing TEXT, and loads no aliases without rc config.
expect_alias() {
  local output
  output=$(PI_NO_RC_CONFIG=0 PI_HOST_RC_FILE=$2 /bin/bash -c "$1"$'\nll' 2>&1) || true
  [[ $output == *"$3"* ]] || fail "Pi shellCommandPrefix failed to expand the host ll alias:"$'\n'"$output"
  if output=$(PI_NO_RC_CONFIG=1 PI_HOST_RC_FILE=$2 /bin/bash -c "$1"$'\nll' 2>&1); then
    fail 'no-rc command prefix unexpectedly expanded the host alias'
  fi
  [[ $output != *"$3"* ]] || fail 'no-rc command prefix unexpectedly loaded host aliases'
}

printf 'export FROM_PROFILE=yes\nalias ll="printf host-ll"\n' > "$TEST_HOME/.profile"
printf 'source ~/.profile\nexport FROM_ZSHRC=yes\n' > "$TEST_HOME/.zshrc"
printf 'source ~/.profile\nexport FROM_BASH_PROFILE=yes\n' > "$TEST_HOME/.bash_profile"
printf 'export FROM_BASHRC=yes\n' > "$TEST_HOME/.bashrc"

# Default selection follows the basename of SHELL and prepares a stable
# per-workspace rc file; Pi's own shell commands get the host aliases while
# custom settings are kept.
reset_docker
fake_image "$NAME"
existing_settings '{"quietStartup":true,"shellCommandPrefix":"printf custom-prefix"}'
EXTRA_ENV=(SHELL=/usr/local/bin/zsh)
run_pi "$WS" --version
assert_status 0
rc_dirs=("$CONFIG_DIR"/shell-rc/*)
[[ ${#rc_dirs[@]} -eq 1 && ${rc_dirs[0]} == "$RC_SOURCE" && -f $RC_SOURCE/rc ]] || fail "expected one rc directory: ${rc_dirs[*]}"
assert_file_has "$RC_SOURCE/rc" 'export FROM_PROFILE=yes'
assert_file_has "$RC_SOURCE/rc" 'export FROM_ZSHRC=yes'
SHELL_COMMAND_PREFIX=$(jq -r '.shellCommandPrefix' "$SETTINGS")
[[ $SHELL_COMMAND_PREFIX == *'printf custom-prefix'* ]] || fail 'custom shellCommandPrefix was lost'
[[ $SHELL_COMMAND_PREFIX == *'shopt -s expand_aliases'* ]] || fail 'alias expansion is not enabled'
[[ $SHELL_COMMAND_PREFIX == *'pi-agents managed host shell aliases'* ]] || fail 'managed alias marker is missing'
assert_log_has 'grep -E'
expect_alias "$SHELL_COMMAND_PREFIX" "$RC_SOURCE/rc" host-ll
assert_eq "$(jq -r '.shellCommandPrefix' "$SETTINGS" | grep -Fc 'pi-agents managed host shell aliases')" 1 'managed alias blocks'
assert_log_has "shell=zsh rc-source=$RC_SOURCE rc-file=/tmp/pi-host-shellrc/rc no-rc=0"
assert_log_has 'compose.shell-rc.yml'
assert_log_has 'up --detach pi'
assert_log_lacks '--build'
assert_eq "$(container_field "$NAME" mount./tmp/pi-host-shellrc)" "$RC_SOURCE" 'rc mount source'
assert_log_has 'exec pi pi-shell-launch pi-session-log --forward-output install npm:pi-agent-browser-native'
assert_log_has 'exec pi pi-shell-launch pi-session-log --version'

# A stale image is reported without an implicit rebuild.
stale_image
run_pi "$WS" --version
assert_status 2
assert_output_has 'image lacks pi-shell-launch'
assert_output_has 'pi update'
assert_log_lacks 'up --build'
assert_log_lacks 'install npm:pi-agent-browser-native'
current_image

# Explicit overrides win over SHELL and rewrite the same rc source file, so an
# already-running container's read-only mount sees the selected shell's config.
EXTRA_ENV=(SHELL=/bin/zsh)
run_pi "$WS" --bash --version
assert_status 0
rc_dirs=("$CONFIG_DIR"/shell-rc/*)
[[ ${#rc_dirs[@]} -eq 1 && ${rc_dirs[0]} == "$RC_SOURCE" ]] || fail "expected the same rc directory: ${rc_dirs[*]}"
assert_file_has "$RC_SOURCE/rc" 'export FROM_BASH_PROFILE=yes'
assert_file_has "$RC_SOURCE/rc" 'export FROM_BASHRC=yes'
assert_file_has "$RC_SOURCE/rc" 'alias ll="printf host-ll"'
expect_alias "$SHELL_COMMAND_PREFIX" "$RC_SOURCE/rc" host-ll
assert_log_has "shell=bash rc-source=$RC_SOURCE rc-file="

EXTRA_ENV=(SHELL=/bin/bash)
run_pi "$WS" --zsh --version
assert_status 0
assert_log_has 'shell=zsh rc-source='

# --rebuild builds the service image once; Compose then recreates from it.
run_pi "$WS" --rebuild --version
assert_status 0
assert_log_has ' build pi'
assert_log_has 'up --detach pi'
assert_log_lacks 'up --build'
assert_log_lacks '--no-cache'
assert_log_lacks ' --pull '

# Repeated launches keep a single managed alias block.
assert_eq "$(jq -r '.shellCommandPrefix' "$SETTINGS" | grep -Fc 'pi-agents managed host shell aliases')" 1 'managed alias blocks'

# No-rc mode selects the shell without generating or mounting an rc file.
reset_docker
fake_image "$NAME"
EXTRA_ENV=(SHELL=/bin/zsh)
run_pi "$WS" --no-rc-config --version
assert_status 0
[[ ! -e $CONFIG_DIR/shell-rc ]] || fail 'no-rc mode generated an rc file'
assert_log_has 'shell=zsh rc-source= rc-file=/tmp/pi-host-shellrc/rc no-rc=1'
assert_log_lacks 'compose.shell-rc.yml'
assert_log_has 'exec pi pi-shell-launch pi-session-log --version'
assert_log_lacks 'exec -T pi sh -c'
EXTRA_ENV=()

# Disposable Pi and extension installation both use the shell launcher, and
# the one-off configures host aliases in the agent state.
RM_HOME=$TMP_DIR/rm-home
mkdir -p "$RM_HOME"
printf 'alias ll="printf rm-host-ll"\n' > "$RM_HOME/.profile"
printf 'source ~/.profile\n' > "$RM_HOME/.bash_profile"
reset_docker
fake_image "$NAME"
existing_settings '{"shellCommandPrefix":"printf rm-custom-prefix"}'
EXTRA_ENV=(HOME="$RM_HOME")
run_pi "$WS" --rm --version
assert_status 0
assert_log_has 'run --rm --entrypoint /bin/sh pi -c'
assert_log_has 'pi-agents managed host shell aliases'
assert_log_has '[ ! -x /usr/local/bin/pi-shell-launch ]'
assert_log_has 'run pi update or use --rebuild'
assert_log_has 'run --rm --service-ports pi pi-shell-launch pi --version'
assert_log_lacks 'run --build'
assert_eq "$(grep -Ec '^docker compose .* run --' "$DOCKER_LOG" || true)" 2 'compose run count'
RM_PREFIX=$(jq -r '.shellCommandPrefix' "$SETTINGS")
[[ $RM_PREFIX == *'rm-custom-prefix'* ]] || fail 'custom shellCommandPrefix was lost by the one-off'
expect_alias "$RM_PREFIX" "$RC_SOURCE/rc" rm-host-ll

stale_image
run_pi "$WS" --rm --version
assert_status 2
assert_output_has 'image lacks pi-shell-launch'
assert_output_has 'pi update'
assert_log_lacks 'run --build'
assert_log_lacks 'build pi'

run_pi "$WS" --rebuild --rm --version
assert_status 0
assert_log_has 'build pi'
assert_log_has 'run --rm --service-ports pi pi-shell-launch pi --version'
assert_log_lacks 'run --build'
assert_log_lacks '--no-cache'
assert_eq "$(grep -Ec '^docker compose .* run --' "$DOCKER_LOG" || true)" 2 'compose run count'
EXTRA_ENV=()

# Existing-container shell attachment uses the launcher and keeps the selected
# shell and rc settings in its environment.
existing_stack
EXTRA_ENV=(SHELL=/bin/zsh)
run_pi "$WS" shell
assert_status 0
assert_log_has "$EXEC_PREFIX --env PI_HOST_SHELL=zsh $EXEC_ENV --env PI_NO_RC_CONFIG=0 $NAME pi-shell-launch"

run_pi "$WS" --rebuild shell
assert_status 0
assert_log_has ' build pi'
assert_log_has 'up --detach --force-recreate pi'
assert_log_has "$EXEC_PREFIX --env PI_HOST_SHELL=zsh $EXEC_ENV --env PI_NO_RC_CONFIG=0 $NAME pi-shell-launch"

# A running current stack that already mounts the rc is attached as is: a stack
# started with --oauth keeps its published ports and attached Pi sessions.
existing_stack
printf 'port=%s\n' 127.0.0.1:1455:1455/tcp ::1:1455:1455/tcp >> "$FAKE_DOCKER_STATE/containers/$NAME"
run_pi "$WS" shell
assert_status 0
assert_log_lacks ' up '
assert_eq "$(container_field "$NAME" port | LC_ALL=C sort)" $'127.0.0.1:1455:1455/tcp\n::1:1455:1455/tcp' 'published OAuth ports'
assert_eq "$(container_field "$NAME" created)" 2026-01-01T00:00:00Z 'container must not be recreated'
assert_log_has "$EXEC_PREFIX --env PI_HOST_SHELL=zsh $EXEC_ENV --env PI_NO_RC_CONFIG=0 $NAME pi-shell-launch"

# Normal shell attachment reconciles a current container previously created
# with --no-rc-config before trying to source the generated rc.
existing_stack -mount./tmp/pi-host-shellrc
run_pi "$WS" shell
assert_status 0
assert_log_has 'compose.shell-rc.yml'
assert_log_has 'up --detach pi'
assert_eq "$(container_field "$NAME" mount./tmp/pi-host-shellrc)" "$RC_SOURCE" 'reconciled rc mount source'
assert_log_has "$EXEC_PREFIX --env PI_HOST_SHELL=zsh $EXEC_ENV --env PI_NO_RC_CONFIG=0 $NAME pi-shell-launch"

# Explicit rebuilding recreates the current workspace stack before attaching.
run_pi "$WS" --rebuild shell
assert_status 0
assert_log_has ' build pi'
assert_log_has 'up --detach --force-recreate pi'
assert_log_has "$EXEC_PREFIX --env PI_HOST_SHELL=zsh $EXEC_ENV --env PI_NO_RC_CONFIG=0 $NAME pi-shell-launch"

run_pi "$WS" shell --root
assert_status 0
assert_log_has "$EXEC_PREFIX --user 0 --env PI_HOST_SHELL=zsh $EXEC_ENV --env PI_NO_RC_CONFIG=0 $NAME pi-shell-launch"

EXTRA_ENV=(SHELL=/bin/bash)
run_pi "$WS" --no-rc-config shell
assert_status 0
assert_log_has "$EXEC_PREFIX --env PI_HOST_SHELL=bash $EXEC_ENV --env PI_NO_RC_CONFIG=1 $NAME pi-shell-launch"
EXTRA_ENV=()

# Invalid selection fails before any Docker command.
run_pi "$WS" --bash --zsh --version
assert_status 2
assert_no_docker
assert_output_has '--bash and --zsh are mutually exclusive'

EXTRA_ENV=(SHELL=/usr/bin/fish)
run_pi "$WS" --version
assert_status 2
assert_no_docker
assert_output_has 'unsupported host shell: fish'

# Commands that never start a host-shell session ignore an unsupported SHELL.
for command in list stop remove copy; do
  run_pi "$WS" "$command"
  assert_output_lacks 'unsupported host shell'
  [[ -s $DOCKER_LOG ]] || fail "pi $command with SHELL=fish did not reach Docker"$'\n'"$(show_run)"
done
EXTRA_ENV=()

# Read-only inventory does not generate startup configuration.
reset_docker
EXTRA_ENV=(SHELL=/bin/zsh)
run_pi "$WS" list
assert_status 0
[[ ! -e $CONFIG_DIR/shell-rc ]] || fail 'list generated an rc file'
EXTRA_ENV=()

pass
