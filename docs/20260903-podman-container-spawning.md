# Podman-only engine and container spawning from inside the image

**Status:** Draft **Date:** 2026-09-03
**Author:** Giorgos Siggouroglou

## 1. Business context

Agents running inside the `claude-tools` container — `code-reviewer`, `developer` and `senior-dev` — need to start
throwaway containers in order to do their job. The concrete cases are a foreign repository's **existing** test suite
that uses Testcontainers or `docker compose`, and ad-hoc verification of code under development (bring up a broker,
exercise a consumer, tear it down). Today the image contains no container engine at all, so the agent reports that no
`docker` is available and the work stops at "could not run the tests".

The governing constraint on the solution is the user's own phrase: **"with podman-type safety"** — rootless, and no path
to host root. It has since been sharpened into a hard requirement: **the agent must not be able to mount host locations
into the containers it starts.**

A second, related requirement arrived with the same task: the treatment of docker is to be unified across both surfaces
— the host-side scripts and the image. Docker is to be removed entirely as an engine option; podman only.

## 2. Scope

**In scope**

- Removing docker as an engine choice from `build.sh` and `run-claude.sh` (`--engine`, `CONTAINER_ENGINE`, the fallback
  logic and every engine-conditional branch that exists solely to accommodate docker).
- Installing rootless podman inside the image, with the Docker-compatible API service started by the entrypoint.
- An opt-in flag on `run-claude.sh`, **off by default**, that grants the container what nested podman needs.
- Compose support inside the image, so a foreign repository's compose-based fixtures can be brought up and torn down.
- Persisting the in-container image store between runs, so images are not re-pulled every time.
- Documenting the options and what each one buys **inside the `Dockerfile` itself**, in the style of its existing
  numbered sections, plus the new threat model in the README.
- Teaching the three agent prompts that podman is the only engine available, and how to use it — including compose
  files that live in the repository under review and ad-hoc `podman run` when the agent judges it necessary.

**Out of scope**

- Mounting the host engine's socket into the container. Rejected on the mount requirement — see §7.
- Renaming `docker-entrypoint.sh`. It is a conventional filename, not an engine declaration; renaming it is churn across
  the `Dockerfile` and the README for no behavioural gain.
- Weakening the sandbox itself. Claude's sandbox stays enabled and the design works with it on, but two things follow
  that the original phrasing assumed away. `--cap-add=all` breaks bubblewrap outright — with it, every command inside
  the container fails, not only podman but a bare `echo` too, with *"bwrap: Unexpected capabilities but not setuid, old
  file caps config?"* — so the entrypoint drops every capability immediately before `exec claude` (§5.4). And no
  sandbox setting lets a sandboxed process reach the engine at all, so the commands that need it are listed in
  `sandbox.excludedCommands` and run outside the sandbox (§5.6). Both are part of the design rather than unstated
  assumptions.
- Enumerating supported service images. Any design that lists them in advance is wrong for this requirement.
- Resource limits (CPU/memory) on spawned containers. Rootless podman inside a container has no cgroup delegation; see
  §8.
- Restoring ssh access in a narrower form. The `~/.ssh` mount was **removed** in commit `1eabbb5`, while this analysis
  was being written. If a container ever has to reach a remote over ssh, `run-claude.sh --mount` already covers that
  case ad hoc with a dedicated key directory; designing anything beyond that is out of scope here.

## 3. Current state

**The image** (`Dockerfile`) is `debian:trixie-slim` plus, in seven commented sections: base packages including
`bubblewrap` and `socat`; Node.js from NodeSource; an unprivileged user whose uid/gid come from build args; Claude Code
via npm into a user-level prefix; pyenv; SDKMAN!; and shell initialisation exported through `BASH_ENV`. There is no
container engine and no `sudo` — the `Dockerfile` header states this outright, and the README's Security section repeats
it: *"Anything requiring root has to go into the `Dockerfile`."*

**The entrypoint** (`docker-entrypoint.sh`) initialises pyenv and SDKMAN!, offers a `shell`/`bash`/`sh` escape hatch,
and ends in `exec claude "$@"`. It starts no background processes.

**Build format.** Commit `4e35c5a` makes `build.sh` pass `--format docker` when the engine is podman, because podman
ignores the `SHELL` instruction in OCI format and the `Dockerfile` relies on it for the SDKMAN! step. See §5.2b.

**Engine selection** is duplicated in `build.sh` and `run-claude.sh`: podman if present, else docker, else error and
exit non-zero (commit `6a01eb2`). `build.sh` additionally tracks `AUTO_ENGINE` purely so it can tell the user whether
`run-claude.sh` will need `CONTAINER_ENGINE=` repeated.

**The run script** (`run-claude.sh`) mounts `$PWD` at `/workspace`, the host's `~/.claude` and `~/.claude.json`, the
repository's `agents/` and `settings.json` on top, and `~/.gitconfig` read-only. `~/.ssh` was mounted read-only until
commit `1eabbb5` removed it, leaving a comment in its place noting that `:ro` prevents writes and never reads, and that
a dedicated key should be passed with `--mount` if one is ever needed. It sets `--userns=keep-id` under rootless podman
so bind mounts keep host ownership, and leaves the network default to podman when rootless.

**The already-relaxed confinement** is in `run-claude.sh:137-165`, and it is the single most important piece of context
for this proposal. To let Claude's own bubblewrap sandbox run inside the container, the script already drops three
engine defences: `seccomp=unconfined`, `apparmor=unconfined` (skipped under rootless podman, which has no profile), and
`/proc` unmasking (`unmask=ALL` on podman, `systempaths=unconfined` on docker). The comments there are explicit about
the trade-off and about the escape hatch (`--no-sandbox`), and they already flag that under rootless podman bubblewrap
nests a user namespace inside podman's own — *"the part most likely to need `--no-sandbox` on an unusual host"*.

**Permissions** (`settings.json`) set `sandbox.enabled: true` with `autoAllowBashIfSandboxed: true`, deny reads of
`~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.docker`, `~/.netrc`, `~/.git-credentials` and friends both in `permissions.deny` and
in `sandbox.filesystem.denyRead`, and contain no `Bash(podman *)` or `Bash(docker *)` entries.

**What this repository is** is packaging: a `Dockerfile`, three bash scripts, one settings file and a directory of agent
prompts. There is no application code, no test suite and no `docs/` directory. Commit titles are imperative, sentence
case, no prefix (`Support podman as an alternative container engine`, `Default to podman, falling back to docker`).

**This section describes the repository as it stood when the analysis was written**, before any step of §9 landed:
nothing here had been built or executed, no container engine existed in that environment, and commit `a3ca3fe`, which
moved the base image to Debian 13, had never been built. Everything below is marked either as measured on the user's
host, with the reading taken, or as unmeasured.

## 4. Proposed solution

Two independent changes, delivered as separate waves.

**(1) Podman only.** Delete engine selection from both scripts. `run-claude.sh` then passes `unmask=ALL` and
`seccomp=unconfined` unconditionally, and the apparmor opt-out disappears for the rootless case. This is not a
prerequisite for (2) and lands correctly even if (2) is abandoned.

**(2) Nested rootless podman, with the daemon outside bubblewrap.** Containers started by the agent are **children of
the claude container**, not siblings on the host. Concretely:

```
host
└── rootless podman  (the user's own, unprivileged)
    └── claude-tools container            uid = host uid via --userns=keep-id
        ├── podman system service         started by docker-entrypoint.sh, PID-1 context
        │   └── postgres / rabbitmq / …   grandchildren; die with the claude container
        └── claude                        all capabilities dropped before exec
            ├── bubblewrap                Claude's sandbox, wraps every Bash call
            └── podman / mvn / gradle / npm   excluded from the sandbox (§5.6); reach
                                              the service on tcp://127.0.0.1:2375
```

Three properties follow from that shape, and together they are the whole argument for it:

- **The mount requirement is satisfied by the kernel, not by policy.** The inner podman can only bind-mount paths that
  exist in the claude container's mount namespace. The host filesystem is not one of them. No allow-list, no proxy, no
  enforcement code — the paths simply are not there.
- **`localhost` means the same thing to the test process and to the published port.** Both live in the claude
  container's network namespace, so a foreign repository's hard-coded `localhost:5432`, a Testcontainers
  `getMappedPort()`, and a container that needs to reach back into the test process all work with no overrides.
  Measured with a real Testcontainers suite, which reported `TESTCONTAINERS-OK host=127.0.0.1 port=33287` and connected
  to it. This holds for a process **outside** Claude's sandbox; a sandboxed process reaches neither the service nor a
  published port, which is why the commands that need the engine are excluded from the sandbox (§5.6).
- **Relative volumes resolve correctly.** A compose file's `./config:/etc/app` resolves against its own directory under
  `/workspace`, which exists in the same namespace.

**Why the daemon is started by the entrypoint rather than invoked by the agent.** The reason is the API, not the
sandbox: Testcontainers, dockerode, docker-py and the compose implementations all speak the Docker-compatible **API**
and never the CLI, so a service has to exist regardless. Starting `podman system service` from `docker-entrypoint.sh`,
in the PID-1 context, is simply the earliest and simplest place to put it. It is served on `tcp://127.0.0.1:2375` rather
than on a unix socket, for the reason given in §5.6 and with the cost given in §5.8.

An earlier draft justified it differently — that bubblewrap's `no_new_privs` neutralises the setuid-root
`newuidmap`/`newgidmap` helpers. **The spike refuted that diagnosis** (§5.6): `newuidmap` fails for a capability reason
that applies outside bubblewrap too, and is fixed on the outer container rather than inside. Bubblewrap *does*
additionally rule out the local CLI, but for a third reason again: after the entrypoint's capability drop (§5.4) the
local `newuidmap` has no capabilities left to use, so the service is the only interface to the engine (§5.6). That
sharpens the case for the service rather than changing it. What the sandbox does block is the *client* side: no
sandboxed process can reach the service at all, over either transport, which is why the commands that talk to it run
outside the sandbox (§5.6).

**The core of this design is now verified.** The S1 spike brought up `postgres:16` nested, watched it drop to uid 999
and report itself ready, and reached its published port from inside the claude container. See §5.10.

**The agent's interface is `podman`.** `CONTAINER_HOST` points the podman CLI at `tcp://127.0.0.1:2375`, so
`podman run …` works as a thin remote client. `DOCKER_HOST` is set to the same address — not as an engine choice, but
because Testcontainers, dockerode and docker-py inside *foreign* code read that variable and speak the
Docker-compatible API that podman's service serves.

## 5. Design detail

### 5.1 Engine selection removal

`build.sh`: drop `--engine`, `CONTAINER_ENGINE`, `AUTO_ENGINE` and `RUN_PREFIX`; require `podman` on `PATH` and error
out otherwise. `run-claude.sh`: drop `--engine`, `CONTAINER_ENGINE` and the `basename` comparisons; keep the
`ROOTLESS_PODMAN` distinction as it is today — whether rootful podman should remain supported at all is an open
question (§10), and this analysis does not settle it.

Leaving docker in `build.sh` alone would create a broken combination: `build.sh --engine docker` writes the image into
docker's store, which a podman-only `run-claude.sh` never reads.

### 5.2 Image contents

A new commented section in the `Dockerfile`, placed before the `USER` instruction because it needs root, installing:

| Package                     | What it buys                                                                     |
|-----------------------------|----------------------------------------------------------------------------------|
| `podman`                    | the engine and the `system service` that serves the Docker-compatible API        |
| `uidmap`                    | `newuidmap`/`newgidmap`, without which rootless podman cannot map a subuid range |
| `fuse-overlayfs`            | the `overlay` storage driver rootless; needs `/dev/fuse` in the outer container  |
| `passt`                     | the rootless network namespace; needs `/dev/net/tun` in the outer container      |
| `nftables`                  | netavark's packet filter; without it no user-defined network comes up            |
| `aardvark-dns`              | container-to-container name resolution on those networks                        |
| `catatonit`                 | podman's `--init` process for the containers the agent starts                    |
| a compose implementation    | see §5.5                                                                         |

`nftables` and `aardvark-dns` are `Recommends` of **netavark**, not of podman, so `--no-install-recommends` drops both,
and neither omission is cosmetic. Without `nftables` netavark cannot set up a network and errors out with
`Error: netavark: nftables error: unable to execute nft: No such file or directory`, so **no container starts on a
user-defined network at all** — which is every compose project. Without `aardvark-dns` netavark logs
`aardvark-dns binary not found, container dns will not be enabled` and continues, so containers start but cannot
resolve one another by service name.

`slirp4netns` was tried as the alternative rootless network backend and did **not** produce a working runtime in this
configuration. `passt` (pasta) is what works, and `slirp4netns` is recorded as tried and rejected rather than as an
untested second option.

Per the user's instruction, this section documents each option and what it buys **in the `Dockerfile` itself**, matching
the commentary style of sections 1-7 and of the sandbox block in `run-claude.sh`.

Also required in the same section:

- `/etc/subuid` and `/etc/subgid` entries for `${USER_NAME}`. **The ranges cannot be chosen from a desk** — they must
  lie inside the id space `--userns=keep-id` maps into the container, and must skip the build-arg uid itself. The
  customary `claude:100000:65536` is wrong here. The spike derived them arithmetically from `/proc/self/uid_map`
  (Appendix A step 3) and confirmed `claude:1002:64535` / `claude:1004:64533` on a host with uid 1001 and gid 1003 and a
  65536-wide range. The Dockerfile must compute them the same way, not hardcode these values, since they follow from
  whatever uid and gid the build args carry.
- `XDG_RUNTIME_DIR`. Rootless podman requires it and the image does not set it. Create `/run/user/${USER_UID}` owned by
  the build-arg uid and export it.
- `containers.conf` with `cgroup_manager = "cgroupfs"` (there is no systemd in the container) and `events_logger =
  "file"`.
- `storage.conf` selecting `overlay` with `mount_program = /usr/bin/fuse-overlayfs`. `driver = "overlay"` is fixed
  there; `vfs` is a manual edit of `/etc/containers/storage.conf`, not an automatic fallback (§6).
- A `registries.conf` drop-in setting `unqualified-search-registries = ["docker.io"]`. Debian ships
  `/etc/containers/registries.conf` with that key commented out, and its `shortnames.conf` carries no alias for
  `postgres`, `rabbitmq`, `redis`, `mysql` or `mongo`. Without the drop-in, a compose file saying `image: postgres:16`
  and Testcontainers' own unqualified defaults both fail with:

  ```
  Error: short-name "postgres:16" did not resolve to an alias and no unqualified-search registries are defined in
  "/etc/containers/registries.conf"
  ```

**Why the spike found none of the three.** Appendix A step 5 uses fully-qualified image names throughout and never
leaves the default network, so neither the registry search list nor netavark's helpers were ever exercised.

Package names are **confirmed present in Debian 13**, measured on the user's host on 2026-09-03 with `apt-cache policy`
inside `debian:trixie-slim`: `podman 5.4.2+ds1-2+b2`, `uidmap 1:4.17.4-2`, `fuse-overlayfs 1.14-1+b1`,
`passt 0.0~git20250503.587980c-2+deb13u1`, `slirp4netns 1.2.1-1.1`, `catatonit 0.2.1-2+b13`, `podman-compose 1.3.0-1`.
That open item is closed. The trixie base image measures **1.88 GB**, slightly smaller than the 1.96 GB bookworm one.
With podman, its dependencies and the packages above, the image measures **2.06 GB** — growth of **180 MB**, measured
on trixie.

### 5.2b Build format — a hard prerequisite

Podman **ignores the `SHELL` instruction when building in OCI format**, which breaks the SDKMAN! step in section 6 of
the `Dockerfile`. Commit `4e35c5a` makes `build.sh` pass `--format docker`. Any repository whose `Dockerfile` uses
`SHELL` cannot be built by podman in the default format, so this is a prerequisite for everything here rather than a
detail: without it the image does not build at all under a podman-only design. Validated together with `a3ca3fe` during
the spike — the Debian 13 image now builds.

### 5.3 The storage volume is not an optimisation

The claude container's own filesystem is overlayfs. `fuse-overlayfs` on top of overlayfs is not supported, so the inner
store must live on a real filesystem — a named volume. The same volume is what stops `postgres` and `rabbitmq` being
re-pulled on every run, which matters for a second reason given in §6: a first pull competing with a 60-second
Testcontainers startup timeout produces a failure that reads exactly like a broken container.

Mount: `-v claude-tools-containers:/home/<user>/.local/share/containers`. Podman's `:U` suffix, which chowns the volume
to the container user, is **not needed and is not used**. Measured on a genuinely fresh volume, first creation, with no
`:U`:

```
drwxr-xr-x 3 1001 1003 /home/claude/.local/share/containers
```

The mountpoint is already owned by the container user, because under `--userns=keep-id` the host uid maps to itself;
`:U` would additionally chown the whole image store on every run. Both paths are measured rather than reasoned: the
effective graphroot is `/home/<user>/.local/share/containers/storage`, and the named volume mounts one level above it,
on `/home/<user>/.local/share/containers`.

**The cost argument is softer than assumed.** The spike reported `Store.GraphDriverName = overlay`, so `fuse-overlayfs`
does work with `--device /dev/fuse`, and `vfs` — with its per-layer copies and slow first starts — is not reached in the
configuration this design ships: nothing selects it automatically (§6). The volume is still required, because
`fuse-overlayfs` cannot stack on the container's own overlayfs.

**The image store is shared between concurrent sessions.** The volume name `claude-tools-containers` is a constant,
while the path it mounts on is derived from `CLAUDE_TOOLS_USER`. `run-claude.sh` uses `--rm` and no `--name` by default,
so two simultaneous `--containers` sessions share one graphroot with two different runroots. Two consequences follow
from the shared graphroot alone: images pulled by one session appear in the other, and a `podman system prune` in one
removes layers the other may be using. Whether concurrent use costs anything beyond that is **unmeasured**. Recorded as
a known consequence of the design, not as a task.

### 5.4 `run-claude.sh --containers`

Default **off**. When given, it adds:

- **`--cap-add=all`** — required. See below; this is a genuine new concession.
- `--device /dev/fuse` — for `fuse-overlayfs`.
- `--device /dev/net/tun` — for pasta, which the inner podman uses for its rootless network namespace.
- the named volume of §5.3.
- `-e CLAUDE_TOOLS_CONTAINERS=1`, which is what the entrypoint keys off.

