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
#   ./run.sh                                  # interactive claude in the current directory
#   ./run.sh --agent code-reviewer            # any arguments are forwarded to claude
#   ./run.sh -p "what does this repo do?"
#   ./run.sh --dangerously-skip-permissions
#   ./run.sh shell                            # bash inside the container instead of claude
#
# Options handled by this script (they must come BEFORE the claude arguments):
#   --image <tag>        image to run (default: claude-tools:latest)
#   --workdir <path>     what to mount as /workspace (default: $PWD)
#   --mount <src:dst>    additional bind mount (repeatable)
#   --env  <K=V>         additional environment variable (repeatable)
#   --no-agents-mount    do not mount <repo>/agents
#   --no-settings-mount  do not mount <repo>/settings.json
#   --no-sandbox         drop the security options that Claude's sandbox needs
#   --network <mode>     docker network mode (default: bridge)
#   --name <name>        container name
#   --                   end of this script's options

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

IMAGE_TAG="${CLAUDE_TOOLS_IMAGE:-claude-tools:latest}"
CONTAINER_USER="${CLAUDE_TOOLS_USER:-claude}"
CONTAINER_HOME="/home/${CONTAINER_USER}"

WORKDIR_HOST="$PWD"
NETWORK_MODE="${CLAUDE_TOOLS_NETWORK:-bridge}"
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

# --- host-side prerequisites ------------------------------------------------
mkdir -p "$HOME/.claude"
[ -f "$HOME/.claude.json" ] || echo '{}' > "$HOME/.claude.json"
mkdir -p "$SCRIPT_DIR/agents"

DOCKER_ARGS=(
    run --rm
    --init
    --network "$NETWORK_MODE"
    --workdir /workspace
    -v "$WORKDIR_HOST:/workspace"
    -v "$HOME/.claude:$CONTAINER_HOME/.claude"
    -v "$HOME/.claude.json:$CONTAINER_HOME/.claude.json"
)

# Claude's own sandbox runs bubblewrap inside the container, which needs an
# unprivileged user namespace and a fresh /proc mount. Docker's defaults block
# all three: the seccomp profile rejects clone(CLONE_NEWUSER), the AppArmor
# profile rejects the mount, and the masked /proc paths stop proc being
# remounted. No added capability is required -- only these restrictions lifted.
#
# The trade-off is real: this weakens Docker's own confinement in exchange for
# Claude's in-container sandbox. Use --no-sandbox to keep Docker's defaults,
# in which case set "sandbox": {"enabled": false} in settings.json as well.
if [ "$ENABLE_SANDBOX" -eq 1 ]; then
    DOCKER_ARGS+=(
        --security-opt seccomp=unconfined
        --security-opt apparmor=unconfined
        --security-opt systempaths=unconfined
    )
fi

# Allocate a TTY only when there is a real terminal (otherwise: -p "...", CI).
if [ -t 0 ] && [ -t 1 ]; then
    DOCKER_ARGS+=(-it)
fi

[ -n "$CONTAINER_NAME" ] && DOCKER_ARGS+=(--name "$CONTAINER_NAME")

# The repo's agents/settings are layered ON TOP of the host ~/.claude mount.
if [ "$MOUNT_AGENTS" -eq 1 ]; then
    DOCKER_ARGS+=(-v "$SCRIPT_DIR/agents:$CONTAINER_HOME/.claude/agents")
fi
if [ "$MOUNT_SETTINGS" -eq 1 ] && [ -f "$SCRIPT_DIR/settings.json" ]; then
    DOCKER_ARGS+=(-v "$SCRIPT_DIR/settings.json:$CONTAINER_HOME/.claude/settings.json")
fi

# Handy read-only mounts, when they exist on the host.
for ro in "$HOME/.gitconfig" "$HOME/.ssh"; do
    [ -e "$ro" ] && DOCKER_ARGS+=(-v "$ro:$CONTAINER_HOME/$(basename "$ro"):ro")
done

for m in "${EXTRA_MOUNTS[@]:-}"; do
    [ -n "$m" ] && DOCKER_ARGS+=(-v "$m")
done

DOCKER_ARGS+=(-e "TERM=${TERM:-xterm-256color}")
[ -n "${TZ:-}" ] && DOCKER_ARGS+=(-e "TZ=$TZ")
for v in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX; do
    [ -n "${!v:-}" ] && DOCKER_ARGS+=(-e "$v=${!v}")
done
for e in "${EXTRA_ENVS[@]:-}"; do
    [ -n "$e" ] && DOCKER_ARGS+=(-e "$e")
done

DOCKER_ARGS+=("$IMAGE_TAG" "$@")

exec docker "${DOCKER_ARGS[@]}"
