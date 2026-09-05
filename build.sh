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
# runs as root -- sections 1 and 2 before the USER instruction, section 8 after
# switching back to root -- so a rootless `podman build` has root inside its own
# user namespace exactly where the build needs it.

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

# Rootless podman inside the image needs a subuid/subgid range for the image
# user, and that range has to lie inside the id space --userns=keep-id maps into
# the container -- which is the invoking user's own host range. Its width is a
# host fact that does not follow from the uid, so the Dockerfile cannot derive
# it: it is read here and passed in, and section 8 of the Dockerfile turns it
# into the range itself (START = uid + 1, COUNT = width - uid).
#
# Every range the user holds is summed, not just the first line: a user may have
# several, keep-id maps all of them, and taking only the first would under-count
# -- or, if that first line happens to be a narrow range, fail the check below on
# a perfectly well configured host. This is the sum of the count column, exactly
# as the spike derived it from /proc/self/uid_map.
#
# The first field is matched against both the login name and the numeric uid,
# because subuid(5) permits either. useradd writes the name, but provisioning
# tools sometimes write the uid, and on such a host matching only the name would
# report rootless podman as unconfigured when it is working perfectly. The first
# field of /etc/subgid is the *user* as well, so the uid is the right numeric
# alternative for both files.
HOST_USER="$(id -un)"
HOST_UID="$(id -u)"
SUBUID_WIDTH="$(awk -F: -v u="$HOST_USER" -v n="$HOST_UID" '($1 == u || $1 == n) && $3 ~ /^[0-9]+$/ { t += $3 } END { if (t) print t }' /etc/subuid 2>/dev/null || true)"
SUBGID_WIDTH="$(awk -F: -v u="$HOST_USER" -v n="$HOST_UID" '($1 == u || $1 == n) && $3 ~ /^[0-9]+$/ { t += $3 } END { if (t) print t }' /etc/subgid 2>/dev/null || true)"

# No entry means rootless podman is not set up for this user on this host, and
# no default can be guessed: a range outside the keep-id mapping makes newuidmap
# fail and every container the agent starts with it fails to start.
[[ -n "$SUBUID_WIDTH" ]] \
    || { echo "error: no entry for ${HOST_USER} (uid ${HOST_UID}) in /etc/subuid -- rootless podman is not set up on this host" >&2; exit 1; }
[[ -n "$SUBGID_WIDTH" ]] \
    || { echo "error: no entry for ${HOST_USER} (uid ${HOST_UID}) in /etc/subgid -- rootless podman is not set up on this host" >&2; exit 1; }

# What matters is not the total but the part of it above the uid, which is what
# section 8 hands to the image user. The threshold is 1000, the same one the
# spike gated on: postgres and rabbitmq drop to uid 999, so a range that does not
# reach that far builds fine and then maps nothing useful at run time.
(( SUBUID_WIDTH - USER_UID > 1000 )) \
    || { echo "error: the /etc/subuid ranges for ${HOST_USER} total ${SUBUID_WIDTH} ids, leaving only $((SUBUID_WIDTH - USER_UID)) above uid ${USER_UID}; more than 1000 are needed, since images that drop privileges land on uid 999" >&2; exit 1; }
(( SUBGID_WIDTH - USER_GID > 1000 )) \
    || { echo "error: the /etc/subgid ranges for ${HOST_USER} total ${SUBGID_WIDTH} ids, leaving only $((SUBGID_WIDTH - USER_GID)) above gid ${USER_GID}; more than 1000 are needed, since images that drop privileges land on gid 999" >&2; exit 1; }

echo "==> Building ${IMAGE_TAG}"
echo "    user   : ${USER_NAME} (uid=${USER_UID} gid=${USER_GID}, no sudo)"
echo "    node   : ${NODE_MAJOR}   claude: ${CLAUDE_VERSION}"
echo "    python : ${PYTHON_VERSION}   java: ${JAVA_VERSION}"
echo "    maven  : ${MAVEN_VERSION}   gradle: ${GRADLE_VERSION}"
echo "    subids : ${SUBUID_WIDTH} subuids, ${SUBGID_WIDTH} subgids (widths of ${HOST_USER}'s host ranges)"
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
    --build-arg "SUBUID_WIDTH=${SUBUID_WIDTH}" \
    --build-arg "SUBGID_WIDTH=${SUBGID_WIDTH}" \
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
