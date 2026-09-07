#!/usr/bin/env bash
#
# Runs the claude-tools image, with claude as the entrypoint.
#
# Mounts:
#   $PWD                  -> /workspace              (current directory, workdir)
#   ~/.claude             -> ~/.claude               (auth, history, projects)
#   ~/.claude.json        -> ~/.claude.json
#   <repo>/agents         -> ~/.claude/agents        (agents versioned in this repo)
#   <repo>/settings.json  -> ~/.claude/settings.json (settings versioned in this repo)
#
# Usage:
#   ./run-claude.sh                                  # interactive claude in the current directory
#   ./run-claude.sh --agent code-reviewer            # any arguments are forwarded to claude
#   ./run-claude.sh -p "what does this repo do?"
#   ./run-claude.sh --dangerously-skip-permissions
#   ./run-claude.sh shell                            # bash inside the container instead of claude
#
# Options handled by this script (they must come BEFORE the claude arguments):
#   --image <tag>        image to run (default: claude-tools:latest)
#   --workdir <path>     what to mount as /workspace (default: $PWD)
#   --mount <src:dst>    additional bind mount (repeatable)
#   --env  <K=V>         additional environment variable (repeatable)
#   --no-agents-mount    do not mount <repo>/agents
#   --no-settings-mount  do not mount <repo>/settings.json
#   --no-sandbox         drop the security options that Claude's sandbox needs
#   --containers         start containers inside this one (see the note below)
#   --network <mode>     network mode (default: podman's own)
#   --name <name>        container name
#   --                   end of this script's options
#
# podman is the only supported engine and has to be on PATH; there is no docker
# fallback. It also has to be rootless: the script refuses to run as root, since
# under sudo a bind mount becomes a way to write root-owned files onto the host.
#
# --containers lets the agent start its own containers inside this one, as
# children of it, and is off by default. It grants the container --cap-add=all,
# without which the inner rootless podman cannot map its subuid range. Those
# capabilities apply inside the container's user namespace and not on the host,
# so they are not host privilege -- but the container is materially less
# confined than without the flag, which is why it is opt-in. It cannot be
# combined with --no-sandbox, nor with host networking: the container engine
# API it starts is unauthenticated and is kept private by the container's own
# network namespace, which --network host takes away.
#
# The capability is not the whole cost. The containers the agent starts run
# outside Claude's sandbox and outside settings.json's deny list, so anything
# started in one can read the credentials in the mounted ~/.claude, and the
# images it pulls are never seen by the sandbox's network filter.

set -euo pipefail

# Resolve symlinks first: the script is meant to be symlinked onto PATH, and
# agents/ and settings.json are located relative to the real file, not the link.
SCRIPT_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)"

IMAGE_TAG="${CLAUDE_TOOLS_IMAGE:-claude-tools:latest}"
CONTAINER_USER="${CLAUDE_TOOLS_USER:-claude}"
CONTAINER_HOME="/home/${CONTAINER_USER}"

WORKDIR_HOST="$PWD"
NETWORK_MODE="${CLAUDE_TOOLS_NETWORK:-}"
CONTAINER_NAME=""
MOUNT_AGENTS=1
MOUNT_SETTINGS=1
ENABLE_SANDBOX=1
ENABLE_CONTAINERS=0
EXTRA_MOUNTS=()
EXTRA_ENVS=()

# Print the header comment block as the help text.
usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)             IMAGE_TAG="$2"; shift 2 ;;
        --workdir)           WORKDIR_HOST="$2"; shift 2 ;;
        --mount)             EXTRA_MOUNTS+=("$2"); shift 2 ;;
        --env)               EXTRA_ENVS+=("$2"); shift 2 ;;
        --network)           NETWORK_MODE="$2"; shift 2 ;;
        --name)              CONTAINER_NAME="$2"; shift 2 ;;
        --no-agents-mount)   MOUNT_AGENTS=0; shift ;;
        --no-settings-mount) MOUNT_SETTINGS=0; shift ;;
        --no-sandbox)        ENABLE_SANDBOX=0; shift ;;
        --containers)        ENABLE_CONTAINERS=1; shift ;;
        --help)              usage 0 ;;
        --)                  shift; break ;;
        *)                   break ;;
    esac
done

# --containers needs exactly the two security options that --no-sandbox drops,
# so the combination cannot do what it asks for. Checked here, after the whole
# command line has been parsed, so the order of the two flags does not matter.
if [ "$ENABLE_CONTAINERS" -eq 1 ] && [ "$ENABLE_SANDBOX" -eq 0 ]; then
    echo "error: --containers and --no-sandbox are mutually exclusive" >&2
    echo "       the inner podman needs the seccomp=unconfined and unmask=ALL" >&2
    echo "       that --no-sandbox drops" >&2
    exit 1
fi

# Host networking is refused for the same reason it is checked here: the podman
# API service the entrypoint starts is unauthenticated, and the only thing that
# keeps it private is the container having a network namespace of its own.
# NETWORK_MODE is read after parsing, so this catches --network host and
# CLAUDE_TOOLS_NETWORK alike, whatever order the flags came in.
if [ "$ENABLE_CONTAINERS" -eq 1 ] && [ "$NETWORK_MODE" = "host" ]; then
    echo "error: --containers and --network host are mutually exclusive" >&2
    echo "       the container engine API the entrypoint starts has no" >&2
    echo "       authentication, and only the container's own network namespace" >&2
    echo "       keeps it private; on host networking every process on the host" >&2
    echo "       could drive it" >&2
    exit 1
fi

WORKDIR_HOST="$(cd -- "$WORKDIR_HOST" && pwd)"

# --- podman -----------------------------------------------------------------
command -v podman >/dev/null 2>&1 \
    || { echo "error: podman is not on PATH" >&2; exit 1; }

# Rootless only. Everything below assumes podman maps the container's uid 0 to
# an ordinary host user; under sudo it maps to host uid 0 instead, and then
# anything the container writes through a bind mount lands on the host as root.
if [ "$(id -u)" -eq 0 ]; then
    echo "error: refusing to run as root -- podman has to be rootless here" >&2
    echo "       under sudo the container's uid 0 is host uid 0, so a bind mount" >&2
    echo "       becomes a way to write root-owned files onto the host" >&2
    exit 1
fi

# --- host-side prerequisites ------------------------------------------------
mkdir -p "$HOME/.claude"
[ -f "$HOME/.claude.json" ] || echo '{}' > "$HOME/.claude.json"
mkdir -p "$SCRIPT_DIR/agents"

# NOTE: on an SELinux distribution the bind mounts below need a :z suffix, which
# is deliberately not added here -- it relabels the host directories.
PODMAN_ARGS=(
    run --rm
    --init
    --workdir /workspace
    -v "$WORKDIR_HOST:/workspace"
    -v "$HOME/.claude:$CONTAINER_HOME/.claude"
    -v "$HOME/.claude.json:$CONTAINER_HOME/.claude.json"
)

# Rootless podman puts the container on pasta/slirp4netns rather than a bridge,
# so there is no sensible default to impose here and the choice is left to
# podman itself. An explicit --network (or CLAUDE_TOOLS_NETWORK) is honoured.
[ -n "$NETWORK_MODE" ] && PODMAN_ARGS+=(--network "$NETWORK_MODE")

# Rootless podman maps container uid 0 to the host user and every other id into
# the subuid range, so the image's uid -- which build.sh takes from `id -u` --
# would land outside the mapping and every bind mount would show up owned by
# nobody. keep-id maps the host uid/gid to themselves inside the container,
# which is exactly what the image was built for.
PODMAN_ARGS+=(--userns=keep-id)

# Claude's own sandbox runs bubblewrap inside the container, which needs an
# unprivileged user namespace and a fresh /proc mount. Podman's defaults block
# both: the seccomp profile rejects clone(CLONE_NEWUSER), and the masked /proc
# paths stop proc being remounted. No added capability is required -- only these
# two restrictions lifted. (There is no AppArmor opt-out to make: a rootless
# podman container gets no profile in the first place.)
#
# The trade-off is real: this weakens podman's own confinement in exchange for
# Claude's in-container sandbox. Use --no-sandbox to keep the defaults, in which
# case set "sandbox": {"enabled": false} in settings.json as well.
#
# Under rootless podman bubblewrap nests a user namespace inside the one podman
# already created; the kernel allows that, but it is the part most likely to
# need --no-sandbox on an unusual host.
if [ "$ENABLE_SANDBOX" -eq 1 ]; then
    PODMAN_ARGS+=(--security-opt seccomp=unconfined)
    PODMAN_ARGS+=(--security-opt unmask=ALL)
fi

