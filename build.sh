#!/usr/bin/env bash
#
# Builds the claude-tools image with the current user's uid/gid, so that
# anything written into the bind mounts is owned by you rather than by root.
#
# Usage:
#   ./build.sh                         # default versions
#   ./build.sh --no-cache
#   ./build.sh --tag my-claude:dev
#   ./build.sh --python 3.11.9 --java 17.0.13-tem
#   ./build.sh --python none --java none        # skip the slow installations
#   ./build.sh --claude-version 2.1.246
#   ./build.sh --maven 3.9.9 --gradle 8.10.2
#   ./build.sh --engine podman         # build with podman instead of docker
#
# The engine defaults to docker when it is installed and podman otherwise; it
# can also be pinned with CONTAINER_ENGINE=podman. The Dockerfile itself is
# engine-agnostic: it uses no BuildKit-only features, and every apt-get runs
# before the USER instruction, so a rootless `podman build` has root inside its
# own user namespace exactly where the build needs it.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

IMAGE_TAG="${CLAUDE_TOOLS_IMAGE:-claude-tools:latest}"
USER_NAME="${CLAUDE_TOOLS_USER:-claude}"
USER_UID="$(id -u)"
USER_GID="$(id -g)"

ENGINE="${CONTAINER_ENGINE:-}"

NODE_MAJOR=22
CLAUDE_VERSION=latest
PYTHON_VERSION=3.12.7
JAVA_VERSION=21.0.5-tem
MAVEN_VERSION=none
GRADLE_VERSION=none

EXTRA_ARGS=()

# Print the header comment block as the help text.
usage() {
    awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--tag)            IMAGE_TAG="$2"; shift 2 ;;
        --engine)            ENGINE="$2"; shift 2 ;;
        -u|--user)           USER_NAME="$2"; shift 2 ;;
        --uid)               USER_UID="$2"; shift 2 ;;
        --gid)               USER_GID="$2"; shift 2 ;;
        --node)              NODE_MAJOR="$2"; shift 2 ;;
        --claude-version)    CLAUDE_VERSION="$2"; shift 2 ;;
        --python)            PYTHON_VERSION="$2"; shift 2 ;;
        --java)              JAVA_VERSION="$2"; shift 2 ;;
        --maven)             MAVEN_VERSION="$2"; shift 2 ;;
        --gradle)            GRADLE_VERSION="$2"; shift 2 ;;
        -h|--help)           usage 0 ;;
        *)                   EXTRA_ARGS+=("$1"); shift ;;   # e.g. --no-cache, --pull
    esac
done

if [ -z "$ENGINE" ]; then
    if command -v docker >/dev/null 2>&1; then ENGINE=docker; else ENGINE=podman; fi
fi
command -v "$ENGINE" >/dev/null 2>&1 \
    || { echo "error: '${ENGINE}' is not on PATH" >&2; exit 1; }

echo "==> Building ${IMAGE_TAG}"
echo "    engine : ${ENGINE}"
echo "    user   : ${USER_NAME} (uid=${USER_UID} gid=${USER_GID}, no sudo)"
echo "    node   : ${NODE_MAJOR}   claude: ${CLAUDE_VERSION}"
echo "    python : ${PYTHON_VERSION}   java: ${JAVA_VERSION}"
echo "    maven  : ${MAVEN_VERSION}   gradle: ${GRADLE_VERSION}"
echo

"${ENGINE}" build \
    --build-arg "USER_NAME=${USER_NAME}" \
    --build-arg "USER_UID=${USER_UID}" \
    --build-arg "USER_GID=${USER_GID}" \
    --build-arg "NODE_MAJOR=${NODE_MAJOR}" \
    --build-arg "CLAUDE_VERSION=${CLAUDE_VERSION}" \
    --build-arg "PYTHON_VERSION=${PYTHON_VERSION}" \
    --build-arg "JAVA_VERSION=${JAVA_VERSION}" \
    --build-arg "MAVEN_VERSION=${MAVEN_VERSION}" \
    --build-arg "GRADLE_VERSION=${GRADLE_VERSION}" \
    -t "${IMAGE_TAG}" \
    "${EXTRA_ARGS[@]}" \
    "${SCRIPT_DIR}"

echo
echo "==> Done: ${IMAGE_TAG}"

# run-claude.sh auto-detects the same way, so the engine only has to be named
# again when this build did not use the one it would pick on its own.
RUN_PREFIX=""
if [ "$ENGINE" != "docker" ] && command -v docker >/dev/null 2>&1; then
    RUN_PREFIX="CONTAINER_ENGINE=${ENGINE} "
fi
echo "    Run it with: ${RUN_PREFIX}${SCRIPT_DIR}/run-claude.sh [claude args...]"
