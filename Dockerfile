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
#   docker build --build-arg USER_UID=$(id -u) --build-arg USER_GID=$(id -g) -t claude-tools .

FROM debian:bookworm-slim

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
        libncursesw5-dev tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev \
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

COPY --chown=${USER_UID}:${USER_GID} docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD []
