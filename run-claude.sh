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
#   --engine <name>      podman or docker (default: podman if installed)
#   --workdir <path>     what to mount as /workspace (default: $PWD)
#   --mount <src:dst>    additional bind mount (repeatable)
#   --env  <K=V>         additional environment variable (repeatable)
#   --no-agents-mount    do not mount <repo>/agents
#   --no-settings-mount  do not mount <repo>/settings.json
#   --no-sandbox         drop the security options that Claude's sandbox needs
#   --network <mode>     network mode (default: bridge; podman's own default
#                        when running rootless)
#   --name <name>        container name
#   --                   end of this script's options
#
# The engine can also be pinned with CONTAINER_ENGINE=docker. Both engines take
# the same arguments here except for the user namespace, the /proc unmasking and
# the default network -- see the comments on each below.

set -euo pipefail

# Resolve symlinks first: the script is meant to be symlinked onto PATH, and
# agents/ and settings.json are located relative to the real file, not the link.
SCRIPT_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)"

IMAGE_TAG="${CLAUDE_TOOLS_IMAGE:-claude-tools:latest}"
CONTAINER_USER="${CLAUDE_TOOLS_USER:-claude}"
CONTAINER_HOME="/home/${CONTAINER_USER}"

ENGINE="${CONTAINER_ENGINE:-}"

WORKDIR_HOST="$PWD"
NETWORK_MODE="${CLAUDE_TOOLS_NETWORK:-}"
CONTAINER_NAME=""
MOUNT_AGENTS=1
MOUNT_SETTINGS=1
ENABLE_SANDBOX=1
EXTRA_MOUNTS=()
EXTRA_ENVS=()

# Print the header comment block as the help text.
usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)             IMAGE_TAG="$2"; shift 2 ;;
        --engine)            ENGINE="$2"; shift 2 ;;
        --workdir)           WORKDIR_HOST="$2"; shift 2 ;;
        --mount)             EXTRA_MOUNTS+=("$2"); shift 2 ;;
        --env)               EXTRA_ENVS+=("$2"); shift 2 ;;
        --network)           NETWORK_MODE="$2"; shift 2 ;;
        --name)              CONTAINER_NAME="$2"; shift 2 ;;
        --no-agents-mount)   MOUNT_AGENTS=0; shift ;;
        --no-settings-mount) MOUNT_SETTINGS=0; shift ;;
        --no-sandbox)        ENABLE_SANDBOX=0; shift ;;
        --help)              usage 0 ;;
        --)                  shift; break ;;
        *)                   break ;;
    esac
done

WORKDIR_HOST="$(cd -- "$WORKDIR_HOST" && pwd)"

# --- container engine -------------------------------------------------------
# podman is the default; docker is only looked for when podman is not installed.
if [ -z "$ENGINE" ]; then
    if command -v podman >/dev/null 2>&1; then
        ENGINE=podman
    elif command -v docker >/dev/null 2>&1; then
        ENGINE=docker
    else
        echo "error: neither podman nor docker is on PATH" >&2
        exit 1
    fi
fi
command -v "$ENGINE" >/dev/null 2>&1 \
    || { echo "error: '${ENGINE}' is not on PATH" >&2; exit 1; }

# Only *rootless* podman needs the adjustments below; `sudo podman` maps ids and
# masks /proc the same way docker does.
ROOTLESS_PODMAN=0
if [ "$(basename -- "$ENGINE")" = "podman" ] && [ "$(id -u)" -ne 0 ]; then
    ROOTLESS_PODMAN=1
fi

# Rootless podman puts the container on pasta/slirp4netns rather than a bridge,
# and its "bridge" means something different from docker's, so the default is
# left to podman itself. An explicit --network is always honoured.
if [ -z "$NETWORK_MODE" ] && [ "$ROOTLESS_PODMAN" -eq 0 ]; then
    NETWORK_MODE=bridge
fi

# --- host-side prerequisites ------------------------------------------------
mkdir -p "$HOME/.claude"
[ -f "$HOME/.claude.json" ] || echo '{}' > "$HOME/.claude.json"
mkdir -p "$SCRIPT_DIR/agents"

# NOTE: on an SELinux distribution the bind mounts below need a :z suffix, which
# is deliberately not added here -- it relabels the host directories.
ENGINE_ARGS=(
    run --rm
    --init
    --workdir /workspace
    -v "$WORKDIR_HOST:/workspace"
    -v "$HOME/.claude:$CONTAINER_HOME/.claude"
    -v "$HOME/.claude.json:$CONTAINER_HOME/.claude.json"
)

[ -n "$NETWORK_MODE" ] && ENGINE_ARGS+=(--network "$NETWORK_MODE")

# Rootless podman maps container uid 0 to the host user and every other id into
# the subuid range, so the image's uid -- which build.sh takes from `id -u` --
# would land outside the mapping and every bind mount would show up owned by
# nobody. keep-id maps the host uid/gid to themselves inside the container,
# which is exactly what the image was built for.
if [ "$ROOTLESS_PODMAN" -eq 1 ]; then
    ENGINE_ARGS+=(--userns=keep-id)
fi

# Claude's own sandbox runs bubblewrap inside the container, which needs an
# unprivileged user namespace and a fresh /proc mount. Docker's defaults block
# all three: the seccomp profile rejects clone(CLONE_NEWUSER), the AppArmor
# profile rejects the mount, and the masked /proc paths stop proc being
# remounted. No added capability is required -- only these restrictions lifted.
#
# The trade-off is real: this weakens the engine's own confinement in exchange
# for Claude's in-container sandbox. Use --no-sandbox to keep the defaults, in
# which case set "sandbox": {"enabled": false} in settings.json as well.
#
# Under rootless podman bubblewrap nests a user namespace inside the one podman
# already created; the kernel allows that, but it is the part most likely to
# need --no-sandbox on an unusual host.
if [ "$ENABLE_SANDBOX" -eq 1 ]; then
    ENGINE_ARGS+=(--security-opt seccomp=unconfined)

    # Rootless podman containers get no AppArmor profile to begin with, so the
    # opt-out is only meaningful for docker and rootful podman.
    if [ "$ROOTLESS_PODMAN" -eq 0 ]; then
        ENGINE_ARGS+=(--security-opt apparmor=unconfined)
    fi

    # Unmasking /proc is spelled differently by the two engines.
    if [ "$(basename -- "$ENGINE")" = "podman" ]; then
        ENGINE_ARGS+=(--security-opt unmask=ALL)
    else
        ENGINE_ARGS+=(--security-opt systempaths=unconfined)
    fi
fi

# Allocate a TTY only when there is a real terminal (otherwise: -p "...", CI).
if [ -t 0 ] && [ -t 1 ]; then
    ENGINE_ARGS+=(-it)
fi

[ -n "$CONTAINER_NAME" ] && ENGINE_ARGS+=(--name "$CONTAINER_NAME")

# The repo's agents/settings are layered ON TOP of the host ~/.claude mount.
if [ "$MOUNT_AGENTS" -eq 1 ]; then
    ENGINE_ARGS+=(-v "$SCRIPT_DIR/agents:$CONTAINER_HOME/.claude/agents")
fi
if [ "$MOUNT_SETTINGS" -eq 1 ] && [ -f "$SCRIPT_DIR/settings.json" ]; then
    ENGINE_ARGS+=(-v "$SCRIPT_DIR/settings.json:$CONTAINER_HOME/.claude/settings.json")
fi

# Handy read-only mounts, when they exist on the host.
for ro in "$HOME/.gitconfig" "$HOME/.ssh"; do
    [ -e "$ro" ] && ENGINE_ARGS+=(-v "$ro:$CONTAINER_HOME/$(basename "$ro"):ro")
done

for m in "${EXTRA_MOUNTS[@]:-}"; do
    [ -n "$m" ] && ENGINE_ARGS+=(-v "$m")
done

ENGINE_ARGS+=(-e "TERM=${TERM:-xterm-256color}")
[ -n "${TZ:-}" ] && ENGINE_ARGS+=(-e "TZ=$TZ")
for v in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX; do
    [ -n "${!v:-}" ] && ENGINE_ARGS+=(-e "$v=${!v}")
done
for e in "${EXTRA_ENVS[@]:-}"; do
    [ -n "$e" ] && ENGINE_ARGS+=(-e "$e")
done

ENGINE_ARGS+=("$IMAGE_TAG" "$@")

exec "$ENGINE" "${ENGINE_ARGS[@]}"
