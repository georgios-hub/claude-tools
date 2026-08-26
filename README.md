# claude-tools

Containerised Claude Code with a ready-made toolchain (node/npm, pyenv, SDKMAN!)
and agents/settings version-controlled in this repository.

## Files

| File                   | Purpose                                                                  |
|------------------------|--------------------------------------------------------------------------|
| `Dockerfile`           | The image: debian + node/npm + claude + pyenv + SDKMAN! + non-sudo user  |
| `docker-entrypoint.sh` | Entrypoint — initialises pyenv/SDKMAN! and runs `exec claude "$@"`       |
| `build.sh`             | Builds the image, passing through the current user's uid/gid             |
| `run-claude.sh`        | Runs the image with every mount wired up, forwarding arguments to claude |
| `settings.json`        | User-level settings, mounted at `~/.claude/settings.json`                |
| `agents/`              | Your agents, mounted at `~/.claude/agents`                               |

## Build

```bash
./build.sh
```

It reads `id -u` / `id -g` and passes them as build arguments, so the user inside the container has
the same uid/gid as you and files written into the mounts stay owned by you.

Useful flags:

```bash
./build.sh --no-cache
./build.sh --tag claude-tools:dev
./build.sh --python 3.11.9 --java 17.0.13-tem
./build.sh --python none --java none        # fast build, no CPython compilation
./build.sh --maven 3.9.9 --gradle 8.10.2    # default: none
./build.sh --claude-version 2.1.246         # pin the claude version
```

The first build takes roughly 5–10 minutes, because `pyenv install` compiles CPython from source.

## Run

```bash
./run-claude.sh                        # interactive claude in the current directory
./run-claude.sh --agent code-reviewer  # arguments are forwarded verbatim to claude
./run-claude.sh -p "what does this repo do?"
./run-claude.sh --dangerously-skip-permissions
./run-claude.sh shell                  # bash inside the container instead of claude
```

### Putting it on PATH

The script has to keep living in this repository, because it locates `agents/`
and `settings.json` relative to itself. Symlink it instead of copying it — the
script resolves the symlink before working out the repo directory:

```bash
ln -s "$PWD/run-claude.sh" ~/.local/bin/run-claude
```

Then `run-claude --agent my-agent` works from any directory, and the directory
you are standing in is the one mounted at `/workspace`. Copying the file into
`~/.local/bin` instead would break the `agents/` and `settings.json` mounts.

### Mounts

| Host                                | Container                                                    |
|-------------------------------------|--------------------------------------------------------------|
| `$PWD` (the directory you run from) | `/workspace` (workdir)                                       |
| `~/.claude`                         | `~/.claude` — auth, history, projects                        |
| `~/.claude.json`                    | `~/.claude.json`                                             |
| `<repo>/agents`                     | `~/.claude/agents` (read-write, layered on top of the above) |
| `<repo>/settings.json`              | `~/.claude/settings.json` (read-write)                       |
| `~/.gitconfig`, `~/.ssh`            | same paths, **read-only** (when present)                     |

The repo's `agents/` and `settings.json` are nested mounts placed **on top of**
the host's `~/.claude`, so inside the container they shadow the host's copies. To turn that off:
`./run-claude.sh --no-agents-mount` / `--no-settings-mount`.

### `run-claude.sh` options (before the claude arguments)

```
--image <tag>        default: claude-tools:latest  (or $CLAUDE_TOOLS_IMAGE)
--workdir <path>     what to mount as /workspace (default: $PWD)
--mount <src:dst>    additional bind mount (repeatable)
--env K=V            additional environment variable (repeatable)
--network <mode>     default: bridge  (e.g. none, to run offline)
--name <name>        container name
--no-agents-mount    /  --no-settings-mount
--no-sandbox         drop the security options Claude's sandbox needs
--                   end of this script's options
```

These are forwarded automatically when set in your environment:
`ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL`,
`CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CODE_USE_VERTEX`, `TERM`, `TZ`.

## Sandbox

`settings.json` sets `sandbox.enabled: true`. On Linux, Claude's sandbox is
bubblewrap for filesystem isolation plus socat for the network filter, so both
packages are installed in the image.

Running bubblewrap *inside* Docker also needs three of Docker's own restrictions
lifted, which `run-claude.sh` passes by default:

| Option | Without it |
|---|---|
| `--security-opt seccomp=unconfined` | `bwrap: No permissions to create new namespace` — the default seccomp profile rejects `clone(CLONE_NEWUSER)` |
| `--security-opt apparmor=unconfined` | `bwrap: Failed to make / slave: Permission denied` |
| `--security-opt systempaths=unconfined` | `bwrap: Can't mount proc on /newroot/proc` — Docker's masked `/proc` paths block the remount |

No extra capability is needed: `--cap-add SYS_ADMIN` and `--privileged` make no
difference, so neither is used.

The trade-off is worth stating plainly: these options weaken Docker's own
confinement of the container in exchange for Claude's sandbox working inside it.
If you would rather keep Docker's defaults, run `./run-claude.sh --no-sandbox` and set
`"sandbox": {"enabled": false}` in `settings.json` — otherwise Claude will report
that the sandbox is enabled but cannot start.

`sandbox.filesystem.allowRead` and `permissions.additionalDirectories` are both
left empty on purpose: inside the container the code always lives at
`/workspace`, which the sandbox and `Read(./**)` already cover. Add entries there
only for paths you mount yourself with `--mount`, using the container-side path.

## Security

- The `claude` user (with your own uid/gid) is **not a sudoer**: the `sudo`
  package is never installed in the image and there is no entry in
  `/etc/sudoers`. Anything requiring root has to go into the `Dockerfile`.
- `settings.json` uses `defaultMode: "default"`. For a looser flow inside the container, change it to `"acceptEdits"` or
  run
  `./run-claude.sh --dangerously-skip-permissions`.
- `~/.ssh` is mounted read-only and is on the `deny` list in `settings.json`.

## Tooling inside the container

```bash
./run-claude.sh shell -lc 'node -v; npm -v; python -V; pyenv versions; java -version; sdk version'
```

- **npm/node** — Node 22 (NodeSource), global prefix `~/.npm-global`
- **pyenv** — `~/.pyenv` plus `pyenv-virtualenv`, default Python 3.12.7
- **SDKMAN!** — `~/.sdkman`, default Java 21 (Temurin)
- git, ripgrep, fd, jq, curl, wget, zip/unzip, build-essential
