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
- Changing the sandbox defaults. Claude's sandbox stays enabled; the design works with it on.
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

**Nothing in this document has been built or executed.** No container engine exists in the environment where the
analysis was written; commit `a3ca3fe`, which moved the base image to Debian 13, has itself never been built. Every
empirical claim below is marked with the command that would confirm it on a real host.

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
        └── claude
            └── bubblewrap                Claude's sandbox, wraps every Bash call
                └── mvn / gradle / npm → talks to the service over a unix socket
```

Three properties follow from that shape, and together they are the whole argument for it:

- **The mount requirement is satisfied by the kernel, not by policy.** The inner podman can only bind-mount paths that
  exist in the claude container's mount namespace. The host filesystem is not one of them. No allow-list, no proxy, no
  enforcement code — the paths simply are not there.
- **`localhost` means the same thing to the test process and to the published port.** Both live in the claude
  container's network namespace, so a foreign repository's hard-coded `localhost:5432`, a Testcontainers
  `getMappedPort()`, and a container that needs to reach back into the test process all work with no overrides.
- **Relative volumes resolve correctly.** A compose file's `./config:/etc/app` resolves against its own directory under
  `/workspace`, which exists in the same namespace.

**Why the daemon is started by the entrypoint rather than invoked by the agent.** The reason is the API, not the
sandbox: Testcontainers, dockerode, docker-py and the compose implementations all speak the Docker-compatible **socket**
and never the CLI, so a service has to exist regardless. Starting `podman system service` from `docker-entrypoint.sh`,
in the PID-1 context, is simply the earliest and simplest place to put it.

An earlier draft justified it differently — that bubblewrap's `no_new_privs` neutralises the setuid-root
`newuidmap`/`newgidmap` helpers. **The spike refuted that diagnosis** (§5.6): `newuidmap` fails for a capability reason
that applies outside bubblewrap too, and is fixed on the outer container rather than inside. Whether bubblewrap
*additionally* blocks the local CLI is still unmeasured and does not affect the case for the service.

**The core of this design is now verified.** The S1 spike brought up `postgres:16` nested, watched it drop to uid 999
and report itself ready, and reached its published port from inside the claude container. See §5.10.

**The agent's interface is `podman`.** `CONTAINER_HOST` points the podman CLI at the service, so `podman run …` works
as a thin remote client. `DOCKER_HOST` is set to the same socket — not as an engine choice, but because Testcontainers,
dockerode and docker-py inside *foreign* code read that variable and speak the Docker-compatible API that podman's
service serves.

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
| `passt` and/or `slirp4netns`| the rootless network namespace; needs `/dev/net/tun` in the outer container      |
| `catatonit`                 | podman's `--init` process for the containers the agent starts                    |
| a compose implementation    | see §5.5                                                                         |

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
- `storage.conf` selecting `overlay` with `mount_program = /usr/bin/fuse-overlayfs`, with `vfs` named as the documented
  fallback.

Package names are **confirmed present in Debian 13**, measured on the user's host on 2026-09-03 with `apt-cache policy`
inside `debian:trixie-slim`: `podman 5.4.2+ds1-2+b2`, `uidmap 1:4.17.4-2`, `fuse-overlayfs 1.14-1+b1`,
`passt 0.0~git20250503.587980c-2+deb13u1`, `slirp4netns 1.2.1-1.1`, `catatonit 0.2.1-2+b13`, `podman-compose 1.3.0-1`.
That open item is closed. The trixie base image measures **1.88 GB**, slightly smaller than the 1.96 GB bookworm one.
Growth from adding podman and its dependencies was roughly 100 MB, but measured against the bookworm base — treat it as
indicative and re-measure on trixie.

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

Proposed mount: `-v claude-tools-containers:/home/<user>/.local/share/containers`. Podman's `:U` suffix, which chowns
the volume to the container user, is likely needed on first creation under `--userns=keep-id`; **verify** with
`podman volume inspect` and an `ls -ln` inside the container.

**The cost argument is softer than assumed.** The spike reported `Store.GraphDriverName = overlay`, so `fuse-overlayfs`
does work with `--device /dev/fuse` and the `vfs` fallback — with its per-layer copies and slow first starts — may never
be reached. Re-verify before relying on it; the volume is still required, because `fuse-overlayfs` cannot stack on the
container's own overlayfs.

### 5.4 `run-claude.sh --containers`

Default **off**. When given, it adds:

- **`--cap-add=all`** — required. See below; this is a genuine new concession.
- `--device /dev/fuse` — for `fuse-overlayfs`.
- `--device /dev/net/tun` — for pasta/slirp4netns, which the inner podman uses for its rootless network namespace.
- the named volume of §5.3.
- `-e CLAUDE_TOOLS_CONTAINERS=1`, which is what the entrypoint keys off.

**`--cap-add=all` is a new security concession and must be described as one.** An earlier draft claimed `--containers`
needed no new security option because `seccomp=unconfined` and `unmask=ALL` were already passed. The spike refuted
that: without `--cap-add=all`, `newuidmap` fails and no image that drops privileges can start. The capabilities are
added to the *outer* container — the one Claude runs in — and they are real capabilities in that user namespace, not on
the host.

**Narrowing it is unresolved and worth revisiting.** `--cap-add=setuid,setgid` alone changed nothing, even though
`CAP_SETUID` and `CAP_SETGID` were already present in `CapBnd` before any `--cap-add`. Only the full set worked. Which
additional capability is operative was **not** determined and is deliberately not guessed here. Moving from `all` to a
named set would be a measurable improvement to the threat model and is the obvious follow-up.

`--privileged` was also tried and also worked. It is **rejected**: it is strictly broader, additionally exposing host
devices reachable by the invoking user, and it buys nothing that `--cap-add=all` does not.

If `--no-sandbox` is used, `seccomp=unconfined` and `unmask=ALL` disappear and `--containers` will not work — the two
flags are mutually exclusive in practice and the script should say so.

### 5.5 Compose

Two candidates, and the choice interacts with the user's decision to remove docker:

- **`podman-compose`** (Debian package, pure Python, talks to the socket). Consistent with a podman-only design, no
  `docker` binary anywhere. A foreign repository whose `Makefile` calls `docker compose` will not work.
- **Docker Compose v2 plugin binary.** Restores `docker compose` for foreign code. Note the trap: the conventional
  plugin directory is `~/.docker/cli-plugins`, and `~/.docker` is on `sandbox.filesystem.denyRead` — so `DOCKER_CONFIG`
  must point elsewhere, and nothing belonging to this feature may live under `~/.docker`.

Recommendation: `podman-compose`, as the option consistent with the stated direction. Whether to additionally install
`podman-docker` so that foreign `docker` invocations resolve is an open question (§10), not a decision taken here — it
reintroduces a `docker` binary into a design whose premise is removing docker.

### 5.6 Sandbox interaction

Everything the agent runs — the build tool, the test process, the readiness polling — runs inside bubblewrap. Two things
must survive it:

1. **The socket must be connectable.** Connecting to a unix socket requires write permission on the inode. If bubblewrap
   does not expose `$XDG_RUNTIME_DIR/podman/podman.sock` writable, every client reports *"Could not find a valid Docker
   environment"*. Whether `settings.json`'s `sandbox.filesystem` can express a write allowance — the current file uses
   only `allowRead`/`denyRead` — **needs checking against the installed Claude Code version**.
2. **Loopback must be reachable.** Published ports bind on the claude container's loopback; the test process reaches
   them through the sandbox's socat network filter.

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

**What remains genuinely unmeasured** is whether bubblewrap *also* blocks the local podman CLI once the capability
problem is solved. That comparison — Appendix A step 7 — has not been run. It no longer decides whether the service
exists, since §4 justifies that on the API, but it does decide whether the agent can usefully run `podman` locally as
well as remotely. Once S5 and S7 have landed it is expressed as

```
./run-claude.sh --containers shell -lc 'podman info'          # outside bwrap
./run-claude.sh --containers -p 'run: podman info'            # via the Bash tool, sandbox on
```

### 5.7 Environment exported into the container

`CONTAINER_HOST` and `DOCKER_HOST` pointing at the service socket. For Testcontainers, `TESTCONTAINERS_RYUK_DISABLED` or
`TESTCONTAINERS_RYUK_PRIVILEGED` — Ryuk bind-mounts the socket into itself and is a known friction point under podman;
which of the two is correct **needs verification**. Notably `TESTCONTAINERS_HOST_OVERRIDE` is *not* needed, which is
precisely the difference between this design and the rejected one.

### 5.8 Entrypoint

When `CLAUDE_TOOLS_CONTAINERS=1`: create `$XDG_RUNTIME_DIR`, start `podman system service --time=0
unix://$XDG_RUNTIME_DIR/podman/podman.sock` in the background, poll for the socket with a bounded timeout, then
`exec claude` as today. On failure it must print an explicit diagnostic naming the likely cause rather than failing
silently or aborting the container — Claude itself is still usable without it, and a silent failure produces exactly the
confusing error this design is meant to avoid.

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
  where those subuids are mapped. **Verify** on a real host before putting it in the README.
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

