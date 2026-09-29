#!/usr/bin/env bash
#
# Alice's Niri dotfiles installer
#
# Usage:
#   ./install.sh
#   ./install.sh --dry-run
#   ./install.sh --no-deps
#   ./install.sh --minimal
#   ./install.sh --fresh
#   ./install.sh --no-tui
#
# Modes:
#
#   Full setup
#       Normal install for an existing Arch system.
#
#   Fresh Arch setup
#       Intended for a basically-empty Arch install.
#       Installs:
#         - Niri
#         - Quickshell
#         - Kate
#         - AliceNight theme
#         - Wallfliper
#         - useful desktop apps
#         - greetd
#         - greetd-tuigreet
#         - NetworkManager
#         - Bluetooth
#       Configures greetd to launch niri-session.
#
# IMPORTANT:
#
#   WAYBAR:
#       NEVER installed.
#       NEVER copied.
#       NEVER backed up.
#       NEVER verified.
#
#   FASTFETCH:
#       Fastfetch may be installed as an application.
#       ~/.config/fastfetch is NEVER touched.
#
#   KATE:
#       Reusable Kate configuration is installed:
#         ~/.config/kate
#         ~/.config/katerc
#         ~/.config/katevirc
#         ~/.config/katemetainfos
#
#       Kate session files are NEVER copied.
#
#   Existing files are backed up before replacement.
#

set -Eeuo pipefail

# ============================================================
# Paths
# ============================================================

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
            ;;

        --fresh)
            FRESH=1
            ;;

        --no-tui)
            NO_TUI=1
            ;;

        --help|-h)
            cat <<'EOF'
Alice's Niri dotfiles installer

Usage:
  ./install.sh
      Open the installer menu.

  ./install.sh --fresh
      Fresh Arch bootstrap:
      Niri + Quickshell + Kate + apps + Wallfliper +
      greetd + tuigreet + NetworkManager + Bluetooth.

  ./install.sh --minimal
      Install the core Niri setup.

  ./install.sh --no-deps
      Skip package installation.

  ./install.sh --dry-run
      Show what would happen without changing anything.

  ./install.sh --no-tui
      Run the full setup without the menu.

The installer NEVER touches:
  ~/.config/waybar
  ~/.config/fastfetch

The installer NEVER copies:
  ~/.local/share/kate/anonymous.katesession
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
# Output
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
    local key
    local rest

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
                return "$selected"
                ;;

            q|Q)
                return 255
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

# ------------------------------------------------------------
# Core desktop
# ------------------------------------------------------------

