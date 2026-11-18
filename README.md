# Pi-Agent-Containers

Pi-Agent-Containers runs the [Pi](https://pi.dev/) coding agent and
`agent-browser` in Docker while keeping the interactive terminal on the host.
Pi does not need to be installed locally: the host-side `bin/pi` wrapper starts
a persistent Docker Compose service scoped to the selected workspace, mounts
that directory at `/workspace`, and attaches your terminal to the Pi process
inside it. Each workspace gets its own Compose project, container, network, and
persisted state volumes, so several workspaces can run at the same time without
sharing agent state. The repository provides the container, Compose
configuration, and workspace lifecycle wrapper; it does not replace Pi or
reimplement its agent runtime.

## What you get

- Pi with internet access through Docker networking.
- A host directory mounted at `/workspace`.
- Git, Node.js, Chromium, `agent-browser`, `ripgrep`, `jq`, and common shell
  tools inside the image.
- Persistent Pi authentication, settings, model metadata, and helper tools.
- The `pi-agent-browser-native` Pi extension, backed by the upstream
  `agent-browser` CLI.
- Workspace-isolated sessions and browser profiles.
- Optional host OAuth callback forwarding.
- Optional CDP access to an existing browser.
- Readable workspace-specific container and Compose project names.

## Requirements

- Docker Desktop or Docker Engine with the Docker Compose v2 plugin, running
  for normal launches.
- Bash 4 or newer on the host `PATH` (the wrapper's scripts use Bash arrays),
  and Bash or zsh as the interactive host shell. macOS ships Bash 3.2 as
  `/bin/bash`; install a current Bash (for example with Homebrew) and place it
  before `/bin` on `PATH`.
- `lsof` or `nc` on the host for the `--oauth` callback port check.
- A provider authentication method available to Pi: an API key in `.env`, or
  Pi's interactive `/login`.
- A host directory containing the project you want Pi to work on.

The wrapper targets macOS and Linux. Windows users should run it from a
Linux-compatible shell such as WSL.

## Installation

Clone this repository, then make `pi` available from any shell with a
user-level symlink:

```bash
mkdir -p "$HOME/.local/bin"
ln -sfn "/absolute/path/to/Pi-Agents/bin/pi" "$HOME/.local/bin/pi"
```

If `~/.local/bin` is not already on your `PATH`, add it in your host shell
startup configuration, then open a new terminal. Alternatively, add the
repository's `bin` directory itself to `PATH`. Verify which command runs:

```bash
command -v pi
```

Copy `.env.example` to `.env` to set the variables Docker Compose reads (see
[Configuration](#configuration)). Its `PI_PACKAGE_VERSION` and
`AGENT_BROWSER_VERSION` build arguments pin the Pi and `agent-browser`
packages installed in the image; both default to `latest`.

Then run `pi` from a project directory. The first run builds the image, creates
a persistent Pi service for that directory, and opens Pi in it.

## Usage

Run `pi --help` for the complete, authoritative option list and combination
rules. Exact `pi -h` and `pi --help` commands show the detailed help locally
without starting Docker; a help flag combined with another argument prints only
the brief usage summary, and `pi --host - --help` shows native Pi's help.

```bash
# Start or reuse the persistent Pi container for the current directory.
pi

# Send an initial prompt.
pi "Inspect the repository state"

# Use another host directory as /workspace.
pi --workspace ~/src/my-project

# Run Pi in a disposable one-off container.
pi --rm

# Run native Pi on the host instead of Docker; offers to install it if missing.
pi --host

# Force a command named like a wrapper command through to Pi.
pi - list
```

The selected directory is mounted at `/workspace`, so edits made by Pi are
edits to files on the host. Persistent mode is the default. It keeps the
container and named volumes so a later `pi` can reconnect to the same
workspace. `--rm` is the exception: it uses a one-off Compose container and
removes it when Pi exits, while still using the workspace's persistent state
volumes. A running `--rm` container of the same workspace does not block later
launches and is not shown by `pi list`. `--rm` cannot be combined with `stop`,
`update`, `remove`, `list`, `shell`, `copy`, `--replace`, `--keep-existing`,
`--seed`, or `--latest-state`.

Arguments that are not wrapper options or commands are passed through to Pi,
for example `pi install npm:pi-web-access` installs a Pi package into the
current workspace's agent state. The wrapper's `stop`, `update`, `list`,
`remove`, `shell`, and `copy` commands take precedence over Pi commands with
the same names. Use a leading `-` to force a wrapper command name through to
Pi: `pi - list` runs Pi's `list` command inside the container, while `pi list`
runs the wrapper inventory command. The marker is a literal argument and does
not require shell escaping.

## Commands

```bash
# Stop the current workspace without removing its state.
pi stop

# Rebuild the image and recreate the persistent service.
pi update

# Update extensions and/or model catalogs in the persistent state volume.
pi update --extensions --models

# Show running and stopped Pi workspaces.
pi list

# Remove the current project while preserving or deleting its state.
pi remove
pi remove --all

# Open a shell in the current workspace's container, or as root.
pi shell
pi shell --root

# Pick a source and copy all agent state into this workspace.
pi copy

# Pick a destination and copy all state from this workspace.
pi copy --to
```

`stop` and `remove` act only on the stack labelled with the current workspace
path and fail when there is none, or when that stack's Compose project also
holds another workspace's container. `remove --all` on a workspace whose stack
is already gone lists its leftover state volumes and asks whether to leave them
(the default), delete all, or delete selected ones. `--oauth` cannot be
combined with `stop` or `remove`.

`stop`, `remove`, `shell`, and `copy` operate on the current workspace. They do
not affect another workspace unless you explicitly target that workspace with
`--workspace`. `list` shows every persistent stack and does not accept
`--workspace`.

`pi shell` reuses the current workspace container when possible, starting it if
stopped and reconciling it with Compose `up` when it lacks the generated rc
mount; otherwise it offers a picker for existing persistent Pi containers and
starts a stopped selection before opening the shell. Use `pi shell --root` or
`pi shell -r` for a root shell. When no current workspace container exists, the
picker offers `0) Start a new project`; choosing it creates the directory if
needed, starts the persistent service, and opens the shell. Every picker, in
`pi shell` and `pi copy`, ends with `X) Cancel (or Esc)`. Choices are single
keys; when a picker lists ten or more entries, a choice starting with 1-9 is a
number confirmed with Enter.

### Host shell configuration

Foreground `pi` commands and `pi shell` use Bash or zsh selected from the
basename of the host's `$SHELL`. Use `--bash` or `--zsh` to force the choice.
`pi list`, `pi stop`, `pi remove`, and `pi copy` start no host shell and do
not check `$SHELL`. Use `--no-rc-config` to start the selected shell without
generating, mounting, or loading host startup configuration.

For Bash, the host `.bash_profile` and `.bashrc` are startup roots. For zsh,
the roots are `.zshenv`, `.zprofile`, `.zshrc`, and `.zlogin`. Every statically
identifiable `source` or dot-file reference in those roots is recursively
flattened on the host into one generated rc file. Its per-workspace directory
under the configuration directory is mounted read-only in the Pi container, so
refreshed rc contents are visible to an already-running container. Dynamic
source expressions are left unresolved and produce warnings.

The host home directory is not mounted into the container. The persistent
container service remains Bash-based; host-shell selection applies only to
foreground Pi commands and interactive shell attachment. For zsh, the launcher
creates a private `ZDOTDIR` under `${TMPDIR:-/tmp}` and removes it when zsh
exits, preserving zsh's exit status.

Missing images are built before use; `--rebuild` builds once with the cache
and Compose recreates the service from the result, while `pi update` pulls and
rebuilds without the cache. An image that lacks `pi-shell-launch` is reported
as stale; run `pi update` or use `--rebuild` to recover. `pi shell` repairs the
current workspace image when needed.

### Native Pi on the host

`pi --host` runs Pi directly on the host instead of in Docker. It starts in the
selected workspace directory, chosen by `--workspace`, then `PI_WORKSPACE`,
then the invocation directory. It uses the host's `~/.pi/agent`
authentication, settings, and sessions, not the workspace volumes. No Docker
command runs.

The wrapper first looks for the launcher script written by Pi's official
installer at `${PI_CODING_AGENT_DIR:-~/.pi/agent}/bin/pi`. If that is missing,
it runs the first `pi` on `PATH` that is not this wrapper, such as an npm,
Homebrew, or Nix installation. If neither exists, it offers to run
`curl -fsSL https://pi.dev/install.sh | sh`. The installer refuses to install
while `pi` resolves to this wrapper, so the wrapper hides itself from the
installer's `PATH`. It also puts the launcher directory first, so the installer
keeps Pi in `~/.pi/agent/bin` and does not link a `pi` that would shadow this
wrapper.

Every argument after the wrapper options goes to native Pi, including the
names of wrapper commands:

```bash
pi --host --continue    # Resume native Pi's latest session here.
pi --host update        # Update the native Pi installation.
pi --host - --help      # Show native Pi's help.
```

`--host` accepts `--workspace`. It rejects container, state, shell, and OAuth
options such as `--rm`, `--seed`, `--zsh`, and `--oauth`.

## Workspace and state

The workspace is selected in this order:

1. `--workspace PATH`
2. `PI_WORKSPACE` exported in the shell
3. The directory from which `pi` is invoked

Relative paths resolve from the invocation directory. `--workspace` is usually
the clearest option. `PI_WORKSPACE` remains useful for automation and existing
shell scripts; it is not loaded automatically from `.env`.

Each workspace's Compose project and persistent container are named
`pi-agents-pi-<workspace-basename>`. The basename is lowercased and every
character other than `a-z`, `0-9`, `_` and `-` becomes `-`, as Compose project
names require, so `~/src/my.project` runs as `pi-agents-pi-my-project`. Agent,
session, and browser volumes keep stable internal names, so renaming the
project does not create fresh state.

`--replace` force-recreates the current workspace container. If another
workspace has the same basename, `pi` prompts before renaming the existing
container to `pi-agents-pi-<first-differing-path-components>-<path-hash>` and
giving the current workspace its own such name; the prompt defaults to cancel.
`--keep-existing` preserves the existing container and creates the
disambiguated one instead. `--replace` and `--keep-existing` are mutually
exclusive. Running and stopped containers are both considered. Every
destination container name and Compose project is checked before the first
rename, and `pi` stops without renaming anything if one belongs to a different
workspace. A workspace that already has a stack reuses it under its current
name, and two stacks claiming the same workspace are refused as ambiguous.

The host workspace is bind-mounted at `/workspace`. Pi's agent state is kept in
private Docker volumes per workspace:

| Data | Persistence |
| --- | --- |
| `auth.json`, settings, model metadata, helpers | Copied from the seed on first initialization, then isolated |
| `sessions/` | Always private to the workspace |
| Browser profile | Always private to the workspace |

Before Compose starts, the wrapper provisions these volumes and declares them
external, so a Compose metadata change never recreates existing state. It also
repairs ownership and write permissions of the agent, session, and browser
volumes before launching Pi. Helper containers that probe, seed, copy, or
repair state volumes run the configured Pi service image
(`docker compose config --images pi`) with an explicit `--user`, so no
separate image is pulled; the image is built first when it is missing.

The first managed stack becomes the seed. A new workspace copies the seed's
agent files once, excluding sessions; it does not share the volume. Later
changes in either workspace stay independent.

Initialization is tracked by marker files in the agent-state volume.
`.container-initialization-pending` records the seed source before copying,
and `.container-initialized` marks completion. If a seed copy is interrupted,
the next launch resumes from the recorded source, and fails rather than
reseeding from another volume if that source is gone. Agent-state volumes
created before the markers that contain a non-empty `auth.json` or a
`defaultProvider`/`defaultModel` setting are marked initialized unchanged.

Agent, session, and browser volumes carry `com.pi-agents.*` labels for their
workspace and kind. State volumes and containers without matching labels are
refused: a state volume must carry `com.pi-agents.managed=true` and this
workspace's path and kind, and a container must carry
`com.pi-agents.managed=true` to be treated as a workspace's stack.

Use these options when creating a workspace:

```bash
# Run on this workspace's separate, empty extra agent-state volume.
pi --new-state

# Copy from the newest Docker-managed state during first initialization.
pi --latest-state

# Make this workspace the seed for future workspaces.
pi --seed
```

`--latest-state` only affects first initialization. On an already initialized
workspace it has no effect and prints a warning.

The seed pointer is stored on the host at
`~/.config/pi-agent-containers/seed`; `PI_AGENT_CONTAINERS_CONFIG_PATH`
overrides its directory (see [Configuration](#configuration)). If the pointer
is missing but managed state volumes exist, the wrapper lists every managed
normal state volume with its creation time, proposes the oldest as the seed,
and asks for confirmation (`y` or `yes`) before initializing a new workspace,
even with `--latest-state`; the proposed volume is checked again after the
answer, and declining or end of input exits with status 2. A pointer that does
not name a managed normal state volume, such as a removed volume or an extra
state volume, is treated as missing the same way; launches never delete the
pointer file. Launching an already-initialized workspace never fills
a missing pointer on its own; only `--seed` does. Removing the current seed
with `pi remove --all` reassigns the pointer to the oldest remaining normal
state, if one exists, and otherwise deletes the pointer file.

`pi list` reports each stack, sorted by container name, with its workspace
path, project/container names, Docker timestamps, the mounted `agent-state`
volume, `active-state` (`normal`, `extra`, `unknown`, or `none`), the
workspace's `extra-state` volume (or `none`), the mounted `session-state` and
`browser-state` volumes, and seed/latest markers. `started` comes from Docker's
`State.StartedAt`; a container that has never started is shown as `never`.
Markers only ever name normal agent-state volumes, so a stack running on its
extra volume is marked through its normal one. After the stacks, or after
`No Pi stacks found.`, an `ORPHAN VOLUMES:` section lists managed state volumes
that no listed stack mounts or owns, with their `kind`, `workspace`, `project`,
`created` time, and markers (only for kind `agent`).

### Extra state volume (`--new-state`)

`--new-state` runs the workspace against an extra agent-state volume,
`pi-agents-new-ws-<hash>_pi-agent-state`, and force-recreates the container on
it. Sessions and browser state stay on the workspace's normal volumes, and the
normal agent-state volume is left untouched. Running without `--new-state`
later recreates the container on the normal agent state.

- The extra volume is created empty, marked initialized, and never seeded;
  `--new-state --latest-state` is rejected.
- It is never the seed or a seed candidate, never the `latest` volume, and
  never a `--latest-state` source. `--seed --new-state` is rejected.
- Extra volumes are labelled `com.pi-agents.state-kind=agent-extra` with the
  usual managed, workspace, and project labels; an extra volume with any other
  kind is refused.
- Whenever the workspace has an extra volume, every start or reuse of the
  persistent container, every `--rm` run, and `pi shell` when it starts or
  creates the stack prints a warning: either that the extra volume is in use
  and the normal state is untouched, or that it exists and is not in use.
- `pi remove` keeps it and names it in a warning; `pi remove --all` removes it
  with the workspace's other state volumes.

### Copying agent state

`pi copy` copies between Pi state volumes: the managed agent-state volumes
labelled with their workspace. It uses a disposable Docker helper with the
source state volume mounted read-only and the destination state volume mounted
read-write, and never shares the volumes afterward. Neither workspace needs a
container, and containers that exist may be running or stopped. Project files
are never copied.

By default, `pi copy` treats the current workspace as the destination and lets
you pick the source. `pi copy --to` treats the current workspace as the source
and lets you pick the destination. The current workspace's state volumes are
created first when missing. The picker lists every other managed agent-state
volume with its workspace and creation time, then `X) Cancel (or Esc)`;
cancelling exits with status 3, and any other invalid choice exits with status
2. `--from` explicitly selects the source (the default); `--from` and `--to`
are mutually exclusive. `copy` refuses `--rm`, `--rebuild`, `--replace`,
`--keep-existing`, `--new-state`, `--seed`, `--latest-state`, and `--oauth`.

The category flags are `--sessions`/`-s`, `--auth`/`-a`, and
`--extensions`/`-e`. Without category flags, all categories are copied. Without
`--all`, Pi lets you select individual sessions, providers, or extensions;
`--all` copies every item in the selected categories.

```bash
pi copy --sessions --auth --extensions --all
pi copy --extensions --override
```

Copying is additive by default. Duplicate items offer `r` (replace), `s`
(skip), `a` (replace all), or `q` (cancel). `--override` replaces duplicates
automatically.

Sessions live in each workspace's separate session volume, which the helper
mounts at `sessions/` on both sides. It is located by the workspace label of
its agent-state volume; `pi copy` fails before copying unless each side has
exactly one. Copies that exclude
sessions (`--auth`, `--extensions`) do not need them.

The copy is transactional per run. Every selected item, including each
duplicate decision, is staged in a temporary directory inside the destination
before the destination changes. Staged items are then published by rename,
each previous item kept as a backup until all items are in place; a failure or
interruption while publishing restores the previous items. Cancelling a picker
or a duplicate prompt (`q`) exits with status 3 and leaves the destination
unchanged. Symlinked state paths on either side, and overlapping
source/destination directories, are refused.

When a running container mounts the destination state volume, copied files are
immediately present in it, but Pi may still hold cached authentication or
extension metadata; `pi copy` names each such container in a warning to restart
it.

## Authentication and OAuth

Provider credentials live in the workspace's agent-state volume, so
authentication survives container recreation. API keys can be supplied in
`.env`; they are passed to the container at runtime and never written into the
image. Pi's `/login` command can also perform interactive provider
authentication in the attached terminal.

The normal stack publishes no host ports. For browser-based OAuth, start Pi
with:

```bash
pi --oauth
```

This publishes the currently known fixed callbacks on host IPv4 and IPv6
loopback (`127.0.0.1` and `[::1]`) only:

| Provider/flow | Port |
| --- | ---: |
| OpenAI Codex / ChatGPT Plus or Pro | `1455` |
| Anthropic Claude Pro/Max | `53692` |
| `pi-antigravity` extension | `51121` |

Custom fixed callback ports can be added as comma- or space-separated values:

```bash
pi --oauth 7000,7001
pi --oauth 7000 7001
```

The `PI_OAUTH_CALLBACK_PORTS` variable is additive, but it must be exported in
the shell because `bin/pi` does not source `.env`:

```bash
export PI_OAUTH_CALLBACK_PORTS="7000,7001"
pi --oauth
```

Only one running stack can reserve a given host port. Before starting, the
wrapper validates each selected port and checks it with `lsof` (or `nc` when
`lsof` is missing), refusing one that something else already listens on.
Ports the workspace's own running stack already publishes are reused; a `--rm`
run cannot share them. Changing OAuth mappings can cause Compose to recreate
the container; the persisted state volumes keep authentication and settings
intact. Run `pi` without `--oauth` afterward to reconcile the stack without
host callback mappings.

Some providers and extensions use dynamic or provider-specific callback flows.
When no fixed port is available, use Pi's device-code or paste-redirect login
flow instead of guessing a host port.

## Networking and browser access

The container has outbound internet access through Docker networking. Each
workspace's Compose project has its own network; services on that network are
reachable by service name.

To reach a service running on the host, use:

```text
http://host.docker.internal:<port>
```

`localhost` inside Pi means the Pi container, not the host.

`agent-browser` launches the Chromium installed in the image by default, with
its profile stored in the workspace's browser volume. To connect it to an
existing CDP endpoint, set `AGENT_BROWSER_CDP` in `.env` to a CDP port or
WebSocket URL:

```dotenv
AGENT_BROWSER_CDP=http://host.docker.internal:9222
```

The endpoint must be reachable from the container. On Docker Desktop,
`host.docker.internal` is the usual route to a host browser.

Before each Pi run, the wrapper ensures that
`npm:pi-agent-browser-native` is installed in the mounted workspace agent
state. The extension exposes Pi's native `agent_browser` tool and delegates
browser execution to the upstream `agent-browser` CLI and Chromium.

## Updates

```bash
pi update                          # Pull, rebuild without cache, recreate the service.
pi update --extensions             # Update Pi-managed extensions.
pi update --models                 # Update Pi's model catalogs.
pi update --extensions --models    # Both.
```

`pi update` rebuilds the image without the Docker build cache, then
force-recreates the persistent service for the current workspace; set
`PI_PACKAGE_VERSION` and `AGENT_BROWSER_VERSION` in `.env` to pin the packages
it installs. `pi update --extensions` starts the persistent service and runs
Pi's extension update command, including `pi-agent-browser-native`.
`pi update --models` starts the service and updates Pi's model catalogs in the
persistent state volume.

## Logs and inspection

Persistent Pi session records are streamed by a service-side forwarder to the
Compose service log stream while Pi runs. Wrapper-managed package and model
update output is mirrored there too, including `pi update --extensions`. Docker
stdout is pretty and colored by default. Get the readable project name from
`pi list`, then follow it with:

```bash
docker compose --project-name <workspace-project> \
  -f /path/to/Pi-Agents/compose.yml \
  logs --follow --timestamps pi
```

These logs are an inspectable live audit stream. The complete durable session
records remain in the workspace-specific session Docker volume at
`/home/node/.pi/agent/sessions/*.jsonl` inside the container.

The forwarder runs alongside the service's main process (`sleep infinity`) in
a restart loop, so a forwarder exit never stops the container or attached Pi
sessions. If a session stream dies, the forwarder exits rather than resuming
from a stale offset, which could duplicate records; on restart it follows
existing sessions from their current end, so history is not replayed. Records
written in the second before a restart can be missing from the Docker log but
stay in the session volume. In `pretty` format, lines that are not JSON objects
(for example a truncated record) are passed through verbatim.

To select another log representation, set these Compose variables in `.env`
before recreating the workspace container (for example with `pi update`):

```dotenv
PI_SESSION_LOG_FORMAT=raw         # pretty (default) or raw JSONL
PI_SESSION_LOG_COLOR=never        # always (default), auto, or never
PI_SESSION_LOG_POLL_INTERVAL=0.2  # seconds between session file scans; default 1
```

Other useful inspection commands:

```bash
docker compose --project-name <workspace-project> -f /path/to/Pi-Agents/compose.yml ps
docker volume ls --filter label=com.pi-agents.managed=true
```

## Configuration

Copy `.env.example` to `.env`. The file is read by Docker Compose for image
build arguments and container environment. Settings consumed directly by
`bin/pi` must be exported in the shell or supplied as command-line options.

| Variable | Purpose |
| --- | --- |
| `PI_PACKAGE_VERSION` | Pi package version used when building the image; defaults to `latest`. |
| `AGENT_BROWSER_VERSION` | `agent-browser` version used when building the image; defaults to `latest`. |
| `ANTHROPIC_API_KEY` | Anthropic API access from inside the container. |
| `OPENAI_API_KEY` | OpenAI API access from inside the container. |
| `GOOGLE_API_KEY` | Google API access from inside the container. |
| `GEMINI_API_KEY` | Gemini API access from inside the container. |
| `PI_OAUTH_CALLBACK_HOST` | Bind address used by Pi's callback listeners inside the container. |
| `AGENT_BROWSER_CDP` | Optional CDP port or WebSocket URL for an existing browser. |
| `PI_SESSION_LOG_FORMAT` | Session log format, `pretty` (default) or `raw`. |
| `PI_SESSION_LOG_COLOR` | Session log color, `always` (default), `auto`, or `never`. |
| `PI_SESSION_LOG_POLL_INTERVAL` | Seconds between the session log forwarder's scans for new or grown session files; defaults to `1`. |
| `PI_OAUTH_CALLBACK_PORTS` | Extra fixed OAuth ports; export in the shell before calling `bin/pi`. |
| `PI_WORKSPACE` | Workspace path; export in the shell. |
| `PI_AGENT_CONTAINERS_CONFIG_PATH` | Host configuration directory; export in the shell. |

The configuration directory defaults to `~/.config/pi-agent-containers`. It
holds the seed pointer (`seed`) and the generated per-workspace shell rc files
(`shell-rc/`):

```bash
export PI_AGENT_CONTAINERS_CONFIG_PATH="$HOME/.config/pi-agent-containers"
```

Avoid setting `PI_WORKSPACE` in `.env`; use `--workspace` or export it in the
shell so the invocation directory remains the default.

## Cleanup boundaries

The container runs as the non-root `node` user without a host Docker socket
mount. Persistent data lives in the selected workspace's named volumes. The
local configuration directory stores the seed pointer and generated workspace
shell configuration.

Use `pi remove --all` only when you intend to delete the selected workspace's
persistent Pi (normal and extra), session, and browser volumes. It does not
remove another workspace's state, and the host workspace files are never
removed.

## Development

The shell regression tests live in `tests/`. `tests/lib` holds the shared
helpers and a stateful fake `docker` that the wrapper tests put on `PATH`.
`tests/bin-pi-*.sh` cover the wrapper by area (CLI, lifecycle, workspace,
state, copy, shell, host shell, host mode, OAuth, update); the other scripts
test the helpers (`pi-session-*`, `pi-shell-*`, `pi-state-copy`) and the
Compose files. The tests require Bash 4 or newer on `PATH` (they skip with a
message otherwise) and `jq`; some also call `docker compose config`, which
reads Compose files without starting anything. Run them all from this
directory:

```bash
for t in tests/*.sh; do bash "$t"; done
```

Validate the Compose configurations without starting services:

```bash
docker compose --file compose.yml config -q
docker compose --file compose.yml --file compose.oauth.yml config -q
```

The project intentionally keeps the host wrapper in `bin/pi`: it is the
boundary that resolves workspace identity, provisions isolated volumes, and
decides whether Pi runs through persistent `compose exec` or disposable
`compose run --rm`.

This repository mirrors its sibling, Claude-Code (`bin/claude-container`): the
same concept gets the same function, variable, file, and test name in both;
helper scripts that behave the same stay textually identical apart from tool
names; fixes are ported both ways.

## Credits

Pi-Agent-Containers is maintained in this [Pi-Agent-Containers repository](.).
The container builds on [Pi](https://pi.dev/) and
[agent-browser](https://agent-browser.dev/).

## License

Released under the [MIT License](LICENSE.md).