**Still unmeasured, and deliberately not inferred from the above:** the §5.9 ownership experiment (root versus uid-999
writes into the `/workspace` bind mount, read back with `ls -ln` from the host); the bubblewrap comparison of §5.6; the
Ryuk variable of §5.7; and MinIO's default user.

## 6. Failure handling and edge cases

| Condition                                                    | Behaviour                                              | User-visible result                                              |
|--------------------------------------------------------------|--------------------------------------------------------|------------------------------------------------------------------|
| `--containers` not given                                     | no service, no devices, no volume                      | agent reports the capability is off, not that the repo is broken   |
| `--containers` given together with `--no-sandbox`            | script rejects the combination                          | explicit error naming the conflict                                 |
| Inner podman cannot map subuids                              | service fails at start; entrypoint logs and continues   | named diagnostic at container start, Claude still usable           |
| `/dev/fuse` unavailable on the host                          | fall back to the `vfs` storage driver                   | slower first start, more disk; documented in the README            |
| `/dev/net/tun` unavailable                                   | inner rootless networking fails                         | containers start but no port publishing; diagnostic in the log     |
| Socket not connectable from inside bubblewrap                | clients cannot find a Docker environment                | *"Could not find a valid Docker environment"*                      |
| Loopback filtered by the sandbox network filter              | readiness polling never succeeds                        | *"Timed out waiting for container port to open"*                   |
| First pull of a large image inside the startup timeout       | wait strategy expires before the service is ready       | same timeout message as above — indistinguishable without triage   |
| Service alive but the image genuinely slow (rabbitmq ~10-20s)| wait strategy eventually succeeds                       | slow first run, then fast                                          |
| Spawned container runs as root and writes to `/workspace`    | ids map back to the invoking user                       | files owned by the user, exactly as today                          |
| Spawned container drops to a non-root uid and writes there   | `Permission denied`, or files owned by a host subuid    | fixture fails, or files the user cannot delete                     |
| Agent leaves containers running                              | they die with the claude container (`--rm`)             | no host residue; the store volume keeps images only                |
| Store volume grows unbounded                                 | not reclaimed automatically                             | documented `podman volume rm claude-tools-containers` in README    |

