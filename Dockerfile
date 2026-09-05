# syntax=docker/dockerfile:1
#
# Claude Code toolbox image.
#
# Contains: claude (via npm), node/npm, SDKMAN! (Java), pyenv (Python) and the
# usual CLI tooling. The user created here is NOT a sudoer -- the sudo package
# is never installed in the image at all.
#
# Build:
#   ./build.sh                (picks up the current user's uid/gid automatically)
#
#   By hand, the equivalent. --format docker is not optional: podman ignores the
#   SHELL instruction in OCI format, and section 6 depends on it. The two width
#   args carry the width of this host's subordinate id ranges, which section 8
#   turns into the image user's own range and cannot derive from the uid.
#     u=$(id -un); n=$(id -u)
#     podman build --format docker \
#       --build-arg USER_UID=$n --build-arg USER_GID=$(id -g) \
#       --build-arg SUBUID_WIDTH=$(awk -F: -v u="$u" -v n="$n" '$1==u||$1==n{t+=$3} END{print t}' /etc/subuid) \
#       --build-arg SUBGID_WIDTH=$(awk -F: -v u="$u" -v n="$n" '$1==u||$1==n{t+=$3} END{print t}' /etc/subgid) \
#       -t claude-tools .

FROM debian:trixie-slim

ARG USER_NAME=claude
ARG USER_UID=1000
ARG USER_GID=1000

# Pass "none" to skip the corresponding installation.
ARG NODE_MAJOR=22
ARG CLAUDE_VERSION=latest
ARG PYTHON_VERSION=3.12.7
ARG JAVA_VERSION=21.0.5-tem
ARG MAVEN_VERSION=none
ARG GRADLE_VERSION=none

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# SDKMAN!'s init script is bash-only, and pipefail makes `curl | bash` fail loudly.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# ---------------------------------------------------------------------------
# 1. Base system packages plus the build dependencies pyenv needs.
#    bubblewrap and socat are what Claude Code's own sandbox needs on Linux
#    (filesystem isolation and the network filter respectively). They also
#    require the container to be started with the security options that run-claude.sh
#    passes -- see the Sandbox section of the README.
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl wget gnupg \
        git openssh-client \
        bash zip unzip xz-utils \
        build-essential pkg-config \
        libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev \
        libncurses-dev tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev \
        procps less vim-tiny nano jq ripgrep fd-find locales tzdata \
        bubblewrap socat \
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# 2. Node.js and npm (NodeSource)
# ---------------------------------------------------------------------------
RUN curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g npm@latest

# ---------------------------------------------------------------------------
# 3. Unprivileged user (no sudo)
#    The uid/gid come from build args so that bind mounts keep the right owner.
# ---------------------------------------------------------------------------
RUN if getent group "${USER_GID}" >/dev/null; then \
            groupmod -n "${USER_NAME}" "$(getent group "${USER_GID}" | cut -d: -f1)"; \
        else \
            groupadd -g "${USER_GID}" "${USER_NAME}"; \
        fi \
    && if getent passwd "${USER_UID}" >/dev/null; then \
            usermod -l "${USER_NAME}" -d "/home/${USER_NAME}" -m -s /bin/bash \
                    "$(getent passwd "${USER_UID}" | cut -d: -f1)"; \
        else \
            useradd -u "${USER_UID}" -g "${USER_GID}" -m -s /bin/bash "${USER_NAME}"; \
        fi \
    && mkdir -p "/home/${USER_NAME}/.claude" /workspace \
    && chown -R "${USER_UID}:${USER_GID}" "/home/${USER_NAME}" /workspace

ENV USER_NAME=${USER_NAME} \
    HOME=/home/${USER_NAME}

USER ${USER_UID}:${USER_GID}
WORKDIR /home/${USER_NAME}

ENV NPM_CONFIG_PREFIX=${HOME}/.npm-global \
    PYENV_ROOT=${HOME}/.pyenv \
    SDKMAN_DIR=${HOME}/.sdkman
ENV PATH=${HOME}/.npm-global/bin:${HOME}/.local/bin:${PYENV_ROOT}/shims:${PYENV_ROOT}/bin:${SDKMAN_DIR}/candidates/java/current/bin:${SDKMAN_DIR}/candidates/maven/current/bin:${SDKMAN_DIR}/candidates/gradle/current/bin:${PATH}