CORE_PKGS=(
    # Wayland / Niri
    niri
    xwayland-satellite

    # Desktop shell
    quickshell
    kitty
    swaync
    wofi

    # KDE / theme support
    kate
    qt6ct
    nwg-look
    kvantum
    layer-shell-qt
    papirus-icon-theme
    dconf

    # Wallpaper
    awww
    ffmpeg
    mpv
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

    # General tools
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

# ------------------------------------------------------------
# Nice everyday applications
# ------------------------------------------------------------

NICE_PKGS=(
    # Browser
    firefox

    # File manager
    thunar
    file-roller
    7zip
    unzip
    zip

    # Image / media
    imv

    # Editor / development
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

# ------------------------------------------------------------
# Packages only needed for a fresh system
# ------------------------------------------------------------

FRESH_PKGS=(
    greetd
    greetd-tuigreet
)

# ------------------------------------------------------------
# AUR
# ------------------------------------------------------------

AUR_PKGS=(
    mpvpaper
    neowall-bin
)

# ============================================================
# Basic command helpers
# ============================================================

need_command() {
    command -v "$1" >/dev/null 2>&1
}

# ============================================================
# Repo validation
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

    local missing=0
    local path

    for path in "${required[@]}"; do
        if [[ ! -e "$path" ]]; then
            warn "missing: ${path#$DOTFILES/}"
            missing=1
        fi
    done

    if (( missing )); then
        warn "some expected files are missing"
    else
        success "repository looks good"
    fi
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
        info "[dry] would build yay"
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
# Packages
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
            warn "not found in official Arch repos: $pkg"
        fi
    done

    if ((${#valid[@]} == 0)); then
        return 0
    fi

    say "installing ${#valid[@]} official packages"

    # Always sync the complete package database first.
    run sudo pacman -Syu --needed --noconfirm \
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
        printf "${YELLOW}a few packages come from the AUR.${RESET}\n"
        printf "${GRAY}they are not required for the basic Niri session.${RESET}\n\n"

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

    run "$helper" -S --needed --noconfirm \
        "${packages[@]}"

    success "AUR packages installed"
}

install_deps() {
    need_command pacman || {
        fail "this installer requires Arch Linux with pacman"
        return 1
    }

    [[ $EUID -ne 0 ]] || {
        fail "do not run this installer as root"
        return 1
    }

    local packages=("${CORE_PKGS[@]}")

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
# Backups
# ============================================================

backup_destination() {
    local dest="$1"

    if [[ -e "$dest" || -L "$dest" ]]; then
        run mkdir -p \
            "$BACKUP/$(dirname "${dest#$HOME/}")"

        run mv \
            "$dest" \
            "$BACKUP/${dest#$HOME/}"
    fi
}

# ============================================================
# @HOME@ substitution
# ============================================================

replace_home_token() {
    local path="$1"

    (( DRY )) && return 0
    [[ -e "$path" ]] || return 0

    grep -rIl -- '@HOME@' "$path" 2>/dev/null \
        | xargs -r sed -i "s|@HOME@|$HOME|g" \
        || true
}

# ============================================================
# Place files
# ============================================================

place() {
    local src="$1"
    local dest="$2"

    [[ -e "$src" || -L "$src" ]] || {
        warn "missing in repo: ${src#$DOTFILES/}"
        return 0
    }

    if [[ -e "$dest" || -L "$dest" ]]; then
        say "backing up ${dest#$HOME/}"
        backup_destination "$dest"
    fi

    run mkdir -p "$(dirname "$dest")"

    if [[ -d "$src" && ! -L "$src" ]]; then
        run mkdir -p "$dest"

        run rsync -a \
            --exclude=.git \
            "$src/" \
            "$dest/"
    else
        run cp -a "$src" "$dest"
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

    # ========================================================
    # ONLY THESE ~/.config directories are managed.
    #
    # Waybar is NOT here.
    # Fastfetch is NOT here.
    # ========================================================

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

    # Quickshell
    place \
        "$DOTFILES/quickshell/my-shell" \
        "$CONFIG/quickshell/my-shell"

    success "desktop configs installed"

    # Explicit protection notices.
    info "Fastfetch config untouched"
    info "Waybar config untouched"
}

# ============================================================
# Shell / Kate / themes
# ============================================================

install_home_files() {
    say "installing shell, Kate and theme files"

    local home_items=(
        # Shell
        ".bashrc"
        ".bash_profile"

        # KDE global settings
        ".config/kdeglobals"

        # ----------------------------------------------------
        # Kate
        #
        # Your reusable Kate configuration.
        #
        # We deliberately do NOT install:
        #
        #   ~/.local/share/kate/anonymous.katesession
        #
        # because that is session state.
        # ----------------------------------------------------

        ".config/kate"
        ".config/katerc"
        ".config/katevirc"
        ".config/katemetainfos"

        # AliceNight
        ".local/share/color-schemes/AliceNight.colors"
        ".local/share/themes/AliceNight"

        # Cursor
        ".icons/Bibata-Material-Cloud"
    )

    local item

    for item in "${home_items[@]}"; do
        place \
            "$DOTFILES/home/$item" \
            "$HOME/$item"
    done

    success "shell, Kate and theme files installed"
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

    # If the repo has no launcher, create one.
    if [[ ! -e "$DOTFILES/local/bin/wallfliper" ]]; then

        if [[ -e "$launcher" ]]; then
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

    success "scripts installed"
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

        # Never overwrite existing user wallpapers.
        if [[ -e "$target" ]]; then
            info "keeping existing wallpaper: $(basename "$file")"
            continue
        fi

        run cp -a "$file" "$target"
    done

    shopt -u nullglob

    success "wallpapers installed"
}

# ============================================================
# PATH
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

file_contains_path_export() {
    local file="$1"

    [[ -f "$file" ]] || return 1

    grep -Fq \
        'export PATH="$HOME/.local/bin:$PATH"' \
        "$file"
}

add_path_to_file() {
    local file="$1"

    if file_contains_path_export "$file"; then
        return 0
    fi

    if (( DRY )); then
        info "[dry] would add ~/.local/bin to ${file#$HOME/}"
        return 0
    fi

    mkdir -p "$(dirname "$file")"

    {
        printf '\n'
        printf '# Alice dotfiles - local user scripts\n'
        printf 'export PATH="$HOME/.local/bin:$PATH"\n'
    } >> "$file"
}

setup_path() {
    say "checking ~/.local/bin PATH"

    # Check actual PATH first.
    if path_contains_bin; then
        success "~/.local/bin is already in PATH"
        return 0
    fi

    # Make scripts available immediately during this run.
    if (( ! DRY )); then
        export PATH="$BIN:$PATH"
    fi

    # Persist it for future sessions.
    add_path_to_file "$HOME/.profile"

    if [[ -f "$HOME/.bashrc" ]]; then
        add_path_to_file "$HOME/.bashrc"
    fi

    if [[ -f "$HOME/.bash_profile" ]]; then
        add_path_to_file "$HOME/.bash_profile"
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
        warn "dconf unavailable; skipping GTK settings"
        return 0
    }

    if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
        warn "no D-Bus session bus; GTK settings skipped"
        return 0
    fi

    say "applying GTK settings"

    if (( DRY )); then
        info "[dry] would load dconf settings"
        return 0
    fi

    mkdir -p "$BACKUP"

    dconf dump /org/gnome/desktop/interface/ \
        > "$BACKUP/interface.dconf.bak" \
        2>/dev/null \
        || true

    dconf load /org/gnome/desktop/interface/ \
        < "$file" \
        || warn "dconf load failed"
}

# ============================================================
# Fresh-system greetd setup
# ============================================================

setup_greetd() {
    say "configuring greetd + tuigreet"

    if ! need_command greetd; then
        fail "greetd is not installed"
        return 1
    fi

    if ! need_command tuigreet; then
        fail "tuigreet is not installed"
        return 1
    fi

    if ! need_command niri-session; then
        fail "niri-session is not installed"
        return 1
    fi

    [[ $EUID -ne 0 ]] || {
        fail "do not run this installer as root"
        return 1
    }

    printf "\n"
    printf "${YELLOW}${BOLD}fresh-system login setup${RESET}\n"
    printf "${GRAY}greetd will become the login manager.${RESET}\n"
    printf "${GRAY}tuigreet will start niri-session after login.${RESET}\n"
    printf "\n"

    if systemctl list-unit-files \
        display-manager.service >/dev/null 2>&1; then

        if systemctl is-enabled \
            display-manager.service >/dev/null 2>&1; then

            warn "another display manager appears to be enabled"

            printf "${GRAY}greetd may conflict with it.${RESET}\n"
            read -rp "continue anyway? [y/N] " answer

            if [[ ! "$answer" =~ ^[Yy]$ ]]; then
                info "greetd setup skipped"
                return 0
            fi
        fi
    fi

    # --------------------------------------------------------
    # Back up existing greetd config.
    # --------------------------------------------------------

    if [[ -e /etc/greetd/config.toml ]]; then
        say "backing up existing greetd configuration"

        run mkdir -p \
            "$BACKUP/etc/greetd"

        run sudo cp -a \
            /etc/greetd/config.toml \
            "$BACKUP/etc/greetd/config.toml"
    fi

    # --------------------------------------------------------
    # Write config.
    # --------------------------------------------------------

    say "writing greetd configuration"

    if (( DRY )); then
        info "[dry] would write /etc/greetd/config.toml"
    else
        sudo install -d \
            -m 0755 \
            /etc/greetd

        sudo tee /etc/greetd/config.toml >/dev/null <<'EOF'
[terminal]
vt = 1

[default_session]
command = "tuigreet --time --remember --remember-session --cmd niri-session"
user = "greeter"
EOF
    fi

    # --------------------------------------------------------
    # Enable greetd for next boot.
    #
    # We deliberately do NOT start it right now, because doing
    # that while the installer is running from a login shell can
    # yank the current session out from underneath us.
    # --------------------------------------------------------

    say "enabling greetd"

    run sudo systemctl enable greetd.service

    success "greetd configured"
    success "tuigreet configured"
    success "Niri session configured"
}

# ============================================================
# Fresh Arch bootstrap
# ============================================================

fresh_install() {
    say "starting fresh Arch setup"

    validate_repo

    if (( DEPS )); then
        install_deps
    else
        warn "dependency installation disabled"
    fi

    install_configs
    install_home_files
    install_wallfliper
    install_scripts
    install_wallpapers
    setup_path
    apply_dconf

    setup_greetd

    verify_installation

    printf "\n"

    if (( ! DRY )); then
        read -rp "reboot into the new system now? [y/N] " answer

        if [[ "$answer" =~ ^[Yy]$ ]]; then
            say "rebooting"
            sudo systemctl reboot
        fi
    fi
}

# ============================================================
# Normal full install
# ============================================================

full_install() {
    validate_repo

    if (( DEPS )); then
        install_deps
    else
        info "dependency installation disabled"
    fi

    install_configs
    install_home_files
    install_wallfliper
    install_scripts
    install_wallpapers
    setup_path
    apply_dconf

    verify_installation
}

# ============================================================
# Config-only install
# ============================================================

configs_only() {
    validate_repo

    install_configs
    install_home_files
    install_wallfliper
    install_scripts
    install_wallpapers
    setup_path
    apply_dconf

    verify_installation
}

# ============================================================
# Packages-only
# ============================================================

packages_only() {
    if (( ! DEPS )); then
        warn "--no-deps was supplied; nothing to install"
        return 0
    fi

    install_deps
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

    # Core
    check_command_status niri "Niri"
    check_command_status quickshell "Quickshell"
    check_command_status kitty "Kitty"
    check_command_status kate "Kate"

    # Wallpaper
    check_command_status awww "awww"
    check_command_status mpv "mpv"
    check_command_status ffmpeg "ffmpeg"

    # Desktop
    check_command_status python "Python"
    check_command_status pavucontrol "pavucontrol"
    check_command_status thunar "Thunar"
    check_command_status firefox "Firefox"
    check_command_status nvim "Neovim"

    # Fastfetch is only checked as an application.
    if need_command fastfetch; then
        success "Fastfetch"
    elif (( ! MINIMAL )); then
        warn "Fastfetch missing"
    fi

    # Fresh-system pieces
    if (( FRESH )); then
        check_command_status greetd "greetd"
        check_command_status tuigreet "tuigreet"
        check_command_status NetworkManager "NetworkManager"

        if [[ -f /etc/greetd/config.toml ]]; then
            success "greetd config exists"
        else
            warn "greetd config missing"
        fi
    fi

    # --------------------------------------------------------
    # Waybar intentionally gets NO package check.
    # We merely acknowledge an existing config.
    # --------------------------------------------------------

    if [[ -d "$CONFIG/waybar" ]]; then
        info "existing Waybar config detected and left untouched"
    fi

    # --------------------------------------------------------
    # Wallfliper dependency check
    # --------------------------------------------------------

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

    # --------------------------------------------------------
    # PATH
    # --------------------------------------------------------

    if path_contains_bin; then
        success "~/.local/bin is in PATH"
    else
        warn "~/.local/bin is not currently in PATH"
    fi
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

    success "Niri installed"
    success "Alice rice installed"
    success "Kate installed and configured"
    success "Wallfliper installed"
    success "~/.local/bin configured"

    if (( FRESH )); then
        success "greetd + tuigreet configured"
    fi

    printf "\n"

    printf "${CYAN}intentionally untouched:${RESET}\n"
    printf "  ${GRAY}•${RESET} ~/.config/waybar\n"
    printf "  ${GRAY}•${RESET} ~/.config/fastfetch\n"
    printf "  ${GRAY}•${RESET} Kate session state\n"

    if [[ -d "$BACKUP" ]]; then
        printf "\n"
        printf "${CYAN}backup:${RESET} %s\n" "$BACKUP"
    fi

    printf "\n"

    if (( FRESH )); then
        printf "${WHITE}${BOLD}fresh Arch setup:${RESET}\n\n"
        printf "  ${GRAY}•${RESET} reboot when ready\n"
        printf "  ${GRAY}•${RESET} log in through ${PINK}tuigreet${RESET}\n"
        printf "  ${GRAY}•${RESET} select/login to ${PINK}Niri${RESET}\n"
    else
        printf "${WHITE}${BOLD}next steps:${RESET}\n\n"
        printf "  ${GRAY}•${RESET} restart Quickshell if necessary\n"
        printf "  ${GRAY}•${RESET} restart Niri or log out/in\n"
    fi

    printf "\n"
    printf "${DIM}have fun rice-ing :3${RESET}\n\n"
}

# ============================================================
# Main
# ============================================================

main() {
    cd "$DOTFILES"

    # --------------------------------------------------------
    # Explicit command-line fresh mode.
    # --------------------------------------------------------

    if (( FRESH )); then
        fresh_install
        show_summary
        return 0
    fi

    # --------------------------------------------------------
    # No TUI.
    # --------------------------------------------------------

    if (( NO_TUI )); then
        full_install
        show_summary
        return 0
    fi

    # --------------------------------------------------------
    # Dry-run notice.
    # --------------------------------------------------------

    if (( DRY )); then
        info "dry-run mode enabled"
        printf "\n"
        pause_screen
    fi

    local choice

    menu \
        "what would you like to install?" \
        "full setup       — Niri + rice + Kate + apps + AUR" \
        "fresh Arch setup — everything + greetd + tuigreet" \
        "minimal setup    — Niri + rice + Kate + core packages" \
        "configs only     — dotfiles without packages" \
        "packages only    — install dependencies/apps" \
        "exit"

    choice=$?

    if (( choice == 255 )); then
        clear_screen
        info "bye :3"
        exit 0
    fi

    case "$choice" in
        0)
            full_install
            ;;

        1)
            FRESH=1
            fresh_install
            ;;

        2)
            MINIMAL=1

            if (( DEPS )); then
                install_deps
            fi

            install_configs
            install_home_files
            install_wallfliper
            install_scripts
            install_wallpapers
            setup_path
            apply_dconf

            verify_installation
            ;;

        3)
            configs_only
            ;;

        4)
            packages_only
            ;;

        5)
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
