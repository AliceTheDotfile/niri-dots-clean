#!/usr/bin/env bash
#
# Alice's Niri dots - tiny Python bootstrap
#
# The actual installer lives in install.py.
#
# Local:
#   ./install.sh
#
# Remote:
#   curl -fsSL https://raw.githubusercontent.com/AliceTheDotfile/niri-dots-clean/main/install.sh | bash
#

set -Eeuo pipefail

readonly RAW_URL="https://raw.githubusercontent.com/AliceTheDotfile/niri-dots-clean/main/install.py"

TMP_DIR=""
SCRIPT_PATH=""

cleanup() {
    if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
        rm -rf -- "$TMP_DIR"
    fi
}

trap cleanup EXIT INT TERM

# Local repository: use the Python installer directly.
if [[ -f "$(dirname "${BASH_SOURCE[0]}")/install.py" ]]; then
    command -v python3 >/dev/null 2>&1 || {
        if command -v sudo >/dev/null 2>&1 && command -v pacman >/dev/null 2>&1; then
            sudo pacman -Syu --needed --noconfirm python
        else
            printf 'error: python3 is required, and pacman/sudo are unavailable\n' >&2
            exit 1
        fi
    }

    exec python3 "$(dirname "${BASH_SOURCE[0]}")/install.py" "$@"
fi

command -v curl >/dev/null 2>&1 || {
    printf 'error: curl is required for the one-line installer\n' >&2
    exit 1
}

# A remote invocation may be happening on a minimal Arch install.
# Bootstrap Python with pacman before downloading the Python program.
if ! command -v python3 >/dev/null 2>&1; then
    command -v pacman >/dev/null 2>&1 || {
        printf 'error: pacman is required to bootstrap Python\n' >&2
        exit 1
    }

    command -v sudo >/dev/null 2>&1 || {
        printf 'error: sudo is required to bootstrap Python\n' >&2
        exit 1
    }

    sudo pacman -Syu --needed --noconfirm python
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/alice-niri-installer.XXXXXXXX")"
SCRIPT_PATH="$TMP_DIR/install.py"

printf "\033[38;5;205m::\033[0m downloading Alice\047s Python installer...\n"

curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --retry 3 \
    --retry-delay 1 \
    "$RAW_URL" \
    -o "$SCRIPT_PATH"

python3 "$SCRIPT_PATH" "$@"
