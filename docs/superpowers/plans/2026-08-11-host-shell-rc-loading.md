# Host Shell RC Loading Implementation Plan

> For agentic workers: REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Make pi and pi shell use the host-selected or explicitly forced Bash/zsh configuration by recursively resolving all relevant startup files into one read-only generated file, while supporting a no-rc-config mode.

**Architecture:** A host-side bin/pi-shell-rc Bash utility statically resolves Bash's .bash_profile/.bashrc or zsh's .zshenv/.zprofile/.zshrc/.zlogin source chains without executing host shell code and writes an atomic generated rc file. A container-side bin/pi-shell-launch helper, copied into the existing image, starts Bash or zsh with that file loaded—or with all rc loading disabled—and safely execs either Pi or an interactive prompt. bin/pi parses --bash, --zsh, and --no-rc-config, prepares the generated file when enabled, passes shell/rc mode through Compose, and routes foreground Pi/shell entry points through the helper; the persistent service command remains Bash.

**Tech Stack:** Bash, Dockerfile/Compose, Docker bind mounts, repository shell integration tests.

## Global Constraints

- Support only host shell basenames bash and zsh; reject other shells before starting Docker.
- --bash and --zsh force the shell and are mutually exclusive; absent either flag, use the basename of $SHELL.
- Bash resolves ~/.bash_profile and ~/.bashrc, deduplicating files reached through source references.
- zsh resolves ~/.zshenv, ~/.zprofile, ~/.zshrc, and ~/.zlogin in that order, deduplicating files reached through source references.
- --no-rc-config disables host rc resolution, generated-file creation, the rc bind mount, and shell startup-file loading.
- Resolve source files statically; never evaluate host startup-file code.
- Follow only literal home-relative source targets (~, $HOME, \${HOME}, or literal paths under the selected host home); preserve unsupported/dynamic source lines and warn.
- Keep compose.yml's bash -lc 'pi-session-forwarder & exec sleep infinity' service command unchanged.
- Mount only a per-workspace directory containing the generated rc file read-only; do not mount the host home directory. The directory mount keeps atomic rc refreshes visible to existing containers.
- Update both detailed help and combined-argument brief help when changing bin/pi.
- Preserve existing workspace/container lifecycle and agent-state lineage behavior and tests.

---

### Task 1: Add the host-side rc-chain resolver

**Files:**
- Create: bin/pi-shell-rc
- Test: tests/pi-shell-rc.sh

**Interface:** bin/pi-shell-rc --shell bash|zsh --home HOST_HOME --output GENERATED_RC writes an atomically-generated rc file. It returns status 2 for invalid arguments or unsupported shells and warns about unresolved/cyclic sources. It resolves every statically identifiable source or . directive in each startup root recursively.

- [ ] Step 1: Write the failing resolver tests.

Create a temporary host home containing:

~~~bash
cat > "$HOME_ROOT/.bash_profile" <<'EOF'
export FROM_PROFILE=1
source "$HOME/.bashrc"
EOF
cat > "$HOME_ROOT/.bashrc" <<'EOF'
export FROM_BASHRC=1
. ~/.aliases
EOF
cat > "$HOME_ROOT/.aliases" <<'EOF'
alias ll='ls -la'
EOF
~~~

Run bin/pi-shell-rc --shell bash --home "$HOME_ROOT" --output "$OUTPUT" and assert the output contains FROM_PROFILE, FROM_BASHRC, and alias ll in that order. Add a zsh case with .zshenv, .zprofile, .zshrc, and .zlogin each contributing a marker, plus a nested source from each chain. Assert all markers occur in startup order and referenced files are included once. Add cases for a missing startup root, a source cycle (included once and warned), and a dynamic source such as . "$HOME/\${RC_NAME}" (preserved verbatim and warned).

Run:

~~~bash
bash tests/pi-shell-rc.sh
~~~

Expected: FAIL because bin/pi-shell-rc does not exist.

- [ ] Step 2: Implement the minimal static resolver.

Implement bin/pi-shell-rc with these rules:

~~~bash
case "$shell" in
  bash) roots=("$home/.bash_profile" "$home/.bashrc") ;;
  zsh)  roots=("$home/.zshenv" "$home/.zprofile" "$home/.zshrc" "$home/.zlogin") ;;
  *) printf 'pi-shell-rc: unsupported shell: %s\n' "$shell" >&2; exit 2 ;;
esac
~~~

Use associative visited and active maps. For each readable root, recursively copy lines to a temporary output. Recognize source and . directives with one literal or quoted target, including common conditional-prefix forms only when the source target can be resolved without evaluating shell code; preserve and warn on dynamic or semantically unsafe forms. Expand ~, ~/..., $HOME/..., \${HOME}/..., and absolute paths lexically under home; reject paths outside home, dynamic expansions, extra command arguments, and command substitutions. For a resolvable readable target, recurse in place and omit the original source line. For a repeated target, omit it; for an active target, warn and omit it. For unresolved targets, retain the original line and warn. Use umask 077, create the parent directory, write to output.$$ and mv it into place. Set mode 0644 so UID 1000 in the container can read it.

- [ ] Step 3: Run bash tests/pi-shell-rc.sh and expect a passing result.

- [ ] Step 4: Commit the resolver.

~~~bash
git add bin/pi-shell-rc tests/pi-shell-rc.sh
git commit -m "feat: resolve host shell rc chains"
~~~

### Task 2: Add the in-image shell launcher and read-only rc mount

**Files:**
- Create: bin/pi-shell-launch
- Modify: Dockerfile
- Modify: compose.yml
- Test: tests/pi-shell-launch.sh
- Test: tests/compose-shell.sh

**Interface:** bin/pi-shell-launch consumes PI_HOST_SHELL (bash or zsh), PI_HOST_RC_FILE (normally /tmp/pi-host-shellrc), PI_NO_RC_CONFIG (0 or 1), and zero or more command arguments. With no arguments it opens an interactive selected shell; with arguments it loads the selected rc file—or disables all rc loading when PI_NO_RC_CONFIG=1—and safely execs the supplied command and arguments.

- [ ] Step 1: Write failing launcher and image/Compose tests.

Create fake bash and zsh executables that log their arguments. Assert that PI_HOST_SHELL=zsh with a command invokes zsh with interactive command execution, while zero arguments invoke an interactive zsh prompt. Add the analogous Bash assertion and a PI_NO_RC_CONFIG=1 case that passes zsh -f or Bash --noprofile --norc without the rc file. Add static checks that Dockerfile installs zsh, copies and chmods bin/pi-shell-launch, and compose.yml mounts the rc source to /tmp/pi-host-shellrc:ro and exposes the shell/rc environment without changing the service command.

Run:

~~~bash
bash tests/pi-shell-launch.sh
bash tests/compose-shell.sh
~~~

Expected: FAIL because the launcher, Dockerfile entries, and Compose mount do not exist.

- [ ] Step 2: Implement the launcher and image wiring.

Implement bin/pi-shell-launch as a Bash wrapper. When PI_NO_RC_CONFIG=1, use Bash --noprofile --norc -i or zsh -f -i, with the same command/no-command behavior. Otherwise, for Bash use bash -i --rcfile "$PI_HOST_RC_FILE" -c 'exec "$@"' pi-shell-launch "$@" for commands and bash -i --rcfile "$PI_HOST_RC_FILE" with no arguments. For zsh create a per-process directory under /tmp, symlink the mounted file to .zshrc, set ZDOTDIR to that directory, and use zsh -i -c 'exec "$@"' pi-shell-launch "$@" or zsh -i with no arguments. Reject unsupported PI_HOST_SHELL values with status 2. Use argument arrays/quoted positional parameters; never interpolate command arguments into a shell string.

Add zsh to the existing apt-get install list, copy the launcher to /usr/local/bin/pi-shell-launch, and include it in the existing executable chmod command. Add this Compose configuration:

~~~yaml
environment:
  PI_HOST_SHELL: \${PI_HOST_SHELL:-bash}
  PI_HOST_RC_FILE: \${PI_HOST_RC_FILE:-/tmp/pi-host-shellrc}
volumes:
  - \${PI_HOST_RC_SOURCE:-/dev/null}:/tmp/pi-host-shellrc:ro
~~~

Leave command: ["bash", "-lc", "pi-session-forwarder & exec sleep infinity"] unchanged.

- [ ] Step 3: Run the launcher and image/Compose tests and expect all focused checks to pass.

- [ ] Step 4: Commit the in-image integration.

~~~bash
git add bin/pi-shell-launch Dockerfile compose.yml tests/pi-shell-launch.sh tests/compose-shell.sh
git commit -m "feat: add container host-shell launcher"
~~~

### Task 3: Integrate shell selection, rc mode, and rc preparation into bin/pi

**Files:**
- Modify: bin/pi
- Modify: tests/bin-pi-shell.sh
- Modify: tests/bin-pi-update.sh
- Create: tests/bin-pi-host-shell.sh

- [ ] Step 1: Write failing wrapper tests.

Add fake-Docker assertions that a default zsh invocation prepares a generated rc file under the configured state directory and that Compose receives the selected shell and generated source path. Add --bash and --zsh cases that force the Compose shell independently of $SHELL. Add --no-rc-config cases that do not create a generated rc file and pass the no-rc mode to the helper. Assert the persistent foreground command is:

~~~text
docker compose ... exec pi pi-shell-launch pi-session-log ...
~~~

Assert --rm uses pi-shell-launch pi ..., pi shell uses docker exec -it ... pi-shell-launch, and pi shell --root preserves --user 0 before the helper. Add mutually-exclusive --bash/--zsh and unsupported-shell cases that exit 2 and produce no Docker log. Update existing shell-test expectations from ... bash to ... pi-shell-launch.

Run:

~~~bash
bash tests/bin-pi-host-shell.sh
bash tests/bin-pi-shell.sh
bash tests/bin-pi-update.sh
~~~

Expected: FAIL because bin/pi still invokes Bash directly and does not prepare/pass host rc configuration.

- [ ] Step 2: Add shell detection and generated-file preparation.