# ---------------------------------------------------------------------------
# 4. Claude Code (npm, into a user-level prefix so root is never needed)
#    npm 11 blocks install scripts by default, and claude's postinstall is what
#    fetches the platform-native binary -- hence the explicit allow-scripts and
#    the manual install.cjs fallback for npm versions without that flag.
# ---------------------------------------------------------------------------
RUN set -e; \
    mkdir -p "${HOME}/.npm-global"; \
    npm config set allow-scripts="@anthropic-ai/claude-code" --location=user || true; \
    npm install -g "@anthropic-ai/claude-code@${CLAUDE_VERSION}"; \
    claude --version \
      || node "${HOME}/.npm-global/lib/node_modules/@anthropic-ai/claude-code/install.cjs"; \
    claude --version

# ---------------------------------------------------------------------------
# 5. pyenv (plus an optional default Python version)
# ---------------------------------------------------------------------------
RUN git clone --depth 1 https://github.com/pyenv/pyenv.git "${PYENV_ROOT}" \
    && git clone --depth 1 https://github.com/pyenv/pyenv-virtualenv.git \
           "${PYENV_ROOT}/plugins/pyenv-virtualenv" \
    && if [ "${PYTHON_VERSION}" != "none" ]; then \
           pyenv install "${PYTHON_VERSION}" \
        && pyenv global "${PYTHON_VERSION}" \
        && pyenv rehash \
        && python -m pip install --no-cache-dir --upgrade pip setuptools wheel virtualenv; \
       fi

# ---------------------------------------------------------------------------
# 6. SDKMAN! (plus optional Java / Maven / Gradle candidates)
# ---------------------------------------------------------------------------
#    `sdk` runs pipelines that return non-zero on success, so errexit/pipefail
#    are turned off around it and the result is verified explicitly afterwards.
RUN set -e; \
    curl -fsSL "https://get.sdkman.io?rcupdate=false" | bash; \
    set +e +o pipefail; \
    . "${SDKMAN_DIR}/bin/sdkman-init.sh"; \
    sdk update; \
    for pair in "java:${JAVA_VERSION}" "maven:${MAVEN_VERSION}" "gradle:${GRADLE_VERSION}"; do \
        candidate="${pair%%:*}"; version="${pair#*:}"; \
        if [ "${version}" != "none" ]; then sdk install "${candidate}" "${version}"; fi; \
    done; \
    sdk flush temp; \
    set -e; \
    if [ "${JAVA_VERSION}"   != "none" ]; then java -version;  fi; \
    if [ "${MAVEN_VERSION}"  != "none" ]; then mvn --version;  fi; \
    if [ "${GRADLE_VERSION}" != "none" ]; then gradle --version; fi

# ---------------------------------------------------------------------------
# 7. Shell initialization.
#    Debian's stock .bashrc returns early for non-interactive shells, so the
#    init lives in its own file: prepended to .bashrc for interactive shells and
#    exported as BASH_ENV for `bash -c` invocations. `sdk` in particular is a
#    shell function and is unavailable unless the file is sourced.
# ---------------------------------------------------------------------------
RUN { \
      echo '# Environment for the claude-tools image -- see the Dockerfile.'; \
      echo 'export NPM_CONFIG_PREFIX="$HOME/.npm-global"'; \
      echo 'export PYENV_ROOT="$HOME/.pyenv"'; \
      echo 'export SDKMAN_DIR="$HOME/.sdkman"'; \
      echo 'export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$PYENV_ROOT/bin:$PATH"'; \
      echo ''; \
      echo '# pyenv shims are already on PATH from the image, so only interactive'; \
      echo '# shells pay for the full init (completion plus the `pyenv shell` command).'; \
      echo 'case $- in'; \
      echo '    *i*)'; \
      echo '        command -v pyenv >/dev/null && eval "$(pyenv init -)"'; \
      echo '        command -v pyenv >/dev/null && eval "$(pyenv virtualenv-init -)" 2>/dev/null'; \
      echo '        ;;'; \
      echo 'esac'; \
      echo ''; \
      echo '[ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ] && . "$SDKMAN_DIR/bin/sdkman-init.sh"'; \
      echo ''; \
      echo '# Always succeed: this file is a BASH_ENV target for `set -e` scripts.'; \
      echo ':'; \
    } > "${HOME}/.claude-tools-env.sh" \
    && { echo '. "$HOME/.claude-tools-env.sh"'; cat "${HOME}/.bashrc"; } > /tmp/bashrc \
    && mv /tmp/bashrc "${HOME}/.bashrc"

ENV BASH_ENV=${HOME}/.claude-tools-env.sh