The middle four rows all surface as one of two messages. The README must carry a triage note distinguishing them:
socket unreachable → *"could not find a valid Docker environment"*; everything else → *"timed out"*, separated by
whether `podman --remote ps` lists the container at all, and whether its log shows the service listening.

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
  and `run-claude.sh` grants this only under `--containers`. `--privileged` was rejected as strictly broader.
  Which single capability is actually required is **unknown**; narrowing `all` to a named set is the clearest available
  improvement to this threat model and should be treated as a follow-up rather than forgotten.
- The README's *"Anything requiring root has to go into the `Dockerfile`"* survives literally — there is still no `sudo`
  — but the image gains `newuidmap`/`newgidmap`, setuid-root helpers whose whole purpose is to cross a privilege
  boundary, and the agent gains root inside nested user namespaces. Not host root; not the same claim either.
- **Any container the agent starts runs outside both `settings.json`'s deny list and bubblewrap.** It can read the
  credentials in the mounted `~/.claude`, and it has network. The deny entries for `~/.ssh` and friends constrain
  Claude's own tools, not a process the agent starts in a container. Bubblewrap still protects against *accidental*
  access — a stray `cat` in a Bash call — which is not nothing, but it no longer protects against deliberate access.
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

**Operational cost.** Image growth of roughly 100 MB — measured once, but against a bookworm base, so indicative only
and pending re-measurement on trixie. A named volume that grows with every image the
agent pulls and is never reclaimed automatically. First-run latency dominated by pulls. No cgroup delegation inside the
container, so spawned containers run without resource limits — a runaway test fixture is bounded only by the claude
container's own limits.

