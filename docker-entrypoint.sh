#!/usr/bin/env bash
#
# Entrypoint: initializes SDKMAN!/pyenv and starts claude straight away.
# Any arguments given to `run-claude.sh` are forwarded verbatim to claude,
# e.g. --agent <name>, --model, -p "...", --dangerously-skip-permissions.
# With CLAUDE_TOOLS_CONTAINERS=1 it starts podman's API service first.
#
# Escape hatch: `./run-claude.sh shell` opens bash instead of claude.

set -euo pipefail

export PYENV_ROOT="${PYENV_ROOT:-$HOME/.pyenv}"
export SDKMAN_DIR="${SDKMAN_DIR:-$HOME/.sdkman}"

if command -v pyenv >/dev/null 2>&1; then
    eval "$(pyenv init -)"
fi

if [ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]; then
    set +u
    # shellcheck disable=SC1091
    . "$SDKMAN_DIR/bin/sdkman-init.sh"
    set -u
fi

# The bind mount of the host's ~/.claude may not carry an agents directory.
mkdir -p "$HOME/.claude" 2>/dev/null || true

# Container spawning, opt-in: run-claude.sh --containers passes
# CLAUDE_TOOLS_CONTAINERS=1 together with the capability, devices and image-store
# volume the inner podman needs. Unset, or any other value, and nothing below
# happens and this image behaves exactly as it did before.
if [ "${CLAUDE_TOOLS_CONTAINERS:-}" = "1" ]; then
    # `podman system service` serves the Docker-compatible API over a unix
    # socket, and that socket -- never the CLI -- is what Testcontainers,
    # dockerode, docker-py and the compose implementations actually talk to. It
    # therefore has to exist before the agent runs anything, which is why it is
    # started here rather than left to the agent. --time=0 keeps it alive when
    # idle; without it the service exits a few seconds after the last request.
    #
    # Rootless podman keeps its runtime state under XDG_RUNTIME_DIR and wants
    # the directory to be the user's own and unreachable by anyone else -- the
    # socket lives in it, and whoever can reach the socket drives the engine.
    # Section 8 of the Dockerfile creates it and podman's tmpcopyup /run carries
    # it into the running container, but recreating it costs nothing and this
    # does not have to depend on that.
    #
    # Both levels are created, and the socket's own directory is the one that
    # bites: the service binds the socket, and bind(2) does not create parent
    # directories, so without $XDG_RUNTIME_DIR/podman the service dies at once
    # with `bind: no such file or directory`. It is derived from the socket path
    # rather than spelled out again, so the two cannot drift apart. Mode 0700 on
    # it is redundant while its parent is 0700 -- nobody else can traverse there
    # -- but it keeps the guarantee off a single directory's mode, and that
    # parent is created by the Dockerfile and carried in by a tmpcopyup mount
    # rather than by anything here.
    #
    # The mkdir and chmod are inside the background command so that their
    # output, and not only podman's, ends up in the log the diagnostic below
    # prints.
    PODMAN_SOCKET="${XDG_RUNTIME_DIR:-}/podman/podman.sock"
    PODMAN_SOCKET_DIR="$(dirname "$PODMAN_SOCKET")"
    PODMAN_SERVICE_LOG="/tmp/podman-service.log"
    PODMAN_SERVICE_TIMEOUT=15

    # `set -m` is not noise, do not delete it: without job control a background
    # command stays in this shell's process group, and the interactive bash of
    # the `shell` hatch below IS this shell -- the terminal's foreground process
    # group. A Ctrl-C at that prompt, clearing a half-typed line, would then go
    # to the service as well, which shuts down and unlinks its socket. Nothing
    # would say so: the entrypoint is long gone, and CONTAINER_HOST and
    # DOCKER_HOST would still point at a path with nothing behind it. Job
    # control puts the service in a process group of its own, out of reach of
    # that signal, and is switched off again at once so nothing else changes.
    #
    # </dev/null is part of the same fix rather than a separate tidiness: bash
    # only redirects an async command's stdin from /dev/null while job control
    # is off, so with `set -m` the service would otherwise read the terminal in
    # competition with claude.
    set -m
    { mkdir -p "$PODMAN_SOCKET_DIR" \
        && chmod 700 "${XDG_RUNTIME_DIR:-}" "$PODMAN_SOCKET_DIR" \
        && exec podman system service --time=0 "unix://$PODMAN_SOCKET"; } \
        </dev/null >"$PODMAN_SERVICE_LOG" 2>&1 &
    PODMAN_SERVICE_PID=$!
    set +m

    # Wait for the socket rather than sleeping a fixed amount: the service is
    # usually listening in well under a second, but the first run against an
    # empty image-store volume has to initialize the store. The ceiling is
    # generous for that; the loop also stops the moment the service process is
    # gone, which is what a service that dies on startup does almost at once.
    waited=0
    while [ ! -S "$PODMAN_SOCKET" ] \
        && [ "$waited" -lt "$((PODMAN_SERVICE_TIMEOUT * 10))" ] \
        && kill -0 "$PODMAN_SERVICE_PID" 2>/dev/null; do
        sleep 0.1
        waited=$((waited + 1))
    done

    if [ -S "$PODMAN_SOCKET" ] && kill -0 "$PODMAN_SERVICE_PID" 2>/dev/null; then
        # Exported only now that the socket is there AND the service behind it
        # still is -- an inode outlives a process that died after bind without
        # unlinking, and pointing the variables at that is the very thing this
        # is meant to avoid. CONTAINER_HOST
        # points the podman CLI at the service; DOCKER_HOST is not an engine
        # choice but what foreign code -- Testcontainers, dockerode, docker-py --
        # reads to find the Docker-compatible API. Pointing either at a socket
        # that does not exist would turn "no engine here" into a connection
        # error against a path, which is harder to read, so on failure they stay
        # unset.
        export CONTAINER_HOST="unix://$PODMAN_SOCKET"
        export DOCKER_HOST="unix://$PODMAN_SOCKET"
    else
        # Not fatal, deliberately. Claude is perfectly usable without an engine,
        # and a container that refused to start would be a far worse outcome
        # than one that cannot spawn containers -- but a silent failure would
        # surface later as "could not find a valid Docker environment", which
        # reads as a broken repository rather than a missing engine.
        #
        # The service's own output comes first, because it is the line that
        # actually diagnoses this: podman names the cause precisely, and every
        # guess made here is only a guess. The causes below are offered as
        # possibilities for when it does not, never as a verdict.
        # A service that has merely been slow is deliberately not killed here.
        # It may be part-way through initializing the image store, which lives
        # on a volume that outlives this container, and interrupting that is a
        # worse risk than leaving a process running that nothing points at. So
        # the message says what is actually known -- the variables are unset --
        # rather than that the service will never arrive.
        echo "warning: the podman API service was not ready within ${PODMAN_SERVICE_TIMEOUT}s --" >&2
        echo "         no socket at $PODMAN_SOCKET, or the service behind it is gone" >&2
        echo "         CONTAINER_HOST and DOCKER_HOST are therefore left unset, so" >&2
        echo "         nothing will find an engine; claude itself is unaffected" >&2
        if [ -s "$PODMAN_SERVICE_LOG" ]; then
            echo "         what the service wrote:" >&2
            sed 's/^/         | /' "$PODMAN_SERVICE_LOG" >&2 || true
        else
            echo "         the service wrote nothing" >&2
        fi
        echo "         possible causes, if that does not name it outright:" >&2
        echo "         - CLAUDE_TOOLS_CONTAINERS=1 was set by hand rather than by" >&2
        echo "           run-claude.sh --containers, so the capability, the devices and" >&2
        echo "           the image-store volume the service needs were never granted" >&2
        echo "         - \"newuidmap: write to uid_map failed: Operation not permitted\"" >&2
        echo "           is the capability case: --cap-add=all missing, or subuid ranges" >&2
        echo "           outside the mapping --userns=keep-id gives this container" >&2
        echo "         - anything the mkdir or chmod above reported -- the runtime" >&2
        echo "           directory could not be created, or is not this user's own" >&2
    fi
fi

case "${1:-}" in
    shell|bash)
        shift
        exec bash "$@"
        ;;
    sh)
        shift
        exec sh "$@"
        ;;
esac

exec claude "$@"
