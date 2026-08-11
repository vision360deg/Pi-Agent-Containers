# Host Shell Startup Configuration Design

## Goal

Make both normal `pi` launches and `pi shell` use the host-selected `$SHELL`
and the matching host startup configuration without exposing the host home
directory to the container.

## Behavior

- The wrapper reads the host `$SHELL` and supports `bash` and `zsh`.
- Bash resolves `~/.bash_profile` followed by `~/.bashrc` (deduplicating files
  that source one another); zsh uses `~/.zshrc`.
- The wrapper resolves literal `source` and `.` references in the startup-file
  chain on the host, preserving source order and preventing recursive cycles.
- The resolver inlines readable files addressed through the host home directory
  (including `~`, `$HOME`, and literal home-relative paths) into one generated
  rc file. Dynamic or unresolvable source expressions remain in the generated
  file and produce a warning; they are not executed on the host.
- The generated rc file is mounted read-only into the Pi container. The host
  home directory and the original startup files are never mounted into Docker.
- A container helper starts the selected shell interactively, sources the
  generated rc file, and then `exec`s its arguments. Normal Pi runs and
  disposable `--rm` runs use this helper for the foreground Pi process.
- `pi shell` and `pi shell --root` use the same helper, preserving the selected
  Docker user while loading the generated rc file.
- The persistent service bootstrap remains unchanged and continues to use Bash
  because it only starts the session log forwarder and keeps the service alive.
- Missing startup files are allowed; the selected shell still launches.
- Unsupported host shells fail before Docker starts with a clear error naming
  the supported shells.

## Architecture

`bin/pi` owns host-side shell detection, startup-file resolution, generated-file
lifecycle, and propagation of the selected shell/rc path into Compose. A small
container-side helper owns shell invocation and argument-safe `exec` behavior.
The Docker image installs zsh and copies the helper; Compose receives one
read-only bind mount for the generated rc file.

The generated file is stored at a stable per-workspace path under the wrapper's
configuration directory so a persistent container does not depend on a deleted
temporary file. Its contents are refreshed before each launch. The file is
generated from host startup files only and is not copied into Pi agent state.

## Safety and resolution limits

Resolution is static: the wrapper reads files and recognizes only literal,
home-relative source targets. It never evaluates host shell code. Source cycles
are reported once and skipped. References outside the host home, dynamic
expansions, missing files, and unreadable files remain as original source lines
and are reported as warnings, so the container shell can apply its own behavior
without silently executing host-side commands.

The generated rc runs with the container's normal `HOME=/home/node`, so host
startup files that use `~` after flattening may still refer to the container
home. The resolver's purpose is to inline the host files, not to emulate the
entire host filesystem.

## Testing

- Unit-style shell tests cover bash/zsh selection, starting-file selection,
  ordered recursive inlining, cycle handling, and unresolved-source warnings.
- Wrapper tests verify that persistent Pi, disposable Pi, normal `pi shell`,
  and root `pi shell` invoke the helper with the selected shell configuration.
- Existing detailed-help and combined-argument brief-help assertions are
  updated to document host-shell behavior while preserving workspace,
  container-lifecycle, and agent-state-lineage help.
- The Dockerfile/Compose smoke checks verify zsh and the helper are present and
  that the generated rc mount is read-only.