# ---------------------------------------------------------------------------
# 8. Rootless podman, so that the agent can start containers from inside this
#    one -- a foreign repository's Testcontainers or compose fixtures, and
#    ad-hoc verification of code under development.
#
#    Placement: this section needs root, yet it deliberately sits AFTER sections
#    4-7 instead of next to the other root work. Sections 4-6 install Claude
#    Code, compile CPython under pyenv and install SDKMAN!, which together cost
#    5-10 minutes; putting podman before them would rebuild all of it every time
#    a package here changes. The price of this order is one extra pair of USER
#    instructions and nothing else -- do not "tidy" it back up next to the USER
#    instruction of section 3.
#
#    What the agent gets is a *child* container, in this container's mount and
#    network namespaces. It can only bind-mount paths that exist in here, so the
#    host filesystem is out of reach by construction rather than by policy, and
#    a published port lands on the same localhost as the test process. The
#    devices and capabilities this needs do not exist in run-claude.sh yet: a
#    later step (S7) adds an opt-in --containers flag that grants them. Until it
#    lands, the packages below are installed but inert.
#
#    Each package, and what it buys:
#      podman          the engine, and `podman system service`, which serves the
#                      Docker-compatible API. Testcontainers, dockerode and
#                      docker-py all speak that socket and never the CLI, so the
#                      service is what foreign test suites actually talk to.
#      uidmap          the setuid-root newuidmap/newgidmap helpers. Without them
#                      rootless podman cannot map the subordinate id range set
#                      up below, and every image that drops privileges
#                      (postgres and rabbitmq both fall to uid 999) fails to
#                      start -- only single-uid containers would work.
#      fuse-overlayfs  the portable way to get the `overlay` storage driver
#                      unprivileged, and this image pins it deliberately.
#                      Kernels from 5.11 can mount overlayfs inside a user
#                      namespace, but setting mount_program below makes
#                      c/storage skip that probe altogether, so this image
#                      always goes through FUSE -- portability bought at the
#                      cost of native overlay even where the kernel offers it.
#                      Being a FUSE filesystem it needs /dev/fuse in this
#                      container; `vfs` is the documented fallback when the
#                      device is not there -- correct, but it copies every
#                      layer, so first starts are slow and the store is much
#                      larger.
#      passt           rootless networking (pasta), which is what publishes a
#                      spawned container's ports. Needs /dev/net/tun.
#      slirp4netns     the older rootless network backend, kept as the fallback
#                      for hosts where pasta does not work. It is NOT the
#                      answer to a missing /dev/net/tun -- both backends need
#                      that device.
#      nftables        netavark, which podman hard-depends on, shells out to
#                      `nft` to set up a user-defined network. Measured, not
#                      assumed: without it `podman run --network <net>` dies
#                      with `netavark: nftables error: unable to execute nft:
#                      No such file or directory` and the container never
#                      starts. iptables is deliberately not installed --
#                      nftables is the backend netavark actually used here.
#      aardvark-dns    name resolution between containers on a user-defined
#                      network. Without it netavark only warns ("container dns
#                      will not be enabled") and carries on, so the failure
#                      surfaces later as one compose service unable to resolve
#                      another by name.
#
#                      nftables and aardvark-dns are both Recommends of
#                      *netavark* rather than of podman, so the
#                      --no-install-recommends on the apt line below drops
#                      them and they have to be named explicitly. Every
#                      compose project creates a user-defined network, so on a
#                      compose file the two fail differently and that is the
#                      whole triage: without nftables nothing starts at all,
#                      while without aardvark-dns the services come up and only
#                      resolving one another by name fails. Either way the
#                      symptom reads as broken compose support rather than as a
#                      missing package.
#      catatonit       the minimal init process podman runs for `--init`, so a
#                      spawned container reaps its own zombies.
#
#    No compose implementation here: that is added separately and extends this
#    section. podman-docker is a different case -- it is not missing but
#    rejected, and is never to be installed: the agent is told podman is the
#    only engine, so a `docker` shim buys nothing.
# ---------------------------------------------------------------------------
USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
        podman uidmap fuse-overlayfs passt slirp4netns catatonit \
        nftables aardvark-dns \
    && rm -rf /var/lib/apt/lists/*

#    Subordinate id ranges for the image user. The customary
#    `claude:100000:65536` is wrong here: the ids have to exist inside the
#    mapping that run-claude.sh's --userns=keep-id gives this container, which
#    is carved out of the *invoking* user's own host range, and a nested user
#    namespace can only map ids its parent already maps. Under keep-id the
#    container sees TOTAL = WIDTH + 1 ids -- the host range, plus the single id
#    the invoking user's own uid maps to -- and that one id is USER_UID itself,
#    which is taken and cannot be handed out again. So the range starts just
#    above it and runs to the end of what is mapped:
#
#        START = USER_UID + 1
#        COUNT = TOTAL - START = (WIDTH + 1) - (USER_UID + 1) = WIDTH - USER_UID
#
#    WIDTH does not follow from the uid, so the Dockerfile cannot know it:
#    build.sh reads it from the host's /etc/subuid and /etc/subgid and passes it
#    in (a hand-rolled `podman build` must do the same). Uid and gid come from
#    two different files, and their widths are summed per file because a user
#    may hold more than one subordinate range and keep-id maps all of them; the
#    two totals are not assumed equal. The RUN below re-checks both the widths
#    and the counts they produce, because a direct `podman build` bypasses
#    build.sh's checks and a range too narrow to use yields an image that builds
#    cleanly and then fails at run time with `newuidmap: write to uid_map
#    failed` -- the hardest symptom in this design to triage.
#
#    The threshold is 1000 rather than 0, and that is the number the spike gated
#    on too: postgres and rabbitmq both drop to uid 999, so a range that does not
#    reach that far maps nothing useful. A range of, say, 40 ids is arithmetically
#    valid and practically dead.
#
#    Worked through on a host with uid 1001, gid 1003 and both ranges 65536
#    wide, the formula yields a uid range starting at 1002 for 64535 ids and a
#    gid range starting at 1004 for 64533 -- exactly the mapping measured from
#    /proc/self/uid_map inside the running container.
#
#    The two files are rewritten, not appended to: useradd in section 3 may have
#    handed the user a 100000-based range of its own, which is outside the
#    mapping and would make newuidmap fail.
#
#    The build args are declared here rather than in the block at the top of the
#    file so that a change to them cannot invalidate sections 1-7.
ARG SUBUID_WIDTH
ARG SUBGID_WIDTH

RUN set -e; \
    : "${SUBUID_WIDTH:?width of the /etc/subuid range on the build host, normally supplied by build.sh -- see section 8}"; \
    : "${SUBGID_WIDTH:?width of the /etc/subgid range on the build host, normally supplied by build.sh -- see section 8}"; \
    subuid_count=$((SUBUID_WIDTH - USER_UID)); \
    subgid_count=$((SUBGID_WIDTH - USER_GID)); \
    [ "${subuid_count}" -gt 1000 ] \
      || { echo "SUBUID_WIDTH=${SUBUID_WIDTH} leaves only ${subuid_count} subordinate uids above uid ${USER_UID}; more than 1000 are needed, since images that drop privileges land on uid 999" >&2; exit 1; }; \
    [ "${subgid_count}" -gt 1000 ] \
      || { echo "SUBGID_WIDTH=${SUBGID_WIDTH} leaves only ${subgid_count} subordinate gids above gid ${USER_GID}; more than 1000 are needed, since images that drop privileges land on gid 999" >&2; exit 1; }; \
    echo "${USER_NAME}:$((USER_UID + 1)):${subuid_count}" > /etc/subuid; \
    echo "${USER_NAME}:$((USER_GID + 1)):${subgid_count}" > /etc/subgid

#    Engine, storage and registry configuration. All three files live under
#    /etc/containers, and they are read by three different rules -- which
#    matters, because it decides whether writing one destroys what was there:
#
#      containers.conf  is MERGED, key by key, over the packaged defaults in
#                       /usr/share/containers, and anything in
#                       ~/.config/containers would in turn merge over this file.
#                       So the two keys below are additions, not a replacement.
#      storage.conf     is SELECTED, not layered: podman reads the single
#                       highest-precedence file that exists and ignores the
#                       others entirely (see containers-storage.conf(5)). A user
#                       file in ~/.config/containers would therefore replace
#                       this one wholesale rather than extend it.
#      registries.conf  genuinely LAYERS through its drop-in directory: every
#                       *.conf in registries.conf.d is applied over the main
#                       file, in lexical order. That is why the registry setting
#                       below is a drop-in rather than an edit of the packaged
#                       registries.conf -- nothing shipped is replaced, and the
#                       packaged shortname aliases keep working.
#
#    None of the three has a per-user counterpart in this image, so all three
#    are what the rootless user actually gets. /etc is also outside every mount
#    run-claude.sh makes by default -- /workspace, ~/.claude, ~/.claude.json,
#    ~/.gitconfig, and the image-store volume S7 will add under ~/.local/share.
#    (Its --mount flag takes an arbitrary src:dst and is repeatable, so "cannot
#    be shadowed" would be too strong; nothing shadows it unless someone asks
#    for that.)
#
#      cgroup_manager = "cgroupfs"   there is no systemd in this container for a
#                                    systemd cgroup manager to talk to.
#                                    containers/common probes for
#                                    /run/systemd/system and would very likely
#                                    pick cgroupfs here by itself; it is pinned
#                                    so the behaviour does not depend on a
#                                    run-time probe.
#      events_logger  = "file"       same shape of reason: the journald backend
#                                    wants a journal socket, which is probed for
#                                    in the same way. Pinned for the same reason.
#      driver         = "overlay"    with fuse-overlayfs as the mount program,
#                                    so that overlay works unprivileged on
#                                    kernels that cannot mount it in a user
#                                    namespace. If /dev/fuse is unavailable, the
#                                    documented fallback is driver = "vfs" (see
#                                    above).
#
#    graphroot and runroot are deliberately NOT set, so podman keeps its
#    rootless defaults. Measured in the built container:
#
#      graphroot = /home/claude/.local/share/containers/storage
#      runroot   = /run/user/1001/containers
#
#    S7 will mount a named image-store volume one level above the graphroot, on
#    ~/.local/share/containers, and that is what will keep pulled images between
#    runs. The volume is not merely an optimisation -- fuse-overlayfs
#    cannot stack on this container's own overlayfs, so the inner store has to
#    sit on a real filesystem.
#
#    unqualified-search-registries. Debian ships registries.conf with this key
#    commented out, and its shortnames list has no alias for the images a test
#    fixture actually names, so an unqualified pull fails outright -- measured
#    on the built image:
#
#      $ podman pull postgres:16
#      Error: short-name "postgres:16" did not resolve to an alias and no
#      unqualified-search registries are defined in
#      "/etc/containers/registries.conf"
#
#    A foreign compose file saying `image: postgres:16`, and Testcontainers' own
#    unqualified defaults, both die exactly there. The spike never hit it
#    because its procedure writes docker.io/library/postgres:16 fully qualified
#    throughout.
RUN mkdir -p /etc/containers /etc/containers/registries.conf.d \
    && { \
      echo '# claude-tools -- see section 8 of the Dockerfile.'; \
      echo '[engine]'; \
      echo 'cgroup_manager = "cgroupfs"'; \
      echo 'events_logger = "file"'; \
    } > /etc/containers/containers.conf \
    && { \
      echo '# claude-tools -- see section 8 of the Dockerfile.'; \
      echo '[storage]'; \
      echo 'driver = "overlay"'; \
      echo ''; \
      echo '[storage.options.overlay]'; \
      echo 'mount_program = "/usr/bin/fuse-overlayfs"'; \
    } > /etc/containers/storage.conf \
    && { \
      echo '# claude-tools -- see section 8 of the Dockerfile.'; \
      echo 'unqualified-search-registries = ["docker.io"]'; \
    } > /etc/containers/registries.conf.d/01-claude-tools.conf

#    XDG_RUNTIME_DIR. Rootless podman keeps its runtime state under it -- the
#    API socket, the storage runroot, the pause process -- and refuses to run
#    without one; it must also be owned by the user. Mode 0700 is not tidiness:
#    the API service's socket lives in here, and anyone who can reach that
#    socket drives the engine.
#
#    Podman mounts /run as a tmpfs with tmpcopyup, which copies the image's
#    existing /run content up into it, so the directory created here does
#    survive into the running container -- measured as
#    `drwx------ claude claude /run/user/1001`. It is created here for that
#    reason and not as a best effort. (If a future engine or option mounts /run
#    without tmpcopyup, the directory would be lost and the entrypoint would have
#    to recreate it; nothing in the tree does that today.)
RUN mkdir -p "/run/user/${USER_UID}" \
    && chown "${USER_UID}:${USER_GID}" "/run/user/${USER_UID}" \
    && chmod 700 "/run/user/${USER_UID}"

ENV XDG_RUNTIME_DIR=/run/user/${USER_UID}

USER ${USER_UID}:${USER_GID}

COPY --chown=${USER_UID}:${USER_GID} docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD []
