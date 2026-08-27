#!/usr/bin/env bash
#
# Entrypoint: initializes SDKMAN!/pyenv and starts claude straight away.
# Any arguments given to `docker run` are forwarded verbatim to claude,
# e.g. --agent <name>, --model, -p "...", --dangerously-skip-permissions.
#
# Escape hatch: `docker run ... claude-tools shell` opens bash instead of claude.

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
