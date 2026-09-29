
#!/usr/bin/env bash
#
# Alice's Niri dotfiles installer
#
# Usage:
#   ./install.sh
#   ./install.sh --fresh
#   ./install.sh --minimal
#   ./install.sh --update
#   ./install.sh --configs-only
#   ./install.sh --packages-only
#   ./install.sh --dry-run
#   ./install.sh --no-deps
#   ./install.sh --no-tui
#
# ============================================================
# IMPORTANT
# ============================================================
#
# WAYBAR:
#   NEVER installed
#   NEVER copied
#   NEVER backed up
#   NEVER verified
#
# FASTFETCH:
#   Application may be installed.
#   ~/.config/fastfetch is NEVER touched.
#
# KATE:
#   Reusable configuration is installed:
#       ~/.config/kate
#       ~/.config/katerc
#       ~/.config/katevirc
#       ~/.config/katemetainfos
#
#   Kate session files are NOT installed.
#
# PATH:
#   ~/.local/bin is added only when it is not already in PATH.
#
# BACKUPS:
#   Existing files are moved to:
#       ~/.dotfiles-backup/<timestamp>/
#
# UPDATE:
#   Local git checkout:
#       git pull --ff-only
#
#   curl | bash:
#       downloads the latest GitHub repository snapshot
#
# FRESH MODE:
#   Intended for a bare Arch installation.
#   Installs/configures:
#       Niri
#       Quickshell
#       Kate
#       Wallfliper
#       useful applications
#       greetd
#       greetd-tuigreet
#       NetworkManager
#       Bluetooth
#
# ============================================================

set -Eeuo pipefail

# ============================================================
# Paths / repository bootstrap
# ============================================================

readonly REPO_URL="https://github.com/AliceTheDotfile/niri-dots-clean"
readonly REPO_ARCHIVE_URL="https://codeload.github.com/AliceTheDotfile/niri-dots-clean/tar.gz/refs/heads/main"

# When running from a real checkout, DOTFILES points to that repo.
# When running through curl | bash, the complete repo is downloaded
# into a temporary directory and DOTFILES is changed to that path.
DOTFILES=""

if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    local_script_path="${BASH_SOURCE[0]}"

    if [[ -f "$local_script_path" ]]; then
        DOTFILES="$(cd "$(dirname "$local_script_path")" && pwd -P)"
    fi
fi

unset local_script_path

# Set when the repository was downloaded automatically.
BOOTSTRAP_DIR=""

CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
SHARE="${XDG_DATA_HOME:-$HOME/.local/share}"
BIN="$HOME/.local/bin"

BACKUP_ROOT="$HOME/.dotfiles-backup"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$BACKUP_ROOT/$TIMESTAMP"

# ============================================================
# Options
# ============================================================

DEPS=1
DRY=0
MINIMAL=0
FRESH=0
NO_TUI=0
MODE=""

# Used by the TUI.
MENU_RESULT=0

for arg in "$@"; do
    case "$arg" in
        --no-deps)
            DEPS=0
            ;;

        --dry-run)
            DRY=1
            ;;

        --minimal)
            MINIMAL=1
            MODE="minimal"
            ;;

        --fresh)
            FRESH=1
            MODE="fresh"
            ;;

        --update)
            MODE="update"
            ;;

        --configs-only)
            MODE="configs"
            ;;

        --packages-only)
            MODE="packages"
            ;;

        --no-tui)
            NO_TUI=1
            ;;

        --help|-h)
            cat <<'EOF'
Alice's Niri dotfiles installer

Usage:
  ./install.sh
      Open installer menu.

  ./install.sh --fresh
      Fresh Arch bootstrap.
      Installs the full desktop + greetd + tuigreet.

  ./install.sh --minimal
      Install the core Niri environment.

  ./install.sh --update
      Pull the newest dotfiles from a local git repository,
      or download the newest GitHub snapshot when launched
      through curl.

  ./install.sh --configs-only
      Install dotfiles without packages.

  ./install.sh --packages-only
      Install packages without copying configs.

  ./install.sh --no-deps
      Skip all package installation.

  ./install.sh --dry-run
      Show actions without modifying the system.

  ./install.sh --no-tui
      Run a normal full installation without the menu.

Quick install:
  curl -fsSL https://raw.githubusercontent.com/AliceTheDotfile/niri-dots-clean/main/install.sh | bash

The installer NEVER touches:
  ~/.config/waybar
  ~/.config/fastfetch

The installer NEVER installs:
  Waybar

The installer NEVER copies:
  ~/.local/share/kate/anonymous.katesession

Update mode:
  Local git repository:
      git pull --ff-only

  curl invocation:
      downloads the latest repository snapshot from GitHub

Local git changes are never overwritten.
EOF
            exit 0
            ;;

        *)
            echo "unknown option: $arg" >&2
            exit 1
            ;;
    esac
done

# ============================================================
# Colors
# ============================================================

RESET='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'

PINK='\033[38;5;205m'
PURPLE='\033[38;5;141m'
CYAN='\033[38;5;81m'
GREEN='\033[38;5;114m'
YELLOW='\033[38;5;221m'
RED='\033[38;5;203m'
WHITE='\033[97m'
GRAY='\033[90m'

# ============================================================
# Output helpers
# ============================================================

clear_screen() {
    printf '\033[2J\033[H'
}

say() {
    printf "${PINK}::${RESET} %s\n" "$*"
}

success() {
    printf "${GREEN}✓${RESET} %s\n" "$*"
}

warn() {
    printf "${YELLOW}!${RESET} %s\n" "$*" >&2
}

fail() {
    printf "${RED}✗${RESET} %s\n" "$*" >&2
}

info() {
    printf "${CYAN}→${RESET} %s\n" "$*"
}

run() {
    if (( DRY )); then
        printf "${GRAY}[dry]${RESET} "
        printf '%q ' "$@"
        printf '\n'
    else
        "$@"
    fi
}

pause_screen() {
    printf "\n${GRAY}press enter to continue...${RESET}"
    read -r
}

# ============================================================
# Error handling
# ============================================================

cleanup() {
    if [[ -n "${BOOTSTRAP_DIR:-}" ]] &&
       [[ -d "$BOOTSTRAP_DIR" ]]; then

        rm -rf -- "$BOOTSTRAP_DIR"
    fi

    printf '\033[0m\n'
}

trap cleanup EXIT
trap 'fail "installer failed on line $LINENO"; exit 1' ERR

# ============================================================
# TUI
# ============================================================

draw_header() {
    clear_screen

    printf "\n"
    printf " ${PINK}╭──────────────────────────────────────────────────────╮${RESET}\n"
    printf " ${PINK}│${RESET} ${BOLD}${WHITE}alice's niri dots installer${RESET} ${DIM}:3${RESET}                  ${PINK}│${RESET}\n"
    printf " ${PINK}│${RESET} ${GRAY}clean • keyboard-first • backed-up${RESET}               ${PINK}│${RESET}\n"
    printf " ${PINK}╰──────────────────────────────────────────────────────╯${RESET}\n\n"
}