**`--cap-add=all` is a new security concession and must be described as one.** An earlier draft claimed `--containers`
needed no new security option because `seccomp=unconfined` and `unmask=ALL` were already passed. The spike refuted
that: without `--cap-add=all`, `newuidmap` fails and no image that drops privileges can start. The capabilities are
added to the *outer* container — the one Claude runs in — and they are real capabilities in that user namespace, not on
the host.

**It also breaks Claude's own sandbox, and the entrypoint is where that conflict is resolved.** With the capability set
granted, bubblewrap refuses to run anything at all — not only podman, a bare `echo` too:

```
bwrap: Unexpected capabilities but not setuid, old file caps config?
```

Measured directly, inside the container:

```
without --cap-add=all:   bwrap OK       CapEff: 0000000000000000
with    --cap-add=all:   bwrap FAILS    CapEff: 000001ffffffffff
```

The entrypoint therefore drops every capability immediately before `exec claude`, with
`setpriv --inh-caps=-all --ambient-caps=-all --bounding-set=-all`; `setpriv` comes from util-linux and is already in the
image, so this costs no new package. The podman service keeps its own capabilities, because it is started first and
capabilities are per-process. Proven end to end: the service comes up, `CapEff` is zero afterwards, bubblewrap
works, and the service still spawns containers. Nothing in this document anticipated the conflict, and it is the
sharpest interaction the design has with the sandbox.

**Narrowing it is unresolved and worth revisiting.** `--cap-add=setuid,setgid` alone changed nothing, even though
`CAP_SETUID` and `CAP_SETGID` were already present in `CapBnd` before any `--cap-add`. Only the full set worked. Which
additional capability is operative was **not** determined and is deliberately not guessed here. Moving from `all` to a
named set would be a measurable improvement to the threat model and is the obvious follow-up. It would **not** have
removed the capability drop above: bubblewrap's check is *any* capability at all while not setuid, so any non-empty
grant trips it.

`--privileged` was also tried and also worked. It is **rejected**: it is strictly broader, additionally exposing host
devices reachable by the invoking user, and it buys nothing that `--cap-add=all` does not.

If `--no-sandbox` is used, `seccomp=unconfined` and `unmask=ALL` disappear and `--containers` will not work — the two
flags are mutually exclusive in practice and the script should say so.

`--containers` is refused with **host networking** for a different reason (commit `b3a3f29`). The service listens on an
unauthenticated port, and the only thing keeping it private is the container having a network namespace of its own;
`--network host` would put that listener on the host's loopback among every other process on the machine. See §5.8.

### 5.5 Compose

Two candidates, and the choice interacts with the user's decision to remove docker:

- **`podman-compose`** (Debian package, pure Python). It does **not** talk to the socket: it `os.execlp`s the `podman`
  CLI (`podman_compose.py:1480`), and reaches the service only because the CLI itself defaults `--remote` to true when
  `CONTAINER_HOST` is set — `podman(1)` says so explicitly. Consistent with a podman-only design, no `docker` binary
  anywhere. A foreign repository whose `Makefile` calls `docker compose` will not work.
- **Docker Compose v2 plugin binary.** Restores `docker compose` for foreign code. Note the trap: the conventional
  plugin directory is `~/.docker/cli-plugins`, and `~/.docker` is on `sandbox.filesystem.denyRead` — so `DOCKER_CONFIG`
  must point elsewhere, and nothing belonging to this feature may live under `~/.docker`.

**That indirection is a triage trap.** With `CONTAINER_HOST` unset there is no socket error at all: the CLI runs
locally and dies with `newuidmap: write to uid_map failed: Operation not permitted` — the same string a too-narrow
subuid range produces, and the same one a missing `--cap-add=all` produces (§9, S5). The message alone does not
distinguish the three.

**Compose works end to end**, measured in the shipped configuration: a project under `/workspace` comes up, its
services resolve one another by name, and `podman-compose down` removes them. `down` prints the same
`rootless netns: kill network process: permission denied` line that breaks Testcontainers teardown (§5.7), but exits
**0** and completes the cleanup, so compose is unaffected in practice — the agents must be told not to read that line
as a failure (S11).

Recommendation: `podman-compose`, as the option consistent with the stated direction. Whether to additionally install
`podman-docker` so that foreign `docker` invocations resolve is an open question (§10), not a decision taken here — it
reintroduces a `docker` binary into a design whose premise is removing docker.

### 5.6 Sandbox interaction

Everything the agent runs — the build tool, the test process, the readiness polling — runs inside bubblewrap unless it
is excluded from the sandbox. Two things had to survive it, and **neither does**:

1. **The socket is not connectable from inside the sandbox.** Measured, from a sandboxed Bash call:

   ```
   dial unix /run/user/1001/podman/podman.sock: socket: operation not permitted
   ```

   Claude Code's Linux sandbox isolates the network namespace and blocks AF_UNIX at the seccomp layer. It is not a
   permission question on the inode, which is what an earlier reading of this point assumed.
2. **Loopback is not reachable either.** A sandboxed process cannot reach **any** TCP port on the *container's*
   loopback, published ports included. It can bind and connect to its **own** loopback, and that is the measurement
   that misleads: it looks like working loopback, and it is a different namespace.

Four settings were measured against the first point and none of them bridges it:

- `sandbox.filesystem.allowWrite` fixes a different and real problem — `chmod /run/user/1001/libpod: read-only file
  system` — and then reveals the socket block underneath it. It is **not** in the shipped `settings.json`: with the
  commands excluded, podman never runs under the sandbox's filesystem restrictions at all.
- `sandbox.network.allowLocalBinding: true` — no effect.
- `sandbox.enableWeakerNetworkIsolation: true` — no effect.
- `sandbox.network.allowUnixSockets` exists on **macOS only**.

**The agent therefore reaches the engine by running outside the sandbox, not by being let through it.** S9 (commit
`a25bcf3`) uses `sandbox.excludedCommands`, whose entries run outside bubblewrap: `podman`, `podman-compose`, and the
test runners — Maven, Gradle, npm/yarn/pnpm, pytest/tox/nox. The runners are on the list because §1's use case is a
foreign suite started by `mvn`, `gradle` or `npm test`, and it is the JVM or node process they start that talks to the
engine, not the shell command itself.

Excluded commands are **not** auto-approved by `autoAllowBashIfSandboxed`, which only auto-approves commands that *are*
sandboxed, so they need matching `permissions.allow` entries; S9 added `Bash(podman *)` and `Bash(podman-compose *)`.

**What exclusion costs, measured rather than assumed:**

| Probe                                      | Sandboxed                | Excluded      |
|--------------------------------------------|--------------------------|---------------|
| read `~/.claude/.credentials.json`         | **succeeds** (508 bytes) | succeeds      |
| write to `$HOME` outside `/workspace`      | blocked, read-only       | **succeeds**  |

Exclusion does not widen credential exposure: the sandbox never confined `~/.claude`, which §8 already records. What is
lost is filesystem write confinement outside `/workspace`.

**The limit of the mechanism.** A suite launched by a wrapper — `make test`, `./scripts/test.sh` — stays sandboxed and
will not reach the engine, because covering it would mean excluding `bash` or `make`, which is the sandbox itself.

One consequence cuts the other way and belongs in the threat model: because the service runs outside bubblewrap, **image
pulls are not seen by the sandbox's network filter at all.** The agent can pull any image from any registry the
container can reach.

**The earlier `no_new_privs` diagnosis was wrong, and is withdrawn.** This document previously argued that bubblewrap
neutralises the setuid-root `newuidmap`/`newgidmap` helpers, and that this was why the daemon had to live outside the
sandbox. The spike refuted it directly. In a plain container shell, **with no bubblewrap anywhere in the picture**,
`newuidmap` still failed, with:

- the setuid bits intact (`-rwsr-xr-x root root`),
- the rootfs mounted `rw,relatime` — no `nosuid`,
- `CAP_SETUID` and `CAP_SETGID` already in `CapBnd` (`00000000800405fb`),
- a subuid range correctly inside the outer mapping.

Nested user namespace creation itself is permitted: `unshare -U -r id -u` printed `0`. The cause is **capabilities on
the outer container**, and the fix is `--cap-add=all` there (§5.4) — not anything about the sandbox.

**The service is not the preferred path to the engine; it is the only one.** The question of Appendix A step 7 —
whether bubblewrap also blocks the local podman CLI — is answered, and more sharply than it was put. With
`--cap-add=all` in force bubblewrap blocks *everything* (§5.4). After the entrypoint's capability drop bubblewrap works,
and it is then the local CLI that cannot: without capabilities `newuidmap` fails with
`newuidmap: write to uid_map failed: Operation not permitted`. That is step 7's first reading — local fails, remote
succeeds — arrived at by a different route than the step assumed. So `podman` on the excluded list works as a remote
client and never as a local engine. The local CLI does still work from the `shell` escape hatch, which sits before the
drop and deliberately keeps its capabilities, so `--containers shell` remains the diagnostic path.

### 5.7 Environment exported into the container

`CONTAINER_HOST` and `DOCKER_HOST` pointing at `tcp://127.0.0.1:2375`, and for Testcontainers
**`TESTCONTAINERS_RYUK_DISABLED=true`**.

Ryuk is Testcontainers' reaper, and it reaches the engine by bind-mounting the Docker socket into itself. There is no
socket to mount, so podman tries to create the path it was asked for and cannot. Measured against the shipped TCP
configuration, a real suite failed before it started anything:

```
(HTTP code 500) making volume mountpoint for volume /var/run/docker.sock: mkdir /var/run/docker.sock: permission denied
```

With the reaper disabled the same suite proceeds. Appendix A step 8's proxy reading — Ryuk starting happily with a unix
socket bind-mounted into it, which pointed at `TESTCONTAINERS_RYUK_PRIVILEGED=true` — is **superseded**: it was run
against a transport this design no longer uses. Disabling the reaper is acceptable here because the engine itself is
ephemeral: the service is a child of the claude container, every container it started dies with it, and nothing survives
the session for a reaper to find. A durable or shared engine would owe this a second look.

`TESTCONTAINERS_HOST_OVERRIDE` is *not* needed, which is precisely the difference between this design and the rejected
one, and it is now measured rather than argued: a real suite started its container and connected to the mapped port
from inside the container, reporting `TESTCONTAINERS-OK host=127.0.0.1 port=33287`.

**Teardown is a known limitation, and it is not caused by anything in this design.** With the tests passed and the
connection made, removing the container fails:

```
(HTTP code 500) removing container ... network: 1 error occurred:
	* rootless netns: kill network process: permission denied
```

Testcontainers surfaces that as an exception, so the suite exits 1. The error reproduces identically with and without
the capability drop of §5.4 (`rc=1` both ways), so it is inherent to nested rootless podman on this host; the cause is
not established here and is deliberately not guessed. The measured boundary is: **compose works end to end;
Testcontainers starts and connects but fails at teardown.** `podman-compose down` hits the same error, exits 0 and
completes the cleanup (§5.5).

### 5.8 Entrypoint

When `CLAUDE_TOOLS_CONTAINERS=1`: create `$XDG_RUNTIME_DIR`, start `podman system service --time=0
tcp://127.0.0.1:2375` in the background, poll the port for a connection with a bounded timeout, then `exec claude` as
today. On failure it must print an explicit diagnostic naming the likely cause rather than failing silently or aborting
the container — Claude itself is still usable without it, and a silent failure produces exactly the confusing error this
design is meant to avoid.

**The API is served over TCP rather than over a unix socket** (commit `0da742b`), because no sandboxed process can
connect to a unix socket at all (§5.6). `XDG_RUNTIME_DIR` did not go with the socket: rootless podman keeps its runtime
state under it — the storage runroot, the pause process — however the API is served. What has gone is the socket file
and the directory that had to exist beneath it.

**A fixed port is safe here, and the reason is the network namespace.** `run-claude.sh` does not pass `--network=host`,
so every claude container has its own loopback. Measured: two concurrent sessions each bound `127.0.0.1:2375` at the
same time, neither saw the other's service, and nothing was bound on the host at all. There is no collision to arbitrate
and no port to allocate. `--network host` is the one mode that would end that, which is why `run-claude.sh` refuses it
under `--containers` (§5.4). 2375 is the conventional Docker API port, chosen to be recognisable on sight in a
diagnostic.

**The cost is a lost permission gate, and it belongs in the threat model.** The unix socket was `srw------- claude
claude`: the filesystem confined it to one user. A port has no such gate, so anything in the container's network
namespace can drive the engine — including a container the agent starts with the inner podman's own `--network host`.
Inside this container that is a modest change against a threat model that already accepts more (§8), but it is a real
difference rather than a wash.

**Then the capability drop of §5.4**, immediately before `exec claude` and after the `shell`/`bash`/`sh` hatch, so that
the debugging shell keeps its privilege while Claude does not. All three capability sets have to go: ambient is how the
capabilities arrive and clearing it is what empties the permitted and effective sets across the exec, inheritable is the
other route across it, and the bounding set is what stops anything downstream regaining them. The invocation is tried
against `true` first and abandoned if that fails, because clearing the bounding set needs `CAP_SETPCAP`: on the ordinary
run, without `--containers`, there is nothing to drop and `setpriv` exits 127 with
`setpriv: apply bounding set: Operation not permitted`. Aborting there would stop Claude starting at all on the commoner
of the two paths.

### 5.9 Identity and file ownership under nesting

The question this answers is whether a container the agent starts as `root` gains anything on the host. It does not,
and the reason is structural: **a nested user namespace can only map ids already mapped in its parent.** Each layer maps
its own uid 0 to the identity that started it:

```
spawned container uid 0  →  claude container uid 1000 (the claude user)  →  host uid 1000 (the invoking user)
spawned container uid N  →  claude container subuid   →  host subuid (inside the invoking user's /etc/subuid range)
```

so "root" in a spawned container terminates at the ordinary, unprivileged host user. There is no path to host uid 0,
and no file can be created on the host owned by root.

**The real consequence is ownership, and it runs the opposite way to the intuitive reading.** Under rootless podman,
container uid 0 maps to the *invoking* user, not to a subuid; the subuid range is consumed by the other container ids.
Nesting preserves that property. With a host user of uid 1000:

| Uid inside the spawned container | In the claude container  | On the host       | Files it writes into `/workspace`   |
|----------------------------------|--------------------------|-------------------|--------------------------------------|
| `0` (root)                       | `1000`, the claude user  | `1000`, the user  | owned by the user — the normal case  |
| non-root, e.g. `999`             | a mapped subuid          | a host subuid     | owned by an id the user cannot use   |

**Both rows are confirmed by observation**, not by reasoning: the ownership run of Appendix A step 6 was carried out on
the user's host (uid 1001, gid 1003). The file written by the root container appeared in the workspace owned by
`1001:1003`, the invoking user's own uid and gid; the file the uid-999 container tried to write was never created — the
`DENIED` outcome, which is the `Permission denied` half of the second row.

So a container running **as root** is the well-behaved case, and a container that **drops privileges** is the one that
strands files. The second case has a mirror-image failure that shows up first in practice: a non-root process sees a
workspace directory owned by the user as owned by `root`, and fails with `Permission denied` before it writes anything.

*Worked example, as raised during review.* `podman run -v /workspace/data:/data <minio> server /data`, with MinIO
running as root: it starts, `/workspace/data` is writable, and the objects appear on the host owned by the user's own
uid and gid. Whether that image still defaults to root **needs confirmation** —
`podman image inspect --format '{{.Config.User}}' <image>`. If it does not, the second row above applies instead.

Mitigations, in order of preference:

- For images that drop privileges, add `--userns=keep-id` to the inner `podman run`, which maps the container's uid to
  the claude user and restores both writability and sane ownership.
- Prefer **named volumes** over bind mounts into `/workspace` for anything such a container writes (database data
  directories, broker state). Read-only bind mounts of configuration are unaffected either way.
- Recovery on the host for files already stranded: `podman unshare rm -rf <path>`, which enters the user's namespace
  where those subuids are mapped. Still **unverified** — the ownership run produced no stranded file to test it on,
  because the uid-999 write was denied before it created anything.
- A blanket `userns = "keep-id"` in `containers.conf` would fix the second row globally but reintroduces the
  single-mapping problem for images that genuinely need a second id. Not proposed; recorded so the trade-off is on the
  record.

The general shape of the guidance for the agents (S11): **let containers run as root and bind-mount the workspace, or
run non-root containers against named volumes.**

**All of the above holds only because the outer podman is rootless.** Under `sudo podman` the container's uid 0 *is*
host uid 0, and a spawned container can then write root-owned files onto the host through any bind mount. That is why
`run-claude.sh` refuses to start under `sudo podman` — see §10 and S3.

### 5.10 What the S1 spike established

Run on the user's host on 2026-09-03. Everything here was **observed**, not predicted.

Environment: host uid 1001, gid 1003; `/etc/subuid` and `/etc/subgid` both `gsiggouroglou:165536:65536`; podman 5.4.2;
kernel `7.1.8+deb13-amd64`; `/proc/sys/user/max_user_namespaces` = 2147483647.

Inside the outer container under `--userns=keep-id`, with `--cap-add=all --device /dev/fuse --device /dev/net/tun`
added to the flags `run-claude.sh` already passes:

| Observation                     | Value                                                                              |
|---------------------------------|------------------------------------------------------------------------------------|
| `uid_map`                       | `0→1 (1001)`, `1001→0 (1)`, `1002→1002 (64535)`                                     |
| `gid_map`                       | `0→1 (1003)`, `1003→0 (1)`, `1004→1004 (64533)`                                     |
| derived ranges                  | `claude:1002:64535` / `claude:1004:64533`                                           |
| `newuidmap` / `newgidmap`       | `-rwsr-xr-x root root` — setuid bits intact                                          |
| rootfs mount options            | `rw,relatime` — no `nosuid`                                                          |
| `CapBnd` before any `--cap-add` | `00000000800405fb`, already including `CAP_SETUID` and `CAP_SETGID`                  |
| nested userns creation          | permitted — `unshare -U -r id -u` printed `0`                                        |
| storage driver                  | `overlay`                                                                            |
| `postgres:16` nested            | started, dropped to uid 999, logged *"database system is ready"*                     |
| published port 15432            | reachable from inside the claude container                                           |

