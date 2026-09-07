# claude-tools

Containerized Claude Code with a ready-made toolchain (node/npm, pyenv, SDKMAN!)
and agents/settings version-controlled in this repository.

The container engine is **podman**, and only podman. `build.sh` and
`run-claude.sh` both require it on `PATH` and error out if it is missing, and
`run-claude.sh` additionally requires it rootless. If you were using docker, see
*Migrating from docker* below.

## Files

| File                   | Purpose                                                                   |
|------------------------|---------------------------------------------------------------------------|
| `Dockerfile`           | The image: debian + node/npm + claude + pyenv + SDKMAN! + non-sudo user   |
| `docker-entrypoint.sh` | Entrypoint — pyenv/SDKMAN!, then `exec claude`; more under `--containers` |
| `build.sh`             | Builds the image, passing through the current user's uid/gid              |
| `run-claude.sh`        | Runs the image with every mount wired up, forwarding arguments to claude  |
| `settings.json`        | User-level settings, mounted at `~/.claude/settings.json`                 |
| `agents/`              | Your agents, mounted at `~/.claude/agents`                                |

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

### Migrating from docker

Docker used to be selectable with `--engine docker` or `CONTAINER_ENGINE=docker`.
Both are gone, and there is no fallback: if that is how you were running this,
install podman and **rebuild**. A docker-built image sits in docker's store, and a
podman-only `run-claude.sh` never reads it.

None of the old invocations still means anything. The two flags say so; the
variable does not:

- `./build.sh --engine docker` forwards the unknown flag on to `podman build`,
  which rejects it with `Error: unknown flag: --engine`.
- `run-claude.sh` does not recognize `--engine` at all: it stops parsing its own
  options there and forwards the rest to `claude`, which exits with
  `error: unknown option '--engine'`. The container starts and dies immediately.
  Any `run-claude.sh` option placed after `--engine` — a `--network`, a
  `--mount` — never reaches the script. `shell` does reach the container, but
  the entrypoint only honours it in first position, and first position is
  `--engine`.
- `CONTAINER_ENGINE=docker` is ignored, and nothing says so: neither script
  reads the variable any more, so the build simply succeeds with podman.

## Run

```bash
./run-claude.sh                        # interactive claude in the current directory
./run-claude.sh --agent code-reviewer  # arguments are forwarded verbatim to claude
./run-claude.sh -p "what does this repo do?"
./run-claude.sh --dangerously-skip-permissions
./run-claude.sh shell                  # bash inside the container instead of claude
./run-claude.sh --containers           # let the agent start containers inside this one
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
| `~/.gitconfig`                      | same path, **read-only** (when present)                      |

The repo's `agents/` and `settings.json` are nested mounts placed **on top of**
the host's `~/.claude`, so inside the container they shadow the host's copies. To turn that off:
`./run-claude.sh --no-agents-mount` / `--no-settings-mount`.

### `run-claude.sh` options (before the claude arguments)

```
--image <tag>        default: claude-tools:latest
--workdir <path>     what to mount as /workspace (default: $PWD)
--mount <src:dst>    additional bind mount (repeatable)
--env K=V            additional environment variable (repeatable)
--network <mode>     default: podman's own  (e.g. none, to run offline;
                     host is refused together with --containers)
--name <name>        container name
--no-agents-mount    /  --no-settings-mount
--no-sandbox         drop the security options Claude's sandbox needs
--containers         let the agent start containers inside this one (opt-in;
                     refused with --no-sandbox and with --network host)
--                   end of this script's options
```

Three environment variables supply defaults:

| Variable               | Read by                     | Sets                                                                     |
|------------------------|-----------------------------|--------------------------------------------------------------------------|
| `CLAUDE_TOOLS_IMAGE`   | `build.sh`, `run-claude.sh` | the image tag — the default for `--tag` and `--image`                    |
| `CLAUDE_TOOLS_USER`    | `build.sh`, `run-claude.sh` | the user inside the container (`claude`) — `build.sh --user` sets it too |
| `CLAUDE_TOOLS_NETWORK` | `run-claude.sh`             | the default for `--network`; `host` is refused under `--containers`      |

`CLAUDE_TOOLS_USER` is the only way to tell `run-claude.sh`, which has no flag
for it, and it has to be the user the image was actually built with:
`run-claude.sh` derives the container-side home directory of the home-directory
mounts from it, so a mismatch puts `~/.claude` in a home that does not exist.

These are forwarded automatically when set in your environment:
`ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL`,
`CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CODE_USE_VERTEX`, `TERM`, `TZ`.

### Starting containers from inside the container

```bash
./run-claude.sh --containers
```

Off by default. With it, the agent can start containers — a repository's own
compose fixtures, a Testcontainers suite, an ad-hoc `podman run` — and they are
**children of this container**, in its mount and network namespaces. Two things
follow, and the first has a limit worth reading twice.

A spawned container can bind-mount only what exists in this container's mount
namespace. That is *not* "none of the host filesystem": it is an enumerated few
of it — the six mounts listed under *Mounts* above, plus anything you passed
with `--mount`. Five of those six are read-write, so a container the agent
starts can write to `/workspace`, to `~/.claude` and `~/.claude.json`, and,
through the nested mounts, to this repository's own `agents/` and
`settings.json` — which means it can rewrite the agent system prompts, on the
host, in this repository. Only `~/.gitconfig` is read-only.

The second: a published port lands on the same `localhost` the test process
sees, so a hard-coded `localhost:5432` and a Testcontainers `getMappedPort()`
both work with no overrides.

What the flag adds to `podman run`:

| Added | What it is for |
|---|---|
| `--cap-add=all` | without it the inner podman cannot map its subordinate id range: `newuidmap` fails and no image that drops privileges starts. A real concession — see *Security* |
| `--device /dev/fuse` | `fuse-overlayfs`, which is how the inner podman gets the `overlay` storage driver unprivileged — the image sets `driver = "overlay"` with `fuse-overlayfs` as its mount program |
| `--device /dev/net/tun` | pasta, the rootless network backend that publishes a spawned container's ports |
| `-v claude-tools-containers:/home/<user>/.local/share/containers` | the inner image store. Not merely a cache: this container's filesystem is overlayfs and `fuse-overlayfs` cannot stack on it, so the store has to sit on a real one |
| `-e CLAUDE_TOOLS_CONTAINERS=1` | what the entrypoint keys off |

The entrypoint then starts `podman system service` on **`tcp://127.0.0.1:2375`**
and waits for the port to answer. Only then does it export `CONTAINER_HOST`,
`DOCKER_HOST` — which is what Testcontainers, dockerode and docker-py read to
find the Docker-compatible API — and `TESTCONTAINERS_RYUK_DISABLED=true`,
because Testcontainers' reaper reaches the engine by bind-mounting a Docker
socket and there is no socket here. If the service does not come up, the
entrypoint prints a diagnostic, leaves those variables unset and starts Claude
anyway. Loopback TCP rather than a unix socket because Claude's sandbox blocks
AF_UNIX outright; see *Sandbox*.

Two combinations are refused outright:

- `--containers --no-sandbox`, because `--no-sandbox` drops the very
  `seccomp=unconfined` and `unmask=ALL` the inner podman needs.
- `--containers --network host` (`CLAUDE_TOOLS_NETWORK=host` included), because
  the API service is unauthenticated and the only thing keeping it private is
  this container having a network namespace of its own.

#### What works

Measured on one host, and worth knowing before you rely on it:

**compose works end to end.** An agent brought up a `compose.yaml` under
`/workspace` with an unqualified `image: postgres:16`, a second service resolved
the first by service name, the published port was reachable, and
`podman-compose down` removed everything. `down` prints
`rootless netns: kill network process: permission denied` on stderr, exits 0 and
completes the cleanup — that line is not a failure.

**Testcontainers starts containers and connects to them, then fails at
teardown.** A suite run by the agent reported
`TESTCONTAINERS-OK host=127.0.0.1 port=32949` and talked to the container;
removing it afterwards failed with the same
`rootless netns: kill network process: permission denied`, which Testcontainers
raises as an exception, so the suite exits 1. This is inherent to nested
rootless podman on this host and is not caused by anything in this repository:
it reproduces identically with and without the entrypoint's capability drop.
Nothing leaks onto the host either way — every spawned container dies with this
one.

**A suite launched by a wrapper — `make test`, `./scripts/test.sh` — stays
inside Claude's sandbox and never reaches the engine.** That is the limit of the
mechanism, not a bug; see *Sandbox*.

#### Triage

Three failures read alike, and none of them is the code under test:

| What you see | What it means |
|---|---|
| *"Could not find a valid Docker environment"* | usually the session was started **without** `--containers`, which is the default. Otherwise: the service failed to start, and the entrypoint said so on the way up and left `DOCKER_HOST` unset; or the command ran **inside** the sandbox, not being on `sandbox.excludedCommands` or having been launched by a wrapper the list cannot cover |
| `rootless netns: kill network process: permission denied` | teardown, not a test failure. From `podman-compose down` it is noise; from Testcontainers it fails the suite |
| a wait strategy that times out on a first run | the image was still being pulled. `podman --remote ps` says whether the container exists at all; the second run is fast, because the store volume keeps the image |

`./run-claude.sh --containers shell` is the diagnostic path: all three escape
hatches — `shell`, `bash` and `sh` — run before the entrypoint drops
capabilities, so the local `podman` CLI works there as well as the remote one.

Nothing reclaims the image store. It grows with every image the agent pulls, and
it is shared by concurrent sessions — images pulled by one appear in the other,
and a `podman system prune` in one removes layers the other may be using. With
no session running:

```bash
podman volume rm claude-tools-containers
```

A container that runs as **root** and writes into `/workspace` is the
well-behaved case: rootless podman maps its uid 0 back to you, so the files come
out owned by you, exactly as they do without this flag. A container that
**drops privileges** is the awkward one — it sees a workspace directory it does
not own and fails with `Permission denied`, or strands files under a host subuid
you cannot manage. Give such a container `--userns=keep-id` on the inner
`podman run`, or point it at a named volume instead of a bind mount.

## Sandbox

`settings.json` sets `sandbox.enabled: true`. On Linux, Claude's sandbox is
bubblewrap for filesystem isolation plus socat for the network filter, so both
packages are installed in the image.

Running bubblewrap *inside* podman also needs two of podman's own restrictions
lifted, which `run-claude.sh` passes by default:

| Option | Without it |
|---|---|
| `--security-opt seccomp=unconfined` | `bwrap: No permissions to create new namespace` — the default seccomp profile rejects `clone(CLONE_NEWUSER)` |
| `--security-opt unmask=ALL` | `bwrap: Can't mount proc on /newroot/proc` — podman's masked `/proc` paths block the remount |

There is no AppArmor row because there is nothing to lift: a rootless podman
container gets no AppArmor profile in the first place.

No added capability is needed for Claude's sandbox itself, so `run-claude.sh`
passes none — unless `--containers` is given, which adds `--cap-add=all` for the
inner podman. That grant breaks bubblewrap outright, and not only for podman: it
refuses to run **every** command, a bare `echo` included, with
`bwrap: Unexpected capabilities but not setuid, old file caps config?`. The
entrypoint therefore drops all three capability sets immediately before starting
Claude. Capabilities are per-process, so this costs nothing: the podman API
service was started first and keeps its own, and so do the `shell`, `bash` and
`sh` escape hatches, which all sit before the drop — which is what makes
`--containers shell` the place to debug from.

The trade-off is worth stating plainly: these options weaken podman's own
confinement of the container in exchange for Claude's sandbox working inside it.
If you would rather keep podman's defaults, run `./run-claude.sh --no-sandbox` and set
`"sandbox": {"enabled": false}` in `settings.json` — otherwise Claude will report
that the sandbox is enabled but cannot start.

`sandbox.filesystem.allowRead` and `permissions.additionalDirectories` are both
left empty on purpose: inside the container the code always lives at
`/workspace`, which the sandbox and `Read(./**)` already cover. Add entries there
only for paths you mount yourself with `--mount`, using the container-side path.

`sandbox.excludedCommands` lists the commands that run **outside** bubblewrap:
`podman`, `podman-compose`, and the test runners — Maven, Gradle,
npm/yarn/pnpm, pytest/tox/nox. That is not a convenience. On Linux Claude's
sandbox isolates the network namespace and blocks AF_UNIX at the seccomp layer,
so a sandboxed command reaches neither a unix socket nor the container's
`127.0.0.1:2375`, and no setting bridges it: `sandbox.network.allowLocalBinding`
and `sandbox.enableWeakerNetworkIsolation` had no effect, and
`sandbox.network.allowUnixSockets` exists on macOS only. Exclusion is the only
mechanism that works. The runners are on the list because it is the JVM or node
process they start that talks to the engine, not the shell command itself, and
they need matching `permissions.allow` entries as well — `autoAllowBashIfSandboxed`
only auto-approves commands that *are* sandboxed.