menu() {
    local title="$1"
    shift

    local options=("$@")
    local selected=0
    local key=""
    local rest=""

    while true; do
        draw_header

        printf " ${PURPLE}${BOLD}%s${RESET}\n\n" "$title"

        for i in "${!options[@]}"; do
            if (( i == selected )); then
                printf "   ${PINK}›${RESET} ${BOLD}${WHITE}%s${RESET}\n" "${options[$i]}"
            else
                printf "     ${GRAY}%s${RESET}\n" "${options[$i]}"
            fi
        done

        printf "\n"
        printf " ${GRAY}↑/↓ or j/k${RESET}   ${GRAY}Enter${RESET} select   ${GRAY}q${RESET} quit\n"

        IFS= read -rsn1 key

        case "$key" in
            "")
                MENU_RESULT="$selected"
                return 0
                ;;

            q|Q)
                MENU_RESULT=-1
                return 0
                ;;

            j)
                selected=$((selected + 1))
                ;;

            k)
                selected=$((selected - 1))
                ;;

            $'\x1b')
                IFS= read -rsn2 rest || true

                case "$rest" in
                    '[A')
                        selected=$((selected - 1))
                        ;;

                    '[B')
                        selected=$((selected + 1))
                        ;;
                esac
                ;;
        esac

        if (( selected < 0 )); then
            selected=$((${#options[@]} - 1))
        fi

        if (( selected >= ${#options[@]} )); then
            selected=0
        fi
    done
}

# ============================================================
# Package lists
# ============================================================

CORE_PKGS=(
    # Niri
    niri
    xwayland-satellite

    # Shell / terminal
    quickshell
    kitty
    swaync
    wofi

    # KDE / themes
    kate
    qt6ct
    nwg-look
    kvantum
    layer-shell-qt
    papirus-icon-theme
    dconf

    # Wallpaper
    awww
    mpv
    ffmpeg
    pyside6

    # Audio
    pipewire
    pipewire-pulse
    wireplumber
    playerctl
    pavucontrol

    # Wayland utilities
    brightnessctl
    grim
    slurp
    wl-clipboard

    # Desktop integration
    xdg-utils
    xdg-user-dirs
    xdg-desktop-portal
    xdg-desktop-portal-gtk

    # Networking
    networkmanager
    network-manager-applet

    # Bluetooth
    bluez
    bluez-utils
    blueman

    # General utilities
    python
    jq
    rsync
    git

    # Fonts
    ttf-hack
    noto-fonts
    noto-fonts-emoji
    otf-atkinsonhyperlegiblemono-nerd
    woff2-font-awesome
)

NICE_PKGS=(
    # Browser
    firefox

    # File management
    thunar
    file-roller
    7zip
    unzip
    zip

    # Image viewer
    imv

    # Development
    neovim
    fzf
    ripgrep
    fd
    bat
    eza
    tree
    less

    # System information
    fastfetch

    # Documentation
    man-db
    man-pages
)

FRESH_PKGS=(
    greetd
    greetd-tuigreet
)

AUR_PKGS=(
    mpvpaper
    neowall-bin
)

# ============================================================
# Basic helpers
# ============================================================

need_command() {
    command -v "$1" >/dev/null 2>&1
}

require_arch() {
    need_command pacman || {
        fail "this installer requires Arch Linux / an Arch-based system with pacman"
        exit 1
    }

    need_command sudo || {
        fail "sudo is required by this installer"
        exit 1
    }

    [[ $EUID -ne 0 ]] || {
        fail "do not run this installer as root"
        exit 1
    }
}

# ============================================================
# GitHub repository bootstrap
# ============================================================

repo_is_complete() {
    [[ -n "$DOTFILES" ]] || return 1

    [[ -f "$DOTFILES/install.sh" ]] || return 1
    [[ -d "$DOTFILES/niri" ]] || return 1
    [[ -d "$DOTFILES/quickshell/my-shell" ]] || return 1
    [[ -d "$DOTFILES/wallfliper" ]] || return 1
    [[ -d "$DOTFILES/local/bin" ]] || return 1
    [[ -d "$DOTFILES/Wallpapers" ]] || return 1
}

bootstrap_repo() {
    if repo_is_complete; then
        return 0
    fi

    need_command curl || {
        fail "curl is required to download the dotfiles repository"
        fail "install curl first, then run this installer again"
        return 1
    }

    need_command tar || {
        fail "tar is required to extract the dotfiles repository"
        fail "install tar first, then run this installer again"
        return 1
    }

    BOOTSTRAP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/alice-niri-dots.XXXXXXXX")"

    local archive="$BOOTSTRAP_DIR/repo.tar.gz"

    say "downloading Alice's latest Niri dots"

    curl \
        --fail \
        --silent \
        --show-error \
        --location \
        --retry 3 \
        --retry-delay 1 \
        "$REPO_ARCHIVE_URL" \
        -o "$archive"

    say "extracting dotfiles"

    tar \
        -xzf "$archive" \
        --strip-components=1 \
        -C "$BOOTSTRAP_DIR"

    rm -f "$archive"

    DOTFILES="$BOOTSTRAP_DIR"

    success "latest dotfiles downloaded"
}

# ============================================================
# Repository validation
# ============================================================

validate_repo() {
    say "checking repository"

    local required=(
        "$DOTFILES/niri"
        "$DOTFILES/quickshell/my-shell"
        "$DOTFILES/wallfliper"
        "$DOTFILES/local/bin"
        "$DOTFILES/Wallpapers"
    )

    local optional=(
        "$DOTFILES/home/.config/kate"
        "$DOTFILES/home/.config/katerc"
        "$DOTFILES/home/.config/katevirc"
        "$DOTFILES/home/.config/katemetainfos"
    )

    local path
    local missing=0

    for path in "${required[@]}"; do
        if [[ ! -e "$path" ]]; then
            warn "missing required repo path: ${path#$DOTFILES/}"
            missing=1
        fi
    done

    for path in "${optional[@]}"; do
        if [[ ! -e "$path" ]]; then
            warn "Kate config not present in repo: ${path#$DOTFILES/}"
        fi
    done

    if (( missing )); then
        fail "repository is missing required files"
        exit 1
    fi

    success "repository looks good"
}

# ============================================================
# Git update
# ============================================================

update_repo() {
    # curl | bash already downloaded the latest main snapshot.
    if [[ -n "${BOOTSTRAP_DIR:-}" ]]; then
        say "using the latest GitHub snapshot"
        success "dotfiles are already up to date"
        return 0
    fi

    need_command git || {
        fail "git is required for update mode"
        return 1
    }

    [[ -d "$DOTFILES/.git" ]] || {
        fail "this installer is not running from a git repository"
        fail "clone the dotfiles repo first, then run ./install.sh --update"
        return 1
    }

    say "checking dotfiles git repository"

    local status
    status="$(git -C "$DOTFILES" status --porcelain)"

    if [[ -n "$status" ]]; then
        fail "the dotfiles repository has uncommitted changes"
        printf "\n${GRAY}%s${RESET}\n\n" "$status"
        warn "update stopped so your local repo changes are not overwritten"
        return 1
    fi

    local branch
    branch="$(git -C "$DOTFILES" branch --show-current)"

    if [[ -n "$branch" ]]; then
        info "branch: $branch"
    else
        warn "repository is in detached HEAD state"
    fi

    if (( DRY )); then
        info "[dry] would run: git pull --ff-only"
        return 0
    fi

    say "pulling latest dotfiles"

    git -C "$DOTFILES" pull --ff-only

    success "dotfiles repository updated"
}

# ============================================================
# AUR helper
# ============================================================

find_aur_helper() {
    if need_command yay; then
        printf '%s\n' yay
        return 0
    fi

    if need_command paru; then
        printf '%s\n' paru
        return 0
    fi

    return 1
}

install_yay() {
    if need_command yay; then
        return 0
    fi

    [[ $EUID -ne 0 ]] || {
        fail "do not run this installer as root"
        return 1
    }

    say "installing yay"

    run sudo pacman -Syu --needed --noconfirm \
        base-devel \
        git

    local tmp
    tmp="$(mktemp -d)"

    if (( DRY )); then
        info "[dry] would clone and build yay"
        rm -rf "$tmp"
        return 0
    fi

    git clone \
        https://aur.archlinux.org/yay.git \
        "$tmp/yay"

    (
        cd "$tmp/yay"
        makepkg -si --noconfirm
    )

    rm -rf "$tmp"

    success "yay installed"
}

# ============================================================
# Package installation
# ============================================================

official_package_exists() {
    pacman -Si "$1" >/dev/null 2>&1
}

install_official_packages() {
    local packages=("$@")
    local valid=()
    local pkg

    for pkg in "${packages[@]}"; do
        if official_package_exists "$pkg"; then
            valid+=("$pkg")
        else
            warn "not found in Arch repositories: $pkg"
        fi
    done

    if ((${#valid[@]} == 0)); then
        return 0
    fi

    say "installing ${#valid[@]} official packages"

    run sudo pacman \
        -Syu \
        --needed \
        --noconfirm \
        "${valid[@]}"

    success "official packages installed"
}

install_aur_packages() {
    local packages=("$@")

    ((${#packages[@]})) || return 0

    local helper=""

    if helper="$(find_aur_helper)"; then
        :
    else
        warn "no AUR helper found"

        if (( DRY )); then
            info "[dry] would install yay"
            return 0
        fi

        printf "\n"
        printf "${YELLOW}some packages are from the AUR.${RESET}\n"
        printf "${GRAY}The installer can bootstrap yay automatically.${RESET}\n\n"

        read -rp "install yay automatically? [Y/n] " answer
        answer="${answer:-Y}"

        if [[ "$answer" =~ ^[Yy]$ ]]; then
            install_yay
            helper="yay"
        else
            warn "AUR packages skipped"
            return 0
        fi
    fi

    say "installing AUR packages with $helper"

    run "$helper" \
        -S \
        --needed \
        --noconfirm \
        "${packages[@]}"

    success "AUR packages installed"
}

install_deps() {
    require_arch

    local packages=(
        "${CORE_PKGS[@]}"
    )

    if (( ! MINIMAL )); then
        packages+=("${NICE_PKGS[@]}")
    fi

    if (( FRESH )); then
        packages+=("${FRESH_PKGS[@]}")
    fi

    install_official_packages "${packages[@]}"
    install_aur_packages "${AUR_PKGS[@]}"
}

# ============================================================
# Backup handling
# ============================================================

backup_destination() {
    local dest="$1"

    if [[ ! -e "$dest" && ! -L "$dest" ]]; then
        return 0
    fi

    local relative="${dest#$HOME/}"

    run mkdir -p \
        "$BACKUP/$(dirname "$relative")"

    run mv \
        "$dest" \
        "$BACKUP/$relative"
}

# ============================================================
# @HOME@ replacement
# ============================================================

replace_home_token() {
    local path="$1"

    (( DRY )) && return 0
    [[ -e "$path" ]] || return 0

    grep -rIl -- '@HOME@' "$path" 2>/dev/null |
        xargs -r sed -i "s|@HOME@|$HOME|g" ||
        true
}

# ============================================================
# Install file / directory
# ============================================================

place() {
    local src="$1"
    local dest="$2"

    if [[ ! -e "$src" && ! -L "$src" ]]; then
        warn "missing in repo: ${src#$DOTFILES/}"
        return 0
    fi

    if [[ -e "$dest" || -L "$dest" ]]; then
        say "backing up ${dest#$HOME/}"
        backup_destination "$dest"
    fi

    run mkdir -p \
        "$(dirname "$dest")"

    if [[ -d "$src" && ! -L "$src" ]]; then
        run mkdir -p "$dest"

        run rsync \
            -a \
            --exclude=.git \
            "$src/" \
            "$dest/"
    else
        run cp -a \
            "$src" \
            "$dest"
    fi

    replace_home_token "$dest"
}

# ============================================================
# Config installation
# ============================================================

install_configs() {
    say "installing desktop configs"

    run mkdir -p \
        "$CONFIG" \
        "$BIN" \
        "$SHARE" \
        "$HOME/Wallpapers"

    local configs=(
        alice-rice
        btop
        cava
        environment.d
        fontconfig
        gamearch
        gtk-3.0
        gtk-4.0
        Kvantum
        niri
        qt6ct
        swaync
    )

    local name

    for name in "${configs[@]}"; do
        place \
            "$DOTFILES/$name" \
            "$CONFIG/$name"
    done

    place \
        "$DOTFILES/quickshell/my-shell" \
        "$CONFIG/quickshell/my-shell"

    success "desktop configs installed"

    info "Fastfetch config untouched"
    info "Waybar config untouched"
}

# ============================================================
# Shell / Kate / themes
# ============================================================

install_home_files() {
    say "installing shell, Kate and theme files"

    local home_items=(
        ".bashrc"
        ".bash_profile"

        ".config/kdeglobals"

        ".config/kate"
        ".config/katerc"
        ".config/katevirc"
        ".config/katemetainfos"

        ".local/share/color-schemes/AliceNight.colors"
        ".local/share/themes/AliceNight"

        ".icons/Bibata-Material-Cloud"
    )

    local item

    for item in "${home_items[@]}"; do
        place \
            "$DOTFILES/home/$item" \
            "$HOME/$item"
    done

    success "shell, Kate and theme files installed"

    info "Kate session files are not installed"
}

# ============================================================
# Wallfliper
# ============================================================

install_wallfliper() {
    say "installing Wallfliper"

    place \
        "$DOTFILES/wallfliper" \
        "$SHARE/wallfliper"

    place \
        "$DOTFILES/wallfliper/config.json" \
        "$CONFIG/wallfliper/config.json"

    local launcher="$BIN/wallfliper"

    if [[ ! -e "$DOTFILES/local/bin/wallfliper" ]]; then
        if [[ -e "$launcher" ]]; then
            say "backing up existing Wallfliper launcher"
            backup_destination "$launcher"
        fi

        if (( DRY )); then
            info "[dry] would create $launcher"
        else
            cat > "$launcher" <<EOF
#!/usr/bin/env bash
exec python "$SHARE/wallfliper/main.py" "\$@"
EOF

            chmod +x "$launcher"
        fi
    fi

    success "Wallfliper installed"
}

# ============================================================
# Local scripts
# ============================================================

install_scripts() {
    say "installing scripts to ~/.local/bin"

    local file
    local name

    shopt -s nullglob

    for file in "$DOTFILES"/local/bin/*; do
        [[ -f "$file" ]] || continue

        name="$(basename "$file")"

        place \
            "$file" \
            "$BIN/$name"

        run chmod +x \
            "$BIN/$name"
    done

    shopt -u nullglob

    success "local scripts installed"
}

# ============================================================
# Wallpapers
# ============================================================

install_wallpapers() {
    say "installing wallpapers"

    local file
    local target

    shopt -s nullglob

    for file in "$DOTFILES"/Wallpapers/*; do
        [[ -e "$file" ]] || continue

        target="$HOME/Wallpapers/$(basename "$file")"

        if [[ -e "$target" ]]; then
            info "keeping existing wallpaper: $(basename "$file")"
            continue
        fi

        run cp -a \
            "$file" \
            "$target"
    done

    shopt -u nullglob

    success "wallpapers installed"
}

# ============================================================
# PATH handling
# ============================================================

path_contains_bin() {
    case ":${PATH:-}:" in
        *":$BIN:"*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

path_file_contains_bin() {
    local file="$1"

    [[ -f "$file" ]] || return 1

    grep -Eq \
        '(^|:|\$HOME/)\.local/bin|\.local/bin.*PATH|PATH=.*\.local/bin' \
        "$file"
}

add_path_to_file() {
    local file="$1"

    if path_file_contains_bin "$file"; then
        return 0
    fi

    if (( DRY )); then
        info "[dry] would add ~/.local/bin to ${file#$HOME/}"
        return 0
    fi

    mkdir -p \
        "$(dirname "$file")"

    {
        printf '\n'
        printf '# Alice dotfiles - local user scripts\n'
        printf 'export PATH="$HOME/.local/bin:$PATH"\n'
    } >> "$file"
}

setup_path() {
    say "checking ~/.local/bin PATH"

    if path_contains_bin; then
        success "~/.local/bin is already in PATH"
        return 0
    fi

    if (( ! DRY )); then
        export PATH="$BIN:$PATH"
    fi

    add_path_to_file "$HOME/.profile"

    if [[ -f "$HOME/.bash_profile" ]]; then
        add_path_to_file "$HOME/.bash_profile"
    fi

    if [[ -f "$HOME/.bashrc" ]]; then
        add_path_to_file "$HOME/.bashrc"
    fi

    if [[ -f "$HOME/.zshrc" ]]; then
        add_path_to_file "$HOME/.zshrc"
    fi

    success "~/.local/bin added to PATH"
}

# ============================================================
# dconf
# ============================================================

apply_dconf() {
    local file="$DOTFILES/dconf/interface.ini"

    [[ -f "$file" ]] || return 0

    need_command dconf || {
        warn "dconf not installed; skipping GTK settings"
        return 0
    }

    if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
        warn "no D-Bus session bus; skipping dconf settings"
        return 0
    fi

    say "applying GTK interface settings"

    if (( DRY )); then
        info "[dry] would load dconf settings"
        return 0
    fi

    mkdir -p "$BACKUP"

    dconf dump \
        /org/gnome/desktop/interface/ \
        > "$BACKUP/interface.dconf.bak" \
        2>/dev/null \
        || true

    dconf load \
        /org/gnome/desktop/interface/ \
        < "$file" \
        || warn "dconf load failed"
}

# ============================================================
# greetd + tuigreet
# ============================================================

setup_greetd() {
    say "configuring greetd + tuigreet"

    need_command greetd || {
        fail "greetd is not installed"
        return 1
    }

    need_command tuigreet || {
        fail "tuigreet is not installed"
        return 1
    }

    need_command niri-session || {
        fail "niri-session is not installed"
        return 1
    }

    if [[ -e /etc/greetd/config.toml ]]; then
        say "backing up existing greetd configuration"

        run mkdir -p \
            "$BACKUP/etc/greetd"

        run sudo cp -a \
            /etc/greetd/config.toml \
            "$BACKUP/etc/greetd/config.toml"
    fi

    if (( DRY )); then
        info "[dry] would write /etc/greetd/config.toml"
        info "[dry] would enable greetd.service"
        return 0
    fi

    say "writing greetd configuration"

    sudo install \
        -d \
        -m 0755 \
        /etc/greetd

    sudo tee /etc/greetd/config.toml >/dev/null <<'EOF'
[terminal]
vt = 1

[default_session]
command = "tuigreet --time --remember --remember-session --asterisks --cmd niri-session"
user = "greeter"
EOF

    say "enabling greetd"

    sudo systemctl enable greetd.service

    success "greetd configured"
    success "tuigreet configured"
    success "Niri configured as the login session"
}

# ============================================================
# Fresh system services
# ============================================================

setup_fresh_services() {
    say "configuring fresh-system services"

    if need_command systemctl; then
        if systemctl list-unit-files \
            NetworkManager.service >/dev/null 2>&1; then

            say "enabling NetworkManager"

            run sudo systemctl enable \
                NetworkManager.service
        fi

        if systemctl list-unit-files \
            bluetooth.service >/dev/null 2>&1; then

            say "enabling Bluetooth"

            run sudo systemctl enable \
                bluetooth.service
        fi
    else
        warn "systemctl unavailable; cannot configure services"
    fi

    setup_greetd
}

# ============================================================
# Verification
# ============================================================

check_command_status() {
    local command_name="$1"
    local label="$2"

    if need_command "$command_name"; then
        success "$label"
    else
        warn "$label missing"
    fi
}

verify_installation() {
    say "checking installation"

    check_command_status niri "Niri"
    check_command_status niri-session "Niri session"
    check_command_status quickshell "Quickshell"
    check_command_status kitty "Kitty"
    check_command_status kate "Kate"

    check_command_status awww "awww"
    check_command_status mpv "mpv"
    check_command_status ffmpeg "ffmpeg"
    check_command_status python "Python"

    check_command_status thunar "Thunar"
    check_command_status firefox "Firefox"
    check_command_status nvim "Neovim"

    if need_command fastfetch; then
        success "Fastfetch"
    elif (( ! MINIMAL )); then
        warn "Fastfetch missing"
    fi

    if [[ -d "$CONFIG/waybar" ]]; then
        info "existing Waybar config detected and left untouched"
    fi

    if path_contains_bin; then
        success "~/.local/bin is in PATH"
    else
        warn "~/.local/bin is not currently in PATH"
    fi

    if (( FRESH )); then
        check_command_status greetd "greetd"
        check_command_status tuigreet "tuigreet"

        if [[ -f /etc/greetd/config.toml ]]; then
            success "greetd configuration"
        else
            warn "greetd configuration missing"
        fi
    fi

    if [[ -f "$SHARE/wallfliper/main.py" ]]; then
        say "checking Wallfliper dependencies"

        if (( DRY )); then
            info "[dry] would run Wallfliper dependency check"
        else
            if python \
                "$SHARE/wallfliper/main.py" \
                --check; then

                success "Wallfliper dependency check passed"
            else
                warn "Wallfliper reported missing dependencies"
            fi
        fi
    fi
}

# ============================================================
# Apply current rice
# ============================================================

apply_rice() {
    install_configs
    install_home_files
    install_wallfliper
    install_scripts
    install_wallpapers
    setup_path
    apply_dconf
}

# ============================================================
# Full install
# ============================================================

do_full_install() {
    FRESH=0
    MINIMAL=0

    validate_repo

    if (( DEPS )); then
        install_deps
    else
        info "dependency installation disabled"
    fi

    apply_rice
    verify_installation
}

# ============================================================
# Minimal install
# ============================================================

do_minimal_install() {
    FRESH=0
    MINIMAL=1

    validate_repo

    if (( DEPS )); then
        install_deps
    else
        info "dependency installation disabled"
    fi

    apply_rice
    verify_installation
}

# ============================================================
# Update existing rice
# ============================================================

do_update() {
    FRESH=0
    MINIMAL=0

    say "updating existing Alice rice"

    update_repo
    validate_repo

    printf "\n"

    if (( ! DRY )); then
        printf "${YELLOW}${BOLD}the current repo will be installed over your existing rice.${RESET}\n"
        printf "${GRAY}existing managed files are backed up first.${RESET}\n"
        printf "${GRAY}Waybar and Fastfetch remain untouched.${RESET}\n\n"

        read -rp "apply the updated rice? [Y/n] " answer
        answer="${answer:-Y}"

        if [[ ! "$answer" =~ ^[Yy]$ ]]; then
            info "update cancelled before applying configs"
            return 0
        fi
    fi

    apply_rice
    verify_installation

    success "existing rice updated from the latest repo"
}

# ============================================================
# Fresh Arch installation
# ============================================================

do_fresh_install() {
    FRESH=1
    MINIMAL=0

    validate_repo

    printf "\n"
    printf "${YELLOW}${BOLD}fresh Arch setup${RESET}\n"
    printf "${GRAY}this mode assumes this is a mostly-empty Arch installation.${RESET}\n"
    printf "${GRAY}it will install greetd and make it the login manager.${RESET}\n"
    printf "\n"

    if (( ! DRY )); then
        read -rp "continue with fresh-system setup? [Y/n] " answer
        answer="${answer:-Y}"

        if [[ ! "$answer" =~ ^[Yy]$ ]]; then
            info "fresh setup cancelled"
            return 0
        fi
    fi

    if (( DEPS )); then
        install_deps
    else
        warn "--no-deps was supplied; fresh package installation skipped"
    fi

    apply_rice

    if (( DEPS )); then
        setup_fresh_services
    else
        warn "greetd setup skipped because dependency installation is disabled"
    fi

    verify_installation

    if (( ! DRY )); then
        printf "\n"
        printf "${WHITE}${BOLD}fresh setup is ready.${RESET}\n"
        printf "${GRAY}reboot to enter tuigreet and launch Niri.${RESET}\n\n"

        read -rp "reboot now? [y/N] " answer

        if [[ "$answer" =~ ^[Yy]$ ]]; then
            say "rebooting"
            sudo systemctl reboot
        fi
    fi
}

# ============================================================
# Config-only
# ============================================================

do_configs_only() {
    FRESH=0

    validate_repo

    apply_rice
    verify_installation
}

# ============================================================
# Packages-only
# ============================================================

do_packages_only() {
    FRESH=0

    if (( ! DEPS )); then
        warn "--no-deps was supplied; nothing to install"
        return 0
    fi

    if (( MINIMAL )); then
        install_official_packages \
            "${CORE_PKGS[@]}"
    else
        install_official_packages \
            "${CORE_PKGS[@]}" \
            "${NICE_PKGS[@]}"
    fi

    install_aur_packages \
        "${AUR_PKGS[@]}"
}

# ============================================================
# Summary
# ============================================================

show_summary() {
    clear_screen

    printf "\n"
    printf " ${PINK}╭──────────────────────────────────────────────────────╮${RESET}\n"
    printf " ${PINK}│${RESET} ${BOLD}${GREEN}installation complete${RESET} ${DIM}:3${RESET}                       ${PINK}│${RESET}\n"
    printf " ${PINK}╰──────────────────────────────────────────────────────╯${RESET}\n\n"

    if [[ "$MODE" == "update" ]]; then
        success "existing rice updated from the latest repo"
        success "latest repo configuration applied"

    elif [[ "$MODE" == "packages" ]]; then
        if (( MINIMAL )); then
            success "core packages installed"
        else
            success "desktop packages installed"
        fi

    elif [[ "$MODE" == "configs" ]]; then
        success "desktop configs installed"
        success "shell / Kate / theme files installed"
        success "Wallfliper installed"

    elif (( FRESH )); then
        success "fresh Arch desktop installed"
        success "Niri installed"
        success "Kate installed and configured"
        success "Wallfliper installed"
        success "greetd + tuigreet configured"
        success "NetworkManager + Bluetooth configured"

    elif (( MINIMAL )); then
        success "minimal Niri setup installed"

    else
        success "Niri desktop installed"
        success "Kate installed and configured"
        success "Wallfliper installed"
    fi

    success "~/.local/bin handled"

    printf "\n"

    printf "${CYAN}intentionally untouched:${RESET}\n"
    printf "  ${GRAY}•${RESET} ~/.config/waybar\n"
    printf "  ${GRAY}•${RESET} ~/.config/fastfetch\n"
    printf "  ${GRAY}•${RESET} Kate session files\n"

    if [[ -d "$BACKUP" ]]; then
        printf "\n"
        printf "${CYAN}backup:${RESET} %s\n" "$BACKUP"
    fi

    printf "\n"

    if (( FRESH )); then
        printf "${WHITE}${BOLD}fresh-system next step:${RESET}\n\n"
        printf "  ${GRAY}•${RESET} reboot\n"
        printf "  ${GRAY}•${RESET} log in through ${PINK}tuigreet${RESET}\n"
        printf "  ${GRAY}•${RESET} launch ${PINK}Niri${RESET}\n"

    elif [[ "$MODE" == "update" ]]; then
        printf "${WHITE}${BOLD}update next step:${RESET}\n\n"
        printf "  ${GRAY}•${RESET} restart Niri / Quickshell if needed\n"
        printf "  ${GRAY}•${RESET} open a new shell if PATH changed\n"

    elif [[ "$MODE" == "packages" ]]; then
        printf "${WHITE}${BOLD}next step:${RESET}\n\n"
        printf "  ${GRAY}•${RESET} restart your shell if PATH changed\n"

    elif [[ "$MODE" == "configs" ]]; then
        printf "${WHITE}${BOLD}next step:${RESET}\n\n"
        printf "  ${GRAY}•${RESET} restart Niri / Quickshell if needed\n"
        printf "  ${GRAY}•${RESET} open a new shell if PATH changed\n"

    else
        printf "${WHITE}${BOLD}next step:${RESET}\n\n"
        printf "  ${GRAY}•${RESET} restart Niri / Quickshell if needed\n"
        printf "  ${GRAY}•${RESET} open a new shell if PATH was changed\n"
    fi

    printf "\n"
    printf "${DIM}have fun rice-ing :3${RESET}\n\n"
}

# ============================================================
# Main
# ============================================================

main() {
    require_arch

    # packages-only does not need the repository at all.
    # Everything else needs the repository contents.
    if [[ "$MODE" != "packages" ]]; then
        bootstrap_repo
        cd "$DOTFILES"
    fi

    case "$MODE" in
        fresh)
            do_fresh_install
            show_summary
            return 0
            ;;

        minimal)
            do_minimal_install
            show_summary
            return 0
            ;;

        update)
            do_update
            show_summary
            return 0
            ;;

        configs)
            do_configs_only
            show_summary
            return 0
            ;;

        packages)
            do_packages_only
            show_summary
            return 0
            ;;
    esac

    if (( NO_TUI )); then
        do_full_install
        show_summary
        return 0
    fi

    if (( DRY )); then
        info "dry-run mode enabled"
        printf "\n"
        pause_screen
    fi

    menu \
        "what would you like to do?" \
        "full setup       — Niri + rice + Kate + apps + AUR" \
        "update existing  — pull newest repo + update rice" \
        "fresh Arch setup — everything + greetd + tuigreet" \
        "minimal setup    — Niri + rice + Kate + core packages" \
        "configs only     — dotfiles without packages" \
        "packages only    — install dependencies/apps" \
        "exit"

    local choice="$MENU_RESULT"

    if (( choice == -1 )); then
        clear_screen
        info "bye :3"
        exit 0
    fi

    case "$choice" in
        0)
            do_full_install
            ;;

        1)
            MODE="update"
            do_update
            ;;

        2)
            MODE="fresh"
            do_fresh_install
            ;;

        3)
            MODE="minimal"
            do_minimal_install
            ;;

        4)
            MODE="configs"
            do_configs_only
            ;;

        5)
            MODE="packages"
            do_packages_only
            ;;

        6)
            clear_screen
            info "bye :3"
            exit 0
            ;;

        *)
            fail "invalid menu selection"
            exit 1
            ;;
    esac

    show_summary
}

main "$@"