**The core of route A is verified.** A stock image that drops privileges runs nested, and its published port is
reachable from the test process — which is exactly §5.9's claim that `localhost` means the same thing on both sides.

**`--userns=keep-id` is exonerated.** The pre-capability failure was byte-identical with and without it. It stays, since
it is what preserves sane file ownership, and it costs nothing here.

**Measured since, during implementation, and recorded in the sections that own them:** the §5.9 ownership experiment
(Appendix A step 6) and the Ryuk proxy of §5.7 (step 8) were both run, and §5.6's bubblewrap comparison was answered by
the capability conflict of §5.4. **Still unmeasured:** MinIO's default user (§10 question 5).

## 6. Failure handling and edge cases

| Condition                                                    | Behaviour                                              | User-visible result                                              |
|--------------------------------------------------------------|--------------------------------------------------------|------------------------------------------------------------------|
| `--containers` not given                                     | no service, no devices, no volume                      | agent reports the capability is off, not that the repo is broken   |
| `--containers` given together with `--no-sandbox`            | script rejects the combination                          | explicit error naming the conflict                                 |
| Inner podman cannot map subuids                              | service fails at start; entrypoint logs and continues   | named diagnostic at container start, Claude still usable           |
| `/dev/fuse` unavailable on the host                          | outer `podman run` fails before the container starts    | podman error names the device; `vfs` is manual, never automatic    |
| `/dev/net/tun` unavailable on the host                       | outer `podman run` fails the same way                   | same; `slirp4netns` is no fallback — it needs the device too       |
| Engine command not on `sandbox.excludedCommands`             | runs sandboxed; reaches neither the service nor a port   | *"Could not find a valid Docker environment"*                      |
| Suite launched by a wrapper (`make test`, `./scripts/test.sh`)| stays sandboxed; exclusion cannot cover it              | same message; the limit of the mechanism, §5.6                     |
| First pull of a large image inside the startup timeout       | wait strategy expires before the service is ready       | same timeout message as above — indistinguishable without triage   |
| Service alive but the image genuinely slow (rabbitmq ~10-20s)| wait strategy eventually succeeds                       | slow first run, then fast                                          |
| Spawned container runs as root and writes to `/workspace`    | ids map back to the invoking user                       | files owned by the user, exactly as today                          |
| Spawned container drops to a non-root uid and writes there   | `Permission denied`, or files owned by a host subuid    | fixture fails, or files the user cannot delete                     |
| Testcontainers suite tears down its containers               | container removal fails under nested rootless podman     | *"rootless netns: kill network process"*; suite exits 1 (§5.7)     |
| `podman-compose down` after a compose run                    | same error on stderr, exit 0, cleanup completes          | nothing to do; the agents are told not to read it as a failure     |
| Agent leaves containers running                              | they die with the claude container (`--rm`)             | no host residue; the store volume keeps images only                |
| Store volume grows unbounded                                 | not reclaimed automatically                             | documented `podman volume rm claude-tools-containers` in README    |

Four rows in the middle all surface as one of two messages. The README must carry a triage note distinguishing them: a
command that ran sandboxed → *"could not find a valid Docker environment"*; everything else → *"timed out"*, separated
by whether `podman --remote ps` lists the container at all, and whether its log shows the service listening.

## 7. Alternatives considered

**Decision:** nested rootless podman inside the claude container, with the API service started by the entrypoint.

**Considered — mounting the host engine's socket (siblings).** Simple, near-zero image cost, very likely to work first
time. Rejected on the mount requirement: the Docker and Podman APIs have **no mount allow-list**, so preventing
`-v /:/host` would require a proxy that inspects the body of every `POST /containers/create`. That is a bespoke security
component to build and maintain, and it is the "monster" this task is explicitly trying not to create. Independently,
the route fails the functional case that justifies it: published ports and bind mounts resolve on the **host**, so a
foreign repository's hard-coded `localhost:5432` and its relative `volumes:` entries break, and a container cannot reach
back into the test process at all. `TESTCONTAINERS_HOST_OVERRIDE` repairs only what flows through the Testcontainers
API, and we cannot patch a foreign repository's own test configuration. The remaining repair — `--network=host` for the
claude container — is a larger concession than the socket mount itself. A rootful `docker.sock` is a full host-root
escape and is out of the question under "podman-type safety".

**Considered — single-id mapping (`vfs` plus `ignore_chown_errors`).** Would let podman run inside bubblewrap without
subuids and remove the service entirely. Rejected because `postgres` and `rabbitmq` both drop privileges to uid 999,
which is unmapped in that mode, so the images the requirement is actually about would not start. Retained only as the
storage-driver fallback of §5.2, not as an id-mapping strategy.

**Considered — requiring `--no-sandbox`.** Would collapse the design to packages plus two devices. Rejected: the user
confirmed the feature must work with Claude's sandbox active. Recorded because it remains the fallback if S1 fails.

**Considered — baking services into the image, or a sidecar started by `run-claude.sh`.** Both were live options while
the requirement looked like "a PostgreSQL for tests". Both are ruled out by the confirmed requirement: the image,
version and topology are dictated by the repository under test, and any design that enumerates services in advance is
wrong for this use case.

## 8. Risks and impact

**The load-bearing assumption is now verified.** The S1 spike brought up a stock `postgres:16` nested under
`--userns=keep-id` and reached its published port from inside the claude container (§5.10). The risk that the whole
approach is impossible on this host is closed.

**Security promises that stop being true.** The user has accepted these knowingly; they are recorded so the acceptance
is on the record.

- **The container now runs with `--cap-add=all`.** This is the most significant new concession and it was not
  anticipated: the design was drafted believing `--containers` needed no security option beyond those already passed
  for Claude's sandbox, and the spike refuted that. The capabilities apply inside the container's user namespace, not
  on the host, so they do not confer host privilege — but the outer container is materially less confined than before,
  and `run-claude.sh` grants this only under `--containers`. `--privileged` was rejected as strictly broader. The
  capabilities exist for the podman service, not for Claude: the entrypoint drops all of them before `exec claude`
  (§5.4), so Claude and everything it runs hold none, and only the `shell` escape hatch keeps them.
  Which single capability is actually required is **unknown**; narrowing `all` to a named set is the clearest available
  improvement to this threat model and should be treated as a follow-up rather than forgotten.
- The README's *"Anything requiring root has to go into the `Dockerfile`"* survives literally — there is still no `sudo`
  — but the image gains `newuidmap`/`newgidmap`, setuid-root helpers whose whole purpose is to cross a privilege
  boundary, and the agent gains root inside nested user namespaces. Not host root; not the same claim either.
- **Any container the agent starts runs outside both `settings.json`'s deny list and bubblewrap.** It can read the
  credentials in the mounted `~/.claude`, and it has network. The deny entries for `~/.ssh` and friends constrain
  Claude's own tools, not a process the agent starts in a container. Bubblewrap still protects against *accidental*
  access — a stray `cat` in a Bash call — which is not nothing, but it no longer protects against deliberate access.
- **The engine API is served on an unauthenticated TCP port**, where it was a `srw------- claude claude` unix socket
  (§5.8). The filesystem gate is gone, so anything in the container's network namespace can drive the engine —
  including a container the agent starts with the inner podman's own `--network host`. What keeps that port off the
  host is the claude container having a network namespace of its own, which is why `--containers` refuses host
  networking.
- **The commands that reach the engine run outside Claude's sandbox** — `podman`, `podman-compose` and the test
  runners, through `sandbox.excludedCommands` (§5.6). Measured, that costs less than it sounds: reading
  `~/.claude/.credentials.json` succeeds sandboxed just as it does excluded, so exclusion widens no credential
  exposure. What is lost is filesystem write confinement outside `/workspace`, which a sandboxed command has and an
  excluded one does not.
- Image pulls bypass the sandbox's network filter entirely (§5.6).
- `~/.ssh` is no longer mounted at all (`1eabbb5`), so the largest instance of this exposure is already closed. The
  `deny` entries for it remain in `settings.json` as defence in depth. `~/.gitconfig` is still mounted read-only and is
  readable by any container the agent starts; it holds no secret unless the user has put one there.

**The mount requirement, stated precisely.** The agent cannot mount *arbitrary* host paths. It can mount the paths the
claude container was already given, now three paths: `/workspace`, `~/.claude`, and `~/.gitconfig` (read-only).
`/workspace` being mountable is required — compose fixtures depend on it. `~/.claude` is the one that matters, and its
exposure is accepted above.

**No escalation to host root, and the ownership hazard is narrower than it first appears.** §5.9 sets out why a spawned
container cannot reach host uid 0 under rootless podman. Containers running as root write files owned by the user, as
today. Only containers that drop privileges strand files under a host subuid or fail outright on a workspace bind mount.
That is the practical cost of this design and belongs in the README.

**Backward compatibility.** Removing docker is a breaking change for anyone running `CONTAINER_ENGINE=docker` or
`--engine docker`; they must install podman and rebuild, since a docker-built image is not in podman's store. The README
must say so. `--containers` defaults to off, so existing invocations are otherwise unaffected.

**`build.sh` has no root guard, while `run-claude.sh` does.** S3 makes `run-claude.sh` refuse to run as root; `build.sh`
has no equivalent check, so `sudo ./build.sh` succeeds and writes the image into root's store, which the root-refusing
`run-claude.sh` will never read — the same broken combination §5.1 rules out for a docker-built image. Left as it
stands, by decision; recorded as a known gap rather than a task.