**Testability.** There is no test suite in this repository and this change does not create one. Verification is manual,
which is a real weakness; §5.6 and the spike exist to make it repeatable rather than ad hoc.

## 9. Implementation algorithm

| #   | Step                                        | Files / area                          | Commit title                                      | Depends on     | Done when                                                                 |
|-----|---------------------------------------------|---------------------------------------|---------------------------------------------------|----------------|---------------------------------------------------------------------------|
| S1  | Spike nested podman on a real host **(done)**| this document                          | `Record the nested podman spike results`           | —              | done — results in §5.10; nesting verified, `--cap-add=all` found necessary |
| S2  | Drop docker from the build script            | `build.sh`                             | `Remove the docker engine option from build.sh`    | —              | `--engine`/`CONTAINER_ENGINE`/`AUTO_ENGINE` gone; missing podman errors    |
| S3  | Drop docker, require rootless podman         | `run-claude.sh`                        | `Remove the docker engine option from run-claude.sh`| —             | engine branches gone; `unmask=ALL` unconditional; rootful refused          |
| S4  | Document the podman-only engine              | `README.md`                            | `Document the podman-only engine in the README`    | S2, S3         | sandbox table rewritten for podman; migration note for docker users        |
| S5  | Install podman and its config in the image   | `Dockerfile`                           | `Install rootless podman in the image`             | S1             | image builds; `podman info` succeeds in `shell`; options commented in file |
| S6  | Start the API service from the entrypoint    | `docker-entrypoint.sh`                 | `Start the podman API service from the entrypoint` | S5             | socket exists; `podman --remote info` succeeds; failure logs a diagnostic  |
| S7  | Add the opt-in flag                          | `run-claude.sh`                        | `Add --containers to run-claude.sh`                | S5             | flag adds `--cap-add=all`, both devices, volume, env; `--no-sandbox` refused|
| S8  | Add compose support                          | `Dockerfile`                           | `Add compose support inside the image`             | S5             | a compose file under `/workspace` comes up and down from `shell`           |
| S9  | Open the socket and loopback to the sandbox  | `settings.json`                        | `Allow the podman socket through Claude's sandbox` | S6, S7         | a Testcontainers run started by the agent reaches the service and the port |
| S10 | Document the capability and its threat model | `README.md`                            | `Document container spawning and its threat model` | S6, S7, S8, S9 | `--cap-add=all` concession stated; triage note; volume cleanup documented  |
| S11 | Teach the three agents the capability        | `agents/` — three prompts              | `Teach the agents to use podman`                   | S6, S7         | three prompts updated; guidance tailored per role; README note added       |
| S12 | Version bump                                 | `Version.txt`                          | `v1.2.0`                                           | S10, S11       | version reflects the released change                                       |

**Parallelization:** Wave 1: S1 *(done)*, S2, S3 · Wave 2: S4 (needs S2, S3), S5 (needs S1) · Wave 3: S6, S7, S8
(need S5) · Wave 4: S9 (needs S6, S7) · Wave 5: S10, S11 (independent of each other) · Wave 6: S12

With S1 landed, the two chains can now run fully in parallel: the podman-only chain (S2 → S3 → S4) and the spawning
chain (S5 → S6/S7/S8 → …) share no files and no ordering.

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
- **S7** must add `--cap-add=all` alongside the two devices. This is a security concession, so the flag's help text and
  the comment beside it say what it buys and what it costs, in the manner of the existing sandbox block.