After workspace/config/volume namespace calculation and before any container-starting path, parse --bash and --zsh as mutually exclusive overrides, otherwise derive the basename of $SHELL (default /bin/bash), reject anything except bash or zsh, and set a stable per-workspace path. Parse --no-rc-config as an independent boolean. Use a stable per-workspace path only when rc loading is enabled:

~~~bash
HOST_SHELL_NAME="\${SHELL:-/bin/bash}"
HOST_SHELL_NAME="\${HOST_SHELL_NAME##*/}"
SHELL_RC_DIRECTORY="$CONFIG_PATH/shell-rc"
HOST_SHELL_RC_FILE="$SHELL_RC_DIRECTORY/\${VOLUME_NAMESPACE}-\${HOST_SHELL_NAME}.rc"
~~~

Add prepare_host_shell_rc() to create the directory and invoke:

~~~bash
"$STACK_ROOT/bin/pi-shell-rc" \
  --shell "$HOST_SHELL_NAME" \
  --home "$HOME" \
  --output "$HOST_SHELL_RC_FILE"
~~~

Call it before persistent Pi startup, disposable Pi startup, and attach_shell when --no-rc-config is false; leave read-only commands such as list without generated-file side effects where possible.

- [ ] Step 3: Pass the generated rc into Compose and route foreground commands.

Extend run_compose() with:

~~~bash
PI_HOST_SHELL="$HOST_SHELL_NAME" \
PI_HOST_RC_SOURCE="$HOST_SHELL_RC_FILE" \
PI_HOST_RC_FILE="/tmp/pi-host-shellrc" \
PI_NO_RC_CONFIG="$NO_RC_CONFIG" \
~~~

Change every foreground Pi invocation (run_logged_pi, update logging, browser-extension install, and disposable --rm Pi/install commands) to prefix the Pi command with pi-shell-launch. Change attach_shell() to execute pi-shell-launch with no arguments and preserve --user 0 ordering. Do not change the persistent service command. In no-rc mode, still use the selected/forced shell but do not prepare or mount a generated rc file.

- [ ] Step 4: Update detailed and brief help.

In print_detailed_help, document host-shell selection, --bash, --zsh, --no-rc-config, Bash's .bash_profile/.bashrc roots, zsh's .zshenv/.zprofile/.zshrc/.zlogin roots, recursive referenced-file resolution, and the fact that the container service bootstrap remains Bash. In print_brief_usage, add compact Shell, --bash/--zsh, and --no-rc-config lines. Update combined-help assertions in tests/bin-pi-update.sh for --help combinations so both help modes mention shell loading and overrides while retaining workspace/container lifecycle and agent-state lineage options.

- [ ] Step 5: Run the wrapper tests and expect all focused tests to pass.

~~~bash
bash tests/bin-pi-host-shell.sh
bash tests/bin-pi-shell.sh
bash tests/bin-pi-update.sh
~~~

- [ ] Step 6: Commit the wrapper integration.

~~~bash
git add bin/pi tests/bin-pi-host-shell.sh tests/bin-pi-shell.sh tests/bin-pi-update.sh
git commit -m "feat: launch Pi with host shell rc"
~~~

### Task 4: Document the user-visible shell behavior

**Files:**
- Modify: README.md
- Modify: bin/pi if help wording needs final alignment

- [ ] Step 1: Add README documentation.

Document that $SHELL selects Bash or zsh, --bash and --zsh force the choice, and --no-rc-config disables startup-file loading. Document that Bash resolves .bash_profile and .bashrc, zsh resolves .zshenv, .zprofile, .zshrc, and .zlogin, and every statically identifiable referenced source file is recursively flattened on the host into a read-only generated file. State that the host home directory is not mounted, dynamic source expressions are left unresolved with warnings, and the persistent service remains Bash.

- [ ] Step 2: Run documentation/help checks.

~~~bash
bash tests/bin-pi-update.sh
bash bin/pi --help >/tmp/pi-help.txt
rg -n 'host|Bash|zsh|rc|service' /tmp/pi-help.txt
~~~

Expected: detailed and combined help describe the shell behavior without starting Docker.

- [ ] Step 3: Commit documentation.

~~~bash
git add README.md bin/pi tests/bin-pi-update.sh
git commit -m "docs: describe host shell loading"
~~~

### Task 5: Run complete verification

**Files:**
- Test: all files under tests/

- [ ] Step 1: Run every repository shell test.

~~~bash
for test_script in tests/*.sh; do
  printf '== %s ==\n' "$test_script"
  bash "$test_script"
done
~~~

Expected: every test exits 0.

- [ ] Step 2: Run static checks.

~~~bash
bash -n bin/pi bin/pi-shell-rc bin/pi-shell-launch
git diff --check HEAD~3..HEAD
git status --short
~~~

Expected: no shell syntax errors, no whitespace errors, and only intended tracked changes.

- [ ] Step 3: Review the final diff against the design.

Confirm that no Compose service command changed from Bash, no helper container was added, no host home directory is mounted, all foreground Pi paths use pi-shell-launch, both help modes mention the behavior, and existing workspace/container/lineage tests remain intact.