**A pre-existing image defect, unrelated to this design.** In a **login** shell — which is what
`./run-claude.sh shell -lc '…'` gives, and what the README's own tooling example uses — Debian's `/etc/profile` resets
`PATH`, and `~/.claude-tools-env.sh` re-prepends `$PYENV_ROOT/bin` but not `$PYENV_ROOT/shims`. Measured: `python3` is
the system 3.13.5 in a login shell and pyenv's 3.12.7 in a non-login one, while section 7 of the `Dockerfile` comments
that the shims are already on `PATH`. It predates this work and is being fixed in a separate commit; recorded so the
discrepancy is on the record.

**Operational cost.** Image growth of **180 MB**, measured on trixie: 1.88 GB to 2.06 GB. A named volume that grows
with every image the agent pulls and is never reclaimed automatically, shared between concurrent sessions (§5.3).
First-run latency dominated by pulls. No cgroup delegation inside the container, so spawned containers run without
resource limits — a runaway test fixture is bounded only by the claude container's own limits.

**Testability.** There is no test suite in this repository and this change does not create one. Verification is manual,
which is a real weakness; §5.6 and the spike exist to make it repeatable rather than ad hoc.

## 9. Implementation algorithm

| #   | Step                                        | Files / area                          | Commit title                                      | Depends on     | Done when                                                                 |
|-----|---------------------------------------------|---------------------------------------|---------------------------------------------------|----------------|---------------------------------------------------------------------------|
| S1  | Spike nested podman on a real host **(done)**| this document                          | `Record the nested podman spike results`           | —              | done — results in §5.10; nesting verified, `--cap-add=all` found necessary |
| S2  | Drop docker from the build script            | `build.sh`                             | `Remove the docker engine option from build.sh`    | —              | `--engine`/`CONTAINER_ENGINE`/`AUTO_ENGINE` gone; missing podman errors    |
| S3  | Drop docker, require rootless podman         | `run-claude.sh`                        | `Remove the docker engine option from run-claude.sh`| —             | engine branches gone; `unmask=ALL` unconditional; rootful refused          |
| S4  | Document the podman-only engine              | `README.md`                            | `Document the podman-only engine in the README`    | S2, S3         | sandbox table rewritten for podman; migration note for docker users        |
| S5  | Install podman and its config in the image   | `Dockerfile`                           | `Install rootless podman in the image`             | S1             | image builds; subuid ranges computed from build args; options commented in file |
| S6  | Start the API service from the entrypoint    | `docker-entrypoint.sh`                 | `Start the podman API service from the entrypoint` | S5             | service listening; `podman --remote info` succeeds; failure logs a diagnostic|
| S7  | Add the opt-in flag                          | `run-claude.sh`                        | `Add --containers to run-claude.sh`                | S5             | flag adds `--cap-add=all`, both devices, volume, env; `--no-sandbox` refused|
| S8  | Add compose support                          | `Dockerfile`                           | `Add compose support inside the image`             | S5, S6, S7     | a compose file under `/workspace` comes up and down from `--containers shell` |
| S8a | Drop capabilities before starting claude **(done)** | `docker-entrypoint.sh`           | `Drop capabilities before starting claude`         | S7             | done — `13d5c67`; bubblewrap runs under `--cap-add=all`, `CapEff` zero      |
| S8b | Serve the API over loopback TCP **(done)**   | `docker-entrypoint.sh`                 | `Serve the podman API over loopback TCP`           | S6             | done — `0da742b`; service on `tcp://127.0.0.1:2375`, env points at it       |
| S8c | Refuse host networking under `--containers` **(done)** | `run-claude.sh`              | `Refuse --containers with host networking`         | S8b            | done — `b3a3f29`; `--containers --network host` errors out                 |
| S9  | Let the agent reach the engine               | `settings.json`                        | `Allow the agent to reach the container engine`    | S8b            | done — `a25bcf3`; engine commands and test runners excluded from the sandbox|
| S10 | Document the capability and its threat model | `README.md`                            | `Document container spawning and its threat model` | S6, S7, S8, S9 | `--cap-add=all` concession stated; triage note; volume cleanup documented  |
| S11 | Teach the three agents the capability        | `agents/` — three prompts              | `Teach the agents to use podman`                   | S6, S7         | three prompts updated; guidance tailored per role; README note added       |
| S12 | Version bump                                 | `Version.txt`                          | `v1.2.0`                                           | S10, S11       | version reflects the released change                                       |

**Parallelization:** Wave 1: S1 *(done)*, S2, S3 · Wave 2: S4 (needs S2, S3), S5 (needs S1) · Wave 3: S6, S7 (need
S5) · Wave 4: S8, then S8a, S8b, S8c and S9 in that order, each needing the one before · Wave 5: S10, S11 (independent
of each other) · Wave 6: S12

With S1 landed, the two chains can now run fully in parallel: the podman-only chain (S2 → S3 → S4) and the spawning
chain (S5 → S6/S7 → S8 → …) share no files and no ordering.

**Step detail**

- **S1** is manual and time-boxed at roughly 45 minutes, most of it image builds. The executable procedure is
  **Appendix A**; it runs against the repository exactly as it stands, with no `--containers` flag and no podman in the
  image. The commit records the observed answers in §5.2, §5.6, §5.7, §5.9 and §10. Nothing else may start until it
  lands, and one reading in Appendix A step 5 decides whether S5 onward happens at all.
- **S3** also removes the `ROOTLESS_PODMAN` distinction outright: the script now errors when `id -u` is 0, so the
  rootful branches for apparmor and the default network have nothing left to guard.
- **S5** carries the commentary requirement: each package and each config choice documented in the `Dockerfile`, in the
  style of its existing numbered sections. The `/etc/subuid` and `/etc/subgid` entries must be **computed** from the
  build-arg uid and gid, following the arithmetic in Appendix A step 3 — not hardcoded to the values §5.2 records.
  **`podman info` is not an S5 criterion.** It needs `--cap-add=all`, which S7 adds; run at S5 it fails with
  `newuidmap: write to uid_map failed: Operation not permitted`. S7 is the first step at which it is verifiable, from
  the `--containers shell` hatch.
- **S7** must add `--cap-add=all` alongside the two devices. This is a security concession, so the flag's help text and
  the comment beside it say what it buys and what it costs, in the manner of the existing sandbox block.
- **S8** is listed after S6 and S7 rather than beside them: its criterion is a compose project actually coming up, which
  needs the service (S6) and the capability and devices (S7) as well as the packages (S5).
- **S8a, S8b and S8c were not in the original plan**, and each is forced by a measurement the plan had no way to
  anticipate: the capability grant of S7 breaks bubblewrap and has to be dropped before `exec claude` (§5.4); no
  sandboxed process can connect to a unix socket, so the API moved to loopback TCP (§5.6, §5.8); and an unauthenticated
  port is only private while the container has a network namespace of its own, so host networking had to be refused
  (§5.8). They are listed here because a plan that omits three landed commits misleads the next reader.
- **S9** turned out to need the opposite of what it was scoped for. No sandbox setting opens the socket or the container
  loopback (§5.6), so the step shipped as `sandbox.excludedCommands` — the engine commands and the test runners running
  *outside* the sandbox — plus the `permissions.allow` entries they need because `autoAllowBashIfSandboxed` does not
  cover them.
- **S11** touches `agents/code-reviewer.md`, `agents/developer.md` and `agents/senior-dev.md`. The **shared substance**
  is identical in all three: podman is the only engine and `docker` does not exist; a repository's compose file is
  brought up from its own directory under `/workspace` and torn down afterwards; containers run as root against a
  workspace bind mount, or non-root against named volumes (§5.9); and the two-timeout triage of §6, so that a sandbox
  or pull problem is never reported as a defect in the code under test. It also has to carry the two teardown readings:
  `podman-compose down` prints `rootless netns: kill network process: permission denied` and still succeeds, so that
  line is not a failure (§5.5), while a Testcontainers suite fails at teardown for the same reason and exits 1 (§5.7).

  **Kept as three tailored copies, not one shared file, and the reason is mechanical.** `agents/README.md` documents the
  directory format for a human reader; it is not loaded into any agent's context — Claude Code reads the agent `.md`
  files as system prompts and nothing else in the directory. An agent cannot follow a reference to a file it never
  sees. Duplication is also already this repository's convention: the "Language" and "Technology-agnostic" paragraphs
  appear near-verbatim in `senior-dev.md`, `developer.md` and `tech-analyst.md`. The maintenance cost is acknowledged
  and paid down with a short note in `agents/README.md` — addressed to the maintainer, not the agents — recording that
  the container guidance is duplicated across the three files and must be changed together.

  **What differs by role**, and is the reason a single blob would be wrong:
  - `code-reviewer` reports and never fixes. Its copy stresses accurate reporting when the capability is off (the
    existing "Report what you could not check" hook), and tearing down whatever it started.
  - `developer` implements one step and hands an uncommitted tree to the tech-lead. Its copy stresses that no container
    artefact may be left in the working tree — stranded subuid-owned files (§5.9) would corrupt that handoff.
  - `senior-dev` goes all the way to a commit. Its copy stresses the same, plus never committing files a container
    created: data directories, volume leftovers, compose state.

