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
    # `podman system service` serves the Docker-compatible API, and that API --
    # never the CLI -- is what Testcontainers, dockerode, docker-py and the
    # compose implementations actually talk to. It therefore has to be up before
    # the agent runs anything, which is why it is started here rather than left
    # to the agent. --time=0 keeps it alive when idle; without it the service
    # exits a few seconds after the last request.
    #
    # It is served over loopback TCP and not over a unix socket, and that is
    # measured rather than preferred. Claude's Bash tool runs inside bubblewrap,
    # and Claude Code's Linux sandbox refuses AF_UNIX outright at the seccomp
    # layer -- from a sandboxed Bash call every client got:
    #
    #   dial unix /run/user/1001/podman/podman.sock: socket: operation not permitted
    #
    # That is a blocked socket(2) and not a permission on a file: allowing
    # sandbox.filesystem.allowWrite over the runtime directory cleared the
    # `chmod ... read-only file system` error that came before it, and uncovered
    # this one underneath. No settings.json lifts it either --
    # sandbox.network.allowUnixSockets exists on macOS only. Loopback TCP does
    # pass the sandbox, and the whole chain was measured through it from inside
    # one: the port reachable, `podman --remote` answering over it, a container
    # spawned through that. So TCP is not a tidier spelling of the socket --
    # from the one place that matters the socket never worked at all, and the
    # `shell` hatch below, which runs outside the sandbox, is the only reason it
    # looked as though it did.
    #
    # What that costs, said here rather than left to be discovered: the socket
    # carried a permission gate in the filesystem -- it was `srw------- claude
    # claude`, so only this user could connect -- and a port carries none.
    # Anything in this container's network namespace can now drive the engine.
    # Inside this container that is a modest change, because the threat model
    # already accepts more: a container the agent starts is outside Claude's
    # sandbox anyway. It is still a real difference, not a wash.
    #
    # The port is a fixed 2375, which looks unsafe and is not. run-claude.sh
    # does not pass --network=host, so every claude container has its own
    # network namespace and therefore its own loopback -- measured: two
    # concurrent sessions each bound 127.0.0.1:2375 at the same time, neither
    # saw the other's service, and nothing was bound on the host at all. There
    # is no arbitration to do and no collision to avoid. --network host is the
    # one mode that would end that, by putting this listener on the host's
    # loopback among every other process on the machine, and run-claude.sh
    # refuses it under --containers for exactly this reason. 2375 is the
    # conventional Docker API port, chosen so that it is recognisable on sight
    # in a diagnostic.
    #
    # XDG_RUNTIME_DIR did not go with the socket. Rootless podman keeps its
    # runtime state under it -- the storage runroot, the pause process --
    # however the API is served, and wants the directory to be the user's own
    # and unreachable by anyone else. Section 8 of the Dockerfile creates it and
    # podman's tmpcopyup /run carries it into the running container, but
    # recreating it costs nothing and this does not have to depend on that. What
    # has gone is only the socket file, and the directory under it that had to
    # exist because bind(2) does not create parents.
    #
    # The mkdir and chmod are inside the background command so that their
    # output, and not only podman's, ends up in the log the diagnostic below
    # prints.
    PODMAN_SERVICE_HOST=127.0.0.1
    PODMAN_SERVICE_PORT=2375
    PODMAN_SERVICE_ADDR="tcp://$PODMAN_SERVICE_HOST:$PODMAN_SERVICE_PORT"
    PODMAN_SERVICE_LOG="/tmp/podman-service.log"
    PODMAN_SERVICE_TIMEOUT=15

    # `set -m` is not noise, do not delete it: without job control a background
    # command stays in this shell's process group, and the interactive bash of
    # the `shell` hatch below IS this shell -- the terminal's foreground process
    # group. A Ctrl-C at that prompt, clearing a half-typed line, would then go
    # to the service as well, which shuts down and stops listening. Nothing
    # would say so: the entrypoint is long gone, and CONTAINER_HOST and
    # DOCKER_HOST would still point at a port with nothing behind it. Job
    # control puts the service in a process group of its own, out of reach of
    # that signal, and is switched off again at once so nothing else changes.
    #
    # </dev/null is part of the same fix rather than a separate tidiness: bash
    # only redirects an async command's stdin from /dev/null while job control
    # is off, so with `set -m` the service would otherwise read the terminal in
    # competition with claude.
    set -m
    { mkdir -p "${XDG_RUNTIME_DIR:-}" \
        && chmod 700 "${XDG_RUNTIME_DIR:-}" \
        && exec podman system service --time=0 "$PODMAN_SERVICE_ADDR"; } \
        </dev/null >"$PODMAN_SERVICE_LOG" 2>&1 &
    PODMAN_SERVICE_PID=$!
    set +m

    # Readiness is a connection now, because there is no file to look for: a
    # listening port is only knowable by connecting to it. bash's /dev/tcp does
    # that with nothing installed -- no curl, no nc, no podman round-trip -- and
    # it is the same connect(2) a client will make. The connection is dropped
    # again immediately; the service sees a client that hung up before sending a
    # request.
    #
    # The subshell is load-bearing under `set -e`, not a habit: a failed
    # redirection on `exec` ends the shell that runs it, and a failed connection
    # is the expected answer for as long as the service is still starting, so it
    # has to end a shell that can be spared. errexit does not fire on the
    # non-zero result either -- both callers below put this in a condition,
    # where errexit is suspended for the whole list, function body included --
    # but that is a property of the callers, so do not move this call somewhere
    # its result is not tested.
    podman_api_reachable() {
        (exec 3<>"/dev/tcp/$PODMAN_SERVICE_HOST/$PODMAN_SERVICE_PORT") 2>/dev/null
    }

    # Wait for the service rather than sleeping a fixed amount: it is usually
    # listening in well under a second, but the first run against an empty
    # image-store volume has to initialize the store. The ceiling is generous
    # for that; the loop also stops the moment the service process is gone,
    # which is what a service that dies on startup does almost at once.
    waited=0
    while ! podman_api_reachable \
        && [ "$waited" -lt "$((PODMAN_SERVICE_TIMEOUT * 10))" ] \
        && kill -0 "$PODMAN_SERVICE_PID" 2>/dev/null; do
        sleep 0.1
        waited=$((waited + 1))
    done

    if podman_api_reachable && kill -0 "$PODMAN_SERVICE_PID" 2>/dev/null; then
        # Exported only now that the port answers AND the service behind it is
        # still there. The socket's stale-inode hazard -- a file outliving the
        # process that died after bind without unlinking -- has no counterpart
        # here, a listener dies with its process; the liveness check earns its
        # keep differently, as what tells "the loop ended because the API
        # answered" apart from "the loop ended because the service went away".
        #
        # CONTAINER_HOST points the podman CLI at the service; DOCKER_HOST is
        # not an engine choice but what foreign code -- Testcontainers,
        # dockerode, docker-py -- reads to find the Docker-compatible API.
        # Pointing either at an address with nothing behind it would turn "no
        # engine here" into a connection error against a port, which is harder
        # to read, so on failure they stay unset.
        export CONTAINER_HOST="$PODMAN_SERVICE_ADDR"
        export DOCKER_HOST="$PODMAN_SERVICE_ADDR"

        # The third variable is what serving the API over TCP costs a client,
        # and it is measured rather than pre-empted. Ryuk is Testcontainers'
        # reaper -- a sidecar that removes the containers a test process left
        # behind when it died -- and it reaches the engine by bind-mounting the
        # Docker socket into itself. There is no socket here, so podman tries to
        # create the path it was asked to mount and cannot, and a real suite run
        # in this container failed before it started anything:
        #
        #   (HTTP code 500) server error - make cli opts(): making volume
        #   mountpoint for volume /var/run/docker.sock: mkdir
        #   /var/run/docker.sock: permission denied
        #
        # With the reaper disabled the same suite got past that and reported its
        # container up on 127.0.0.1 with a mapped port.
        #
        # Turning a cleanup mechanism off deserves more than "it unblocked the
        # error", so: what makes it acceptable is this design specifically, not
        # Ryuk being unimportant. Ryuk reaps containers orphaned by a test
        # process that outlived its cleanup; here the engine itself is
        # ephemeral. The service is a child of this container, every container
        # it started dies with it, and nothing survives the session for a reaper
        # to find. A durable or shared engine would owe this a second look.
        #
        # Set on this branch only, like the two above: a session with no working
        # engine should not carry a variable implying one.
        export TESTCONTAINERS_RYUK_DISABLED=true
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
        echo "         nothing is listening on $PODMAN_SERVICE_ADDR, or the" >&2
        echo "         service that was listening there is gone" >&2
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