- **S9** may turn out to need nothing if the sandbox already permits both; the step then records that, and is still a
  commit only if something changes.
- **S11** touches `agents/code-reviewer.md`, `agents/developer.md` and `agents/senior-dev.md`. The **shared substance**
  is identical in all three: podman is the only engine and `docker` does not exist; a repository's compose file is
  brought up from its own directory under `/workspace` and torn down afterwards; containers run as root against a
  workspace bind mount, or non-root against named volumes (§5.9); and the two-timeout triage of §6, so that a sandbox
  or pull problem is never reported as a defect in the code under test.

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
| 2 | Does bubblewrap block the local podman CLI once capabilities are right? (Appendix A step 7)      | measurement | none   |
| 3 | Does `sandbox.filesystem` support a write allowance for the socket path in the installed build?  | measurement | S9     |
| 4 | `TESTCONTAINERS_RYUK_DISABLED` or `TESTCONTAINERS_RYUK_PRIVILEGED` under nested rootless podman?  | measurement | S9     |
| 5 | Does the MinIO image in use still default to root? `podman image inspect --format '{{.Config.User}}'` | measurement | S11 |
| 6 | The §5.9 ownership experiment — root versus uid-999 writes, read back with `ls -ln` on the host  | measurement | none   |

All decisions have been taken; what remains are measurements. **Question 1 is the one worth chasing**: narrowing
`--cap-add=all` to a named set is the clearest available improvement to the threat model, and it is not on the critical
path. Question 6 would confirm or refute the table in §5.9, which currently rests on reasoning rather than observation.
Nothing here blocks S2 through S8.

**Resolved during review, recorded for traceability:**

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
- The `~/.ssh` mount has been **removed** in commit `1eabbb5`, in a separate change while this analysis was being
  written. `~/.gitconfig` remains mounted read-only by the user's choice. Nothing in this plan depends on either.

## Appendix A — Spike procedure (S1)

**Status: run, and successful.** The results are in §5.10. This procedure is kept for two reasons: steps 6 to 8 were
never reached and remain the outstanding measurements of §10, and steps 1 to 5 are the reproduction anyone needs when
S5 and S7 are implemented.

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
that is the image-growth figure §5.2 still needs on a trixie base.

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

### Step 6 — ownership *(outstanding — §10 question 6)*

Validates the table in §5.9, which currently rests on reasoning rather than observation. In the spike shell:

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

### Step 7 — the bubblewrap comparison *(outstanding — §10 question 2)*

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

- **Local fails, remote succeeds** — the socket is what the agent must use. S6 as designed, and §10 question 3 is
  answered *yes, the sandbox permits the socket*.
- **Both succeed** — bubblewrap blocks neither. The agent may use the CLI directly; the service still exists for
  Testcontainers.
- **Both fail** — the sandbox blocks the socket too. §10 question 3 is answered *no* and S9 has real work; capture the
  exact error, since it determines whether `settings.json` can express the allowance at all.

### Step 8 — Ryuk *(outstanding — §10 question 4)*

A cheap proxy for a full Testcontainers run; Ryuk's distinguishing requirement is bind-mounting the socket into a
container:

```
podman run --rm -v "$XDG_RUNTIME_DIR/podman/podman.sock:/var/run/docker.sock" docker.io/testcontainers/ryuk:0.11.0
```

If it starts and logs that it is listening, §5.7 uses `TESTCONTAINERS_RYUK_PRIVILEGED=true`; if it fails,
`TESTCONTAINERS_RYUK_DISABLED=true`. A proxy, not the real thing — note it as such.

### Step 9 — tidy up and record

```
exit
podman rmi "$SPIKE_IMAGE"; podman volume rm "$SPIKE_VOL"
rm -f "$TMPDIR"/Dockerfile.spike "$TMPDIR"/*.sh "$TMPDIR"/spike.env
```

Fold anything new into §5.2 (image size on trixie), §5.6, §5.7, §5.9 and §5.10, and update §10.