## 10. Open questions

| # | Question                                                                                      | Who answers | Blocks |
|---|-----------------------------------------------------------------------------------------------|-------------|--------|
| 1 | Which capability does `--cap-add=all` actually supply? `setuid,setgid` alone was not enough      | measurement | none   |
| 5 | Does the MinIO image in use still default to root? `podman image inspect --format '{{.Config.User}}'` | measurement | S11 |

Questions 2, 3, 4 and 6 have been answered and moved to the list below; the numbering keeps its gaps so that the
references from Appendix A stay valid. **Question 1 is still the one worth chasing**: narrowing `--cap-add=all` to a
named set is the clearest available improvement to the threat model, and it is not on the critical path. It would
**not** have avoided the capability drop of §5.4 — bubblewrap's check is *any* capability at all while not setuid, so
any non-empty grant trips it, and the drop would have been required either way. Nothing open blocks a step: S9 has
landed, and question 5 affects only the wording of the agent guidance in S11.

**Resolved during review and implementation, recorded for traceability:**

- `agents/code-reviewer.md`, `agents/developer.md` and `agents/senior-dev.md` are all in scope (S11). `senior-dev`
  was added because it takes a small task end to end and hits the same wall when a task needs a container to verify
  against.
- `run-claude.sh` **refuses rootful podman**: it errors out when `id -u` is 0. Every safety property in §5.9 depends on
  the outer podman being rootless — under `sudo podman` a spawned container writes root-owned files onto the host
  through any bind mount. This also removes the last engine-conditional branch from the script. Cost: anyone relying on
  `sudo podman` can no longer run the image. Folded into S3.
- **`podman-docker` will not be installed.** The agent is told only podman exists and runs the repository's compose file
  itself, so the shim buys nothing; it would only matter for a repository whose own script shells out to `docker`.
  Folded into S8.
- The **first spike run (2026-09-03) was void** — three defects in Appendix A, since fixed. A corrected run the same
  day **succeeded**: nested rootless podman works, `postgres:16` starts and its published port is reachable, and
  `--cap-add=all` is required. Full record in §5.10.
- The Debian 13 package versions and `max_user_namespaces` are confirmed; the image builds on trixie after `4e35c5a`.
  Image growth is measured on trixie at **180 MB** (1.88 GB to 2.06 GB), closing the last item of §5.2.
- **Question 2 — bubblewrap and the local podman CLI — is answered, and more sharply than it was asked.** With
  `--cap-add=all` in force bubblewrap blocks everything; after the entrypoint's capability drop bubblewrap works and the
  local CLI is the thing that cannot, because `newuidmap` has no capabilities left. The service is therefore the only
  interface to the engine — Appendix A step 7's first reading — while the local CLI still works from the `shell` hatch,
  which keeps its capabilities. §5.4 and §5.6. This says nothing about whether a sandboxed process can reach the
  service; that is question 3, resolved separately below.
- **Question 3 is answered, and the answer is that no sandbox setting bridges the gap.** `sandbox.filesystem` does
  support a write allowance — `allowWrite` — and it fixes a real but different problem
  (`chmod /run/user/1001/libpod: read-only file system`), revealing the socket block underneath. Claude Code's Linux
  sandbox isolates the network namespace and blocks AF_UNIX at the seccomp layer; `allowLocalBinding` and
  `enableWeakerNetworkIsolation` have no effect, and `allowUnixSockets` is macOS-only. S9 therefore shipped as
  `sandbox.excludedCommands`, and `allowWrite` is not in the settings file at all. §5.6.
- **Question 4 is answered: `TESTCONTAINERS_RYUK_DISABLED=true`.** Appendix A step 8's proxy pointed the other way —
  Ryuk started happily with a unix socket bind-mounted into it — but it was run against a transport this design no
  longer uses, and it is superseded. Measured against the shipped TCP service, a real suite fails before it starts
  anything with `mkdir /var/run/docker.sock: permission denied`, because Ryuk bind-mounts the socket path. Disabling
  the reaper is acceptable because the engine is ephemeral and dies with the claude container. §5.7.
- **Question 6 is answered: the §5.9 table is confirmed by observation.** The root container's file appeared owned by
  `1001:1003`, the invoking user's own uid and gid; the uid-999 container's file was never created — the `DENIED`
  outcome. Both rows hold, and the recovery command for stranded files remains unverified because no file was stranded.
  §5.9.
- The `~/.ssh` mount has been **removed** in commit `1eabbb5`, in a separate change while this analysis was being
  written. `~/.gitconfig` remains mounted read-only by the user's choice. Nothing in this plan depends on either.

## Appendix A — Spike procedure (S1)

**Status: run, and successful.** The results are in §5.10. Steps 6 and 8 were run later, during implementation, and
step 7's question was answered by the capability conflict of §5.4 — see §10. The procedure is kept because steps 1 to 5
are the reproduction anyone needs when S5 and S7 are revisited.

Two hard-won lessons are baked into the form below, and both cost a wasted run:

- **Never paste a long multi-flag `podman run` into a terminal.** Two commands were mangled that way — one lost `$mode`
  inside a loop, another was truncated to its tail. Every multi-flag invocation here is written to a script file with a
  here-doc and then executed.
- **Always qualify the image as `localhost/`.** With both `docker.io/library/claude-tools:latest` and
  `localhost/claude-tools:latest` present, an unqualified `FROM claude-tools:latest` resolved to the docker.io one and
  silently built on a stale bookworm base. Every reference below carries the `localhost/` prefix.

### Step 1 — rebuild and verify the base image

A stale base invalidates everything downstream.

```
./build.sh
podman run --rm localhost/claude-tools:latest shell -lc \
  'grep VERSION_CODENAME /etc/os-release; echo "user=$(id -un) uid=$(id -u) gid=$(id -g)"'
```

Expected, and observed on 2026-09-03: `VERSION_CODENAME=trixie`, `user=claude`. **If the codename is not `trixie`, stop
and rebuild.** Note that `build.sh` must pass `--format docker` (commit `4e35c5a`) or the SDKMAN! step fails, because
podman ignores `SHELL` in OCI format — see §5.2b.

### Step 2 — host facts

```
id -u; id -g
grep "^$(id -un):" /etc/subuid /etc/subgid
podman --version; uname -r
cat /proc/sys/user/max_user_namespaces
ls -l /dev/fuse /dev/net/tun
```

**If `/etc/subuid` has no entry for you, stop** — rootless podman is not set up on this host. Observed values are in
§5.10.

### Step 3 — measure the outer mapping and derive the ranges

Against the **plain** image: this is the mapping `--userns=keep-id` gives the outer container, and it is not observable
from inside the spike image. Look at it by eye first:

```
cat > "$TMPDIR/map.sh" <<'EOF'
podman run --rm --userns=keep-id localhost/claude-tools:latest \
  shell -lc 'cat /proc/self/uid_map; echo ---; cat /proc/self/gid_map'
EOF
bash "$TMPDIR/map.sh"
```

Columns are `inside outside count`. Let `U` be the container-side uid of the image user — the left-hand column of the
line whose count is `1` — and `TOTAL` the sum of the `count` column, the number of container-side ids that exist at all.
The inner range starts just above `U` and runs to the end of what is mapped:

```
START = U + 1
COUNT = TOTAL - START
```

Observed on the user's host: `uid_map` of `0→1 (1001)`, `1001→0 (1)`, `1002→1002 (64535)`, so `TOTAL = 65537`,
`START = 1002`, `COUNT = 64535` → `claude:1002:64535`; and `claude:1004:64533` for gids.

**Compute it rather than typing it.** This is the gate — nothing below accepts a hand-entered value:

```
cat > "$TMPDIR/derive.sh" <<'EOF'
set -eu
IMG=localhost/claude-tools:latest
read -r SPIKE_USER SPIKE_UID SPIKE_GID < <(
  podman run --rm --userns=keep-id "$IMG" shell -lc 'echo "$(id -un) $(id -u) $(id -g)"')
UID_TOTAL=$(podman run --rm --userns=keep-id "$IMG" shell -lc 'cat /proc/self/uid_map' | awk '{t+=$3} END{print t}')
GID_TOTAL=$(podman run --rm --userns=keep-id "$IMG" shell -lc 'cat /proc/self/gid_map' | awk '{t+=$3} END{print t}')
SPIKE_SUBUID="$((SPIKE_UID + 1)):$((UID_TOTAL - SPIKE_UID - 1))"
SPIKE_SUBGID="$((SPIKE_GID + 1)):$((GID_TOTAL - SPIKE_GID - 1))"
[ -n "$SPIKE_USER" ] && [ "${SPIKE_SUBUID##*:}" -gt 1000 ] && [ "${SPIKE_SUBGID##*:}" -gt 1000 ] \
  || { echo "STOP: ranges not derived - do not build"; exit 1; }
printf 'export SPIKE_USER=%s SPIKE_UID=%s SPIKE_GID=%s\n' "$SPIKE_USER" "$SPIKE_UID" "$SPIKE_GID"
printf 'export SPIKE_SUBUID=%s SPIKE_SUBGID=%s\n' "$SPIKE_SUBUID" "$SPIKE_SUBGID"
EOF
bash "$TMPDIR/derive.sh" > "$TMPDIR/spike.env" && cat "$TMPDIR/spike.env" && . "$TMPDIR/spike.env"
export SPIKE_IMAGE=localhost/claude-tools:spike SPIKE_VOL=claude-tools-spike-store REPO="$PWD"
```