# Drop every capability before starting claude. Claude's sandbox is bubblewrap,
# and bubblewrap refuses to run at all while it holds capabilities without
# being setuid:
#
#   bwrap: Unexpected capabilities but not setuid, old file caps config?
#
# Under --containers this container is started with --cap-add=all -- the inner
# podman needs it to map its subuid range -- and podman hands an unprivileged
# user those capabilities through the ambient set, which every process in here
# then inherits. So bubblewrap fails on EVERY Bash call, a bare `echo` exactly
# like a `podman` one, and the agent's Bash tool can run nothing at all. Delete
# the exec below and that is the symptom, in a message that names bubblewrap
# and does not name this file.
#
# Capabilities are per-process, which is what makes this cost nothing: the API
# service further up was started before the drop and keeps its own set, so it
# can still map subuids and spawn containers while claude, and everything
# claude spawns, run with none. That split is this design rather than a
# workaround for it -- clients speak to the service over the API instead of
# driving the engine themselves.
#
# All three capability sets have to go. Ambient is how the capabilities arrive
# here in the first place, and clearing it is what leaves the exec'd process
# with an empty permitted and effective set; inheritable is the other route
# across an exec; the bounding set is what stops anything downstream regaining
# them. setpriv comes from util-linux, which is Essential in Debian and so is
# already in the image -- no package was added for this.
#
# The dry run against `true` is load-bearing rather than caution. Dropping the
# bounding set needs CAP_SETPCAP, so without --containers -- the ordinary run,
# where there are no capabilities to drop in the first place -- setpriv exits
# 127 with `setpriv: apply bounding set: Operation not permitted`. exec leaves
# no way back from that, and claude would simply never start on the commoner of
# the two paths. Trying the identical invocation first, and falling back to a
# plain exec, keeps that run exactly as it was, and covers a missing or broken
# setpriv on the same non-fatal principle as the service above: Claude without
# an engine is usable, Claude that does not start is not.
#
# This sits after the shell/bash/sh hatch above and not before it. The
# asymmetry is deliberate -- do not harmonise it away. That hatch is where a
# human debugs, `--containers shell` is the diagnostic path this feature is
# triaged from, and it is the capabilities that let the local podman CLI work
# there. Claude gets a clean environment; the debugging shell keeps its
# privilege.
CAP_DROP=(setpriv --inh-caps=-all --ambient-caps=-all --bounding-set=-all)
if ! "${CAP_DROP[@]}" true 2>/dev/null; then
    CAP_DROP=()
fi

exec "${CAP_DROP[@]}" claude "$@"