# Nested containers. The agent's own containers are children of this one, run by
# a podman API service that docker-entrypoint.sh starts when it sees
# CLAUDE_TOOLS_CONTAINERS set to 1 -- the value is the contract, and it is this
# flag's only trigger. CONTAINER_HOST and DOCKER_HOST are deliberately not set
# here: the entrypoint exports them, pointing at the loopback address the API
# service listens on, only once it has confirmed the service is answering
# there -- so a service that failed to start never leaves them pointing at
# nothing.
#
# --cap-add=all is a genuine security concession, and the reason this is opt-in
# rather than always on. Without it the inner podman cannot map its subuid
# range: newuidmap fails and no image that drops privileges will start. A
# narrower grant does not work: --cap-add=setuid,setgid alone changes nothing,
# and which capability is the operative one is not known; narrowing this to a
# named set is the obvious improvement to make once it is.
# What it costs: the capabilities are granted inside the container's user
# namespace and not on the host, so they confer no host privilege, but the
# container is materially less confined than it is without the flag.
# --privileged also works and is deliberately not used: it is strictly broader,
# additionally exposing host devices, and buys nothing more.
#
# The capability is not the whole cost either. The containers the agent starts
# run outside Claude's sandbox and outside settings.json's deny list -- both
# constrain Claude's own tools, not a process in another container -- so they
# can read the credentials in the mounted ~/.claude, and their image pulls
# never reach the sandbox's network filter.
#
# The devices are what the inner podman needs to run rootless: /dev/fuse for
# fuse-overlayfs, /dev/net/tun for the pasta/slirp4netns network namespace.
#
# The volume is not just a cache. This container's own filesystem is overlayfs
# and fuse-overlayfs cannot stack on it, so the inner image store has to sit on
# a real one; keeping images between runs is the second reason. No :U suffix --
# under --userns=keep-id the host uid maps to itself, so podman creates the
# volume already owned by the container user, and :U would chown the whole
# store on every run. Reclaim it with `podman volume rm claude-tools-containers`.
if [ "$ENABLE_CONTAINERS" -eq 1 ]; then
    PODMAN_ARGS+=(--cap-add=all)
    PODMAN_ARGS+=(--device /dev/fuse)
    PODMAN_ARGS+=(--device /dev/net/tun)
    PODMAN_ARGS+=(-v "claude-tools-containers:$CONTAINER_HOME/.local/share/containers")
    PODMAN_ARGS+=(-e CLAUDE_TOOLS_CONTAINERS=1)
fi

# Allocate a TTY only when there is a real terminal (otherwise: -p "...", CI).
if [ -t 0 ] && [ -t 1 ]; then
    PODMAN_ARGS+=(-it)
fi

[ -n "$CONTAINER_NAME" ] && PODMAN_ARGS+=(--name "$CONTAINER_NAME")

# The repo's agents/settings are layered ON TOP of the host ~/.claude mount.
if [ "$MOUNT_AGENTS" -eq 1 ]; then
    PODMAN_ARGS+=(-v "$SCRIPT_DIR/agents:$CONTAINER_HOME/.claude/agents")
fi
if [ "$MOUNT_SETTINGS" -eq 1 ] && [ -f "$SCRIPT_DIR/settings.json" ]; then
    PODMAN_ARGS+=(-v "$SCRIPT_DIR/settings.json:$CONTAINER_HOME/.claude/settings.json")
fi

# Handy read-only mount, when it exists on the host.
#
# ~/.ssh is deliberately NOT mounted. A mounted key is readable by every process
# in the container -- `:ro` prevents writes, never reads -- and the deny entries
# in settings.json only constrain Claude's own tools, not an arbitrary command.
# Nothing in the image needs the host's keys; give a dedicated key with --mount
# if a container ever has to reach a remote over ssh.
if [ -e "$HOME/.gitconfig" ]; then
    PODMAN_ARGS+=(-v "$HOME/.gitconfig:$CONTAINER_HOME/.gitconfig:ro")
fi

for m in "${EXTRA_MOUNTS[@]:-}"; do
    [ -n "$m" ] && PODMAN_ARGS+=(-v "$m")
done

PODMAN_ARGS+=(-e "TERM=${TERM:-xterm-256color}")
[ -n "${TZ:-}" ] && PODMAN_ARGS+=(-e "TZ=$TZ")
for v in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX; do
    [ -n "${!v:-}" ] && PODMAN_ARGS+=(-e "$v=${!v}")
done
for e in "${EXTRA_ENVS[@]:-}"; do
    [ -n "$e" ] && PODMAN_ARGS+=(-e "$e")
done

PODMAN_ARGS+=("$IMAGE_TAG" "$@")

exec podman "${PODMAN_ARGS[@]}"