**`SPIKE_USER` must be the in-container name, not your host login.** That mismatch invalidated the first run.

### Step 4 — build a scratch image

Not committed. A throwaway layer over the real image, because the image has no sudo.

```
cat > "$TMPDIR/Dockerfile.spike" <<'SPIKE'
FROM localhost/claude-tools:latest
ARG SPIKE_USER=claude
ARG SPIKE_UID=1000
ARG SPIKE_GID=1000
ARG SPIKE_SUBUID
ARG SPIKE_SUBGID
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
        podman uidmap fuse-overlayfs passt slirp4netns catatonit podman-compose \
    && rm -rf /var/lib/apt/lists/*
RUN echo "${SPIKE_USER}:${SPIKE_SUBUID}" > /etc/subuid \
 && echo "${SPIKE_USER}:${SPIKE_SUBGID}" > /etc/subgid \
 && mkdir -p "/run/user/${SPIKE_UID}" \
 && chown "${SPIKE_UID}:${SPIKE_GID}" "/run/user/${SPIKE_UID}"
USER ${SPIKE_UID}:${SPIKE_GID}
ENV XDG_RUNTIME_DIR=/run/user/${SPIKE_UID}
SPIKE

cat > "$TMPDIR/build-spike.sh" <<'EOF'
set -eu
podman build --format docker -f "$TMPDIR/Dockerfile.spike" \
  --build-arg SPIKE_USER="$SPIKE_USER" \
  --build-arg SPIKE_UID="$SPIKE_UID" \
  --build-arg SPIKE_GID="$SPIKE_GID" \
  --build-arg SPIKE_SUBUID="$SPIKE_SUBUID" \
  --build-arg SPIKE_SUBGID="$SPIKE_SUBGID" \
  -t "$SPIKE_IMAGE" "$REPO"
EOF
bash "$TMPDIR/build-spike.sh"
```

**Verify the entry before going further** — this single check would have caught the first run's defect:

```
podman run --rm "$SPIKE_IMAGE" shell -lc \
  'echo "I am $(id -un)"; echo "-- subuid"; cat /etc/subuid; echo "-- subgid"; cat /etc/subgid; podman --version'
podman images --format '{{.Repository}}:{{.Tag}} {{.Size}}' | grep -E 'claude-tools:(latest|spike)'
```

Expected: the name after `I am` is **identical** to the name at the start of both files, and podman reports 5.4.x. If
the names differ, `SPIKE_USER` is wrong and every reading below is a false negative. **Record the size difference** —
that is the image-growth figure of §5.2, measured on trixie at +180 MB.

### Step 5 — the working configuration

The flags below are the ones that worked. `--cap-add=all` is **required**: without it `newuidmap` fails and no image
that drops privileges can start, regardless of bubblewrap (§5.6).

```
cat > "$TMPDIR/run-spike.sh" <<'EOF'
set -eu
podman run --rm -it --init \
  --userns=keep-id \
  --security-opt seccomp=unconfined \
  --security-opt unmask=ALL \
  --cap-add=all \
  --device /dev/fuse --device /dev/net/tun \
  -v "$REPO:/workspace" \
  -v "$HOME/.claude:/home/$SPIKE_USER/.claude" \
  -v "$HOME/.claude.json:/home/$SPIKE_USER/.claude.json" \
  -v "$SPIKE_VOL:/home/$SPIKE_USER/.local/share/containers" \
  --workdir /workspace \
  "$SPIKE_IMAGE" shell
EOF
bash "$TMPDIR/run-spike.sh"
```

Inside that shell:

```
podman unshare cat /proc/self/uid_map
podman info --format '{{.Store.GraphDriverName}}'
podman run -d --rm --name pg -e POSTGRES_PASSWORD=x -p 15432:5432 docker.io/library/postgres:16
podman logs -f pg          # "database system is ready to accept connections", then Ctrl-C
(exec 3<>/dev/tcp/127.0.0.1/15432) && echo PORT-REACHABLE
podman rm -f pg
```

Observed: multiple mapping lines, `overlay`, postgres ready as uid 999, `PORT-REACHABLE`.

**If any of that regresses, check three things before concluding the design fails.** The first run failed on all three
and produced a false negative:

1. **Username mismatch.** `podman run --rm "$SPIKE_IMAGE" shell -lc 'id -un; head -1 /etc/subuid'` — must be the same
   string.
2. **Stale or wrongly-resolved base.** Check `VERSION_CODENAME` in `/etc/os-release` and `podman --version` inside.
   Expect `trixie` and podman 5.4.x, and check the `localhost/` prefix.
3. **Range outside the outer mapping**, or `--cap-add=all` omitted. Compare `/etc/subuid` against step 3's `uid_map`.

### Step 6 — ownership *(run — §10 question 6 answered)*

Validates the table in §5.9. In the spike shell:

```
mkdir -p /workspace/spike-data
podman run --rm -v /workspace/spike-data:/data docker.io/library/alpine sh -c 'id -u; touch /data/as-root'
podman run --rm --user 999 -v /workspace/spike-data:/data docker.io/library/alpine \
  sh -c 'id -u; touch /data/as-999 || echo DENIED'
podman image inspect --format '{{.Config.User}}' quay.io/minio/minio      # §10 question 5
```

Then, **on the host**, in the repository: `ls -ln spike-data`.

Expected: `as-root` owned by your own uid and gid; `as-999` either absent with `DENIED`, or present and owned by a host
subuid you cannot manage. Anything else refutes §5.9 and that section must be rewritten. Clean up with
`podman unshare rm -rf spike-data`, recording whether it was needed and whether it worked.

Observed: `as-root` owned by `1001:1003`, the invoking user's own uid and gid; `as-999` absent — the `DENIED` outcome,
so `podman unshare` was not needed and the recovery command is still unverified. §5.9 holds.

### Step 7 — the bubblewrap comparison *(answered — §10 question 2)*

This no longer decides whether the service exists — §4 justifies that on the API — but it decides whether the agent can
usefully run `podman` locally as well as remotely. In the spike shell:

```
podman system service --time=0 "unix://$XDG_RUNTIME_DIR/podman/podman.sock" &
export DOCKER_HOST="unix://$XDG_RUNTIME_DIR/podman/podman.sock"
export CONTAINER_HOST="$DOCKER_HOST"
podman --remote info --format '{{.Store.GraphDriverName}}'

cp /workspace/settings.json "$HOME/.claude/settings.json"
claude -p 'Run the shell command `podman info --format {{.Store.GraphDriverName}}` and paste its exact output.'
claude -p 'Run the shell command `podman --remote info --format {{.Store.GraphDriverName}}` and paste its exact output.'
```

Readings:

- **Local fails, remote succeeds** — the service is what the agent must use. S6 as designed. Whether the sandbox
  permits a client to reach that service is a separate question, and does not follow from this reading; see the outcome
  below and §10 question 3.
- **Both succeed** — bubblewrap blocks neither. The agent may use the CLI directly; the service still exists for
  Testcontainers.
- **Both fail** — the sandbox blocks the socket too. §10 question 3 is answered *no* and S9 has real work; capture the
  exact error, since it determines whether `settings.json` can express the allowance at all.

Outcome: the first reading, though by a route the step did not anticipate — the local CLI fails because the entrypoint
drops the capabilities `newuidmap` needs, and bubblewrap cannot run at all while they are held (§5.4, §5.6). The service
is the only interface to the engine. Note that the unix socket above is the spike's transport, not the design's: the
shipped service listens on `tcp://127.0.0.1:2375`, and neither transport is reachable from inside the sandbox, which is
what §10 question 3 came to (§5.6).

### Step 8 — Ryuk *(run — §10 question 4 answered)*

A cheap proxy for a full Testcontainers run; Ryuk's distinguishing requirement is bind-mounting the socket into a
container:

```
podman run --rm -v "$XDG_RUNTIME_DIR/podman/podman.sock:/var/run/docker.sock" docker.io/testcontainers/ryuk:0.11.0
```

If it starts and logs that it is listening, §5.7 uses `TESTCONTAINERS_RYUK_PRIVILEGED=true`; if it fails,
`TESTCONTAINERS_RYUK_DISABLED=true`. A proxy, not the real thing — note it as such.

Observed: it started and logged `level=INFO msg=Started address=[::]:8080` and `client processing started`. That
reading is **superseded**, because the socket it was given no longer exists: against the shipped TCP service a real
suite fails with `mkdir /var/run/docker.sock: permission denied`, and §5.7 uses `TESTCONTAINERS_RYUK_DISABLED=true`.
The step's own caveat — a proxy, not the real thing — is why it was worth re-measuring.

### Step 9 — tidy up and record

```
exit
podman rmi "$SPIKE_IMAGE"; podman volume rm "$SPIKE_VOL"
rm -f "$TMPDIR"/Dockerfile.spike "$TMPDIR"/*.sh "$TMPDIR"/spike.env
```

Fold anything new into §5.2 (image size on trixie), §5.6, §5.7, §5.9 and §5.10, and update §10.