Its limit: a suite launched by a wrapper — `make test`, `./scripts/test.sh` —
stays sandboxed and will not reach the engine. Covering that would mean
excluding `bash` or `make`, which is the sandbox itself. What exclusion costs is
in *Security* below.

## Security

- The `claude` user (with your own uid/gid) is **not a sudoer**: the `sudo`
  package is never installed in the image and there is no entry in
  `/etc/sudoers`. Anything requiring root has to go into the `Dockerfile`.
- Podman has to be **rootless**: `run-claude.sh` refuses to run when `id -u` is 0.
  Under `sudo podman` the container's uid 0 *is* host uid 0, so anything the
  container writes through a bind mount lands on the host owned by root.
- `settings.json` uses `defaultMode: "default"`. For a looser flow inside the container, change it to `"acceptEdits"` or
  run
  `./run-claude.sh --dangerously-skip-permissions`.
- `~/.ssh` is **not** mounted: a mounted key is readable by anything running in the
  container. It also stays on the `deny` list in `settings.json`.

`--containers` is off by default, and the rest of this section is what turning
it on costs. None of it applies without the flag.

- **The container runs with `--cap-add=all`.** The capabilities apply inside the
  container's own user namespace and not on the host, so they confer no host
  privilege — but the container is materially less confined than without the
  flag, and this is the largest concession here. `--privileged` also works and
  was rejected as strictly broader. Which capability is actually the operative
  one is **not known**: `--cap-add=setuid,setgid` alone changed nothing, and
  only the full set worked. Narrowing `all` to a named set is the clearest
  improvement this threat model has available. The capabilities exist for the
  podman service, not for Claude — the entrypoint drops them before starting it,
  so Claude and everything it runs hold none. Only the escape hatches keep them:
  `--containers shell`, and equally `bash` or `sh`.
- **The commands that reach the engine run outside Claude's sandbox** —
  `podman`, `podman-compose` and the test runners, through
  `sandbox.excludedCommands`. Measured, that costs both less and more than it
  sounds. It is **not** a credential cost: reading `~/.claude/.credentials.json`
  succeeds from inside the sandbox exactly as it does outside, so exclusion
  widens nothing there. What is lost is filesystem write confinement — an
  excluded command can write outside `/workspace`, and a sandboxed one cannot.
- **Any container the agent starts is outside both the sandbox and
  `settings.json`'s deny list.** Both constrain Claude's own tools, not a
  process running in another container: anything started in one can read the
  credentials in the mounted `~/.claude`, rewrite this repository's own
  `agents/` and `settings.json` through their read-write mounts, and it has
  network. Bubblewrap still protects against an accidental `cat` in a Bash call,
  which is not nothing, but it no longer protects against a deliberate read.
  Image pulls do not reach the sandbox's network filter at all — any image, from
  any registry the container can reach.
- **The engine API on `127.0.0.1:2375` is unauthenticated.** It replaced a
  `srw------- claude claude` unix socket, which the filesystem confined to a
  single user; a port has no such gate, so anything in this container's network
  namespace can drive the engine — including a container the agent starts with
  the inner podman's own `--network host`. What keeps the port off the host is
  this container having a network namespace of its own, which is why
  `--containers` refuses `--network host`.
- **"Anything requiring root has to go into the `Dockerfile`" survives
  literally** — there is still no `sudo` — but the image now carries
  `newuidmap`/`newgidmap`, setuid-root helpers whose whole purpose is to cross a
  privilege boundary, and the agent has root inside nested user namespaces. That
  is not host root, and it is not the same claim either: rootless podman maps a
  spawned container's uid 0 to your own unprivileged host user, and a nested
  user namespace can only map ids its parent already maps.

## Tooling inside the container

```bash
./run-claude.sh shell -lc 'node -v; npm -v; python -V; pyenv versions; java -version; sdk version'
```

- **npm/node** — Node 22 (NodeSource), global prefix `~/.npm-global`
- **pyenv** — `~/.pyenv` plus `pyenv-virtualenv`, default Python 3.12.7
- **SDKMAN!** — `~/.sdkman`, default Java 21 (Temurin)
- git, ripgrep, fd, jq, curl, wget, zip/unzip, build-essential
