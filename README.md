# Pi-Agent-Containers

Pi-Agent-Containers is a Docker base-containerization utility for
[Pi](https://pi.dev/). It runs Pi coding agents and `agent-browser` in Docker while keeping
the interactive terminal on the host. Pi does not need to be installed
locally: the host-side `bin/pi` wrapper starts the container, mounts the
selected workspace, and attaches your terminal to the Pi process inside it.

This repository provides the container, Compose configuration, and workspace
lifecycle wrapper around Pi. It does not replace Pi or try to reimplement Pi's
agent runtime.

Each workspace gets its own Compose project, container, network, and persisted
state volumes. Multiple Pi Compose stacks in separate workspaces can run at the
same time without sharing their agent state.

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

- Docker Desktop or Docker Engine with Docker Compose v2.
- Bash and standard Unix tools on the host.
- A host directory containing the project you want Pi to work on.

The wrapper targets macOS and Linux. Windows users should run it from a
Linux-compatible shell such as WSL.

## Quick start

```bash
./bin/pi
```

The first run creates a persistent Pi service for the current directory and
opens Pi in that workspace. The project directory is mounted at `/workspace`,
so edits made by Pi are edits to files on the host.

To use `pi` from any shell session, add the wrapper directory to your `PATH`:

```bash
export PATH="/absolute/path/to/Pi-Agent-Containers/bin:$PATH"
```

Or create a user-level symlink:

```bash
mkdir -p "$HOME/.local/bin"
ln -sfn "/absolute/path/to/Pi-Agent-Containers/bin/pi" "$HOME/.local/bin/pi"
export PATH="$HOME/.local/bin:$PATH"
```

## Commands

Run `./bin/pi --help` for the complete, authoritative help text.

```bash
# Start or reuse the persistent Pi container for the current directory.
./bin/pi

# Send an initial prompt.
./bin/pi "Inspect the repository state"

# Use another host directory as /workspace.
./bin/pi --workspace ~/src/my-project

# Run Pi in a disposable one-off container.
./bin/pi --rm

# Stop the current workspace without removing its state.
./bin/pi stop

# Open a shell in the current workspace's running or stopped container.
./bin/pi shell

# Open that shell as root.
./bin/pi shell --root

# Rebuild the image and recreate the persistent service.
./bin/pi update

# Update extensions and/or model catalogs in the persistent state volume.
./bin/pi update --extensions
./bin/pi update --models
./bin/pi update --extensions --models

# Install another Pi package into the current workspace's agent state.
./bin/pi install npm:pi-web-access

# Force a command named like a wrapper command through to Pi.
./bin/pi - list

# Show running and stopped Pi workspaces.
./bin/pi list

# Remove the current project while preserving or deleting its state.
./bin/pi remove
./bin/pi remove --all
```

Persistent mode is the default. It keeps the container and named volumes so a
later `./bin/pi` can reconnect to the same workspace. `--rm` is the exception:
it uses a temporary Compose container and removes it when Pi exits.

`--replace` force-recreates the current workspace container. If another
workspace has the same basename, `--keep-existing` preserves the existing
container and creates a disambiguated one instead.

Arguments that are not wrapper options or commands are passed through to Pi.
The wrapper's `stop`, `update`, `list`, `remove`, and `shell` commands take
precedence over Pi commands with the same names. `pi shell` reuses the current
workspace container when possible; otherwise it offers a picker for existing
persistent Pi containers and starts a stopped selection before opening the shell.
Use `pi shell --root` or `pi shell -r` for a root shell.

When no current workspace container exists, `pi shell` offers `0) Start a new
project`; choosing it creates the directory if needed, starts the persistent
service, and opens the shell. The picker ends with `X) Press Esc to cancel`.

Use a leading `-` to force a wrapper command name through to Pi: `pi - list`
runs Pi's `list` command inside the container, while `pi list` runs the wrapper
inventory command. The marker is a literal argument and does not require shell
escaping.

## Workspace and state

The workspace is selected in this order:

1. `--workspace PATH`
2. `PI_WORKSPACE` exported in the shell
3. The directory from which `pi` is invoked

`--workspace` is usually the clearest option. `PI_WORKSPACE` remains useful for
automation and existing shell scripts; it is not loaded automatically from
`.env`.

The host workspace is bind-mounted at `/workspace`. Pi's agent state is kept in
private Docker volumes per workspace:

| Data | Persistence |
| --- | --- |
| `auth.json`, settings, model metadata, helpers | Copied from the seed on first initialization, then isolated |
| `sessions/` | Always private to the workspace |
| Browser profile | Always private to the workspace |

The first managed stack becomes the seed. A new workspace copies the seed's
agent files once; it does not share the volume. Later changes in either
workspace stay independent.

Use these options when creating a workspace:

```bash
# Start with an empty agent-state volume.
./bin/pi --new-state

# Copy from the newest Docker-managed state during first initialization.
./bin/pi --latest-state

# Make this workspace the seed for future workspaces.
./bin/pi --seed
```

`--latest-state` only affects first initialization. On an already initialized
workspace it has no effect and prints a warning. A `--new-state` workspace is
still eligible to be selected by a later `--latest-state` run.

The seed pointer is stored on the host at
`~/.config/pi-agent-containers/seed`. Override its directory in the shell with:

```bash
export PI_AGENT_CONTAINERS_CONFIG_PATH="$HOME/.config/pi-agent-containers"
```

If the pointer is missing but managed state volumes exist, the wrapper proposes
the oldest state as the seed and asks for confirmation. Removing the current
seed with `./bin/pi remove --all` reassigns the pointer to the oldest remaining
state, if one exists.

`./bin/pi list` reports workspace paths, project/container names, Docker
timestamps, state volumes, and seed/latest markers. `started` comes from
Docker's `State.StartedAt`; a container that has never started is shown as
`never`.

## Authentication and OAuth

API keys can be supplied in `.env`, but Pi's `/login` command can also perform
interactive provider authentication.

The normal stack publishes no host ports. For browser-based OAuth, start Pi
with:

```bash
./bin/pi --oauth
```

This publishes the currently known fixed callbacks on host loopback:

| Provider/flow | Port |
| --- | ---: |
| OpenAI Codex / ChatGPT Plus or Pro | `1455` |
| Anthropic Claude Pro/Max | `53692` |
| `pi-antigravity` extension | `51121` |

Custom fixed callback ports can be added as comma- or space-separated values:

```bash
./bin/pi --oauth 7000,7001
./bin/pi --oauth 7000 7001
```

The `PI_OAUTH_CALLBACK_PORTS` variable is additive, but it must be exported in
the shell because `bin/pi` does not source `.env`:

```bash
export PI_OAUTH_CALLBACK_PORTS="7000,7001"
./bin/pi --oauth
```

Only one running stack can reserve a given host port. Changing OAuth mappings
can cause Compose to recreate the container; Pi's persisted state volumes keep
authentication and settings intact. Run `./bin/pi` without `--oauth` afterward
to reconcile the stack without host callback mappings.

Some providers and extensions use dynamic or provider-specific callback flows.
When no fixed port is available, use Pi's device-code or paste-redirect login
flow instead of guessing a host port.

## Networking and browser access

The container has outbound internet access through Docker's default bridge
network. Other Compose services are reachable by service name, for example
`http://web:3000`.

To reach a service running on the host, use:

```text
http://host.docker.internal:<port>
```

`localhost` inside Pi means the Pi container, not the host.

`agent-browser` launches the Chromium installed in the image by default. To
connect it to an existing CDP endpoint, set `AGENT_BROWSER_CDP` in `.env`:

```dotenv
AGENT_BROWSER_CDP=http://host.docker.internal:9222
```

The endpoint must be reachable from the container. On Docker Desktop,
`host.docker.internal` is the usual route to a host browser.

Before each Pi run, the wrapper ensures that
`npm:pi-agent-browser-native` is installed in the mounted workspace agent
state. The extension exposes Pi's native `agent_browser` tool and delegates
browser execution to the upstream `agent-browser` CLI. Use
`./bin/pi update --extensions` to update it with the other Pi packages.

## Logs and inspection

Persistent Pi session records are streamed by a service-side forwarder to the
Compose service log stream while Pi runs. Docker stdout is pretty and colored
by default. Get the readable project name from `./bin/pi list`, then follow it
with:

```bash
docker compose \
  --project-name <workspace-project> \
  logs --follow --timestamps pi
```

These logs are an inspectable live audit stream. The complete durable session
records remain in the workspace-specific `pi-sessions` Docker volume at
`/home/node/.pi/agent/sessions/*.jsonl` inside the container.

To select another log representation, set these Compose environment variables
before recreating the workspace container:

```bash
PI_SESSION_LOG_FORMAT=raw   # pretty or raw
PI_SESSION_LOG_COLOR=never  # always, auto, or never
./bin/pi update
```

Other useful inspection commands:

```bash
docker compose --project-name <workspace-project> ps
docker volume ls --filter name=pi-agents
```

The wrapper's `list`, `stop`, and `remove` commands operate on the current
workspace. They do not affect another workspace unless you explicitly target
that workspace with `--workspace`.

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
| `PI_OAUTH_CALLBACK_PORTS` | Extra fixed OAuth ports; export in the shell before calling `bin/pi`. |
| `PI_AGENT_CONTAINERS_CONFIG_PATH` | Host directory for the seed pointer; export in the shell. |

Avoid setting `PI_WORKSPACE` in `.env`; use `--workspace` or export it in the
shell so the invocation directory remains the default.

## Development

Build the image and run the shell regression tests:

```bash
docker compose build pi
bash tests/bin-pi-update.sh
bash tests/bin-pi-list.sh
bash tests/bin-pi-lineage.sh
bash tests/bin-pi-seed-recovery.sh
bash tests/bin-pi-state.sh
bash tests/bin-pi-workspace.sh
bash tests/compose-oauth.sh
```

Validate both Compose configurations without starting services:

```bash
docker compose --file compose.yml config -q
docker compose --file compose.yml --file compose.oauth.yml config -q
```

The project intentionally keeps the host wrapper in `bin/pi`: it is the
boundary that resolves workspace identity, provisions isolated volumes, and
decides whether Pi runs through persistent `compose exec` or disposable
`compose run --rm`.

## Credits

Pi-Agent-Containers is maintained in this [Pi-Agent-Containers repository](.). The container builds
on [Pi](https://pi.dev/) and [agent-browser](https://agent-browser.dev/).

## License

Released under the [MIT License](LICENSE.md).
