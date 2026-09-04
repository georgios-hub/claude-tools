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
#
# podman is the only supported engine and has to be on PATH; there is no docker
# fallback. The Dockerfile uses no BuildKit-only features, and every apt-get
# runs before the USER instruction, so a rootless `podman build` has root
# inside its own user namespace exactly where the build needs it.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

IMAGE_TAG="${CLAUDE_TOOLS_IMAGE:-claude-tools:latest}"
USER_NAME="${CLAUDE_TOOLS_USER:-claude}"
USER_UID="$(id -u)"
USER_GID="$(id -g)"

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

# podman is the only engine this image is built and run with: a docker-built
# image lands in docker's store, which a podman-only run-claude.sh never reads.
command -v podman >/dev/null 2>&1 \
    || { echo "error: podman is not on PATH" >&2; exit 1; }

echo "==> Building ${IMAGE_TAG}"
echo "    user   : ${USER_NAME} (uid=${USER_UID} gid=${USER_GID}, no sudo)"
echo "    node   : ${NODE_MAJOR}   claude: ${CLAUDE_VERSION}"
echo "    python : ${PYTHON_VERSION}   java: ${JAVA_VERSION}"
echo "    maven  : ${MAVEN_VERSION}   gradle: ${GRADLE_VERSION}"
echo

# The Dockerfile sets SHELL to bash so that SDKMAN!'s bash-only init script can be
# sourced and pipefail applies to the `curl | bash` pipelines. SHELL is a Docker
# format instruction: podman builds OCI by default, silently ignores it, and falls
# back to /bin/sh -- where `set -o pipefail` and `source` do not exist and the
# SDKMAN! step fails. Asking podman for the docker format keeps SHELL effective.
podman build \
    --format docker \
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
echo "    Run it with: ${SCRIPT_DIR}/run-claude.sh [claude args...]"
