#!/usr/bin/env bash
#
# Alice's Niri dotfiles installer
#
# Usage:
#   ./install.sh
#   ./install.sh --dry-run
#   ./install.sh --no-deps
#   ./install.sh --minimal
#   ./install.sh --no-tui
#
# Notes:
#   - Never touches Waybar.
#   - Never touches Fastfetch configuration.
#   - Backs up files before replacing them.
#   - Adds ~/.local/bin to PATH if it is not already present.
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

DEPS=1
DRY=0
MINIMAL=0
NO_TUI=0

# ============================================================
# Arguments
# ============================================================

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
        --no-tui)
            NO_TUI=1
            ;;
        --help|-h)
            cat <<'EOF'
Alice's Niri dotfiles installer

Usage:
  ./install.sh                Open installer menu
  ./install.sh --dry-run      Preview changes
  ./install.sh --no-deps      Do not install packages
  ./install.sh --minimal      Install only core packages
  ./install.sh --no-tui       Skip the menu

The installer:
  - installs Niri
  - installs required rice dependencies
  - installs useful desktop applications
  - installs Wallfliper
  - installs wallpapers
  - backs up replaced files
  - adds ~/.local/bin to PATH when needed

The installer NEVER manages:
  - ~/.config/waybar
  - Waybar package installation
  - ~/.config/fastfetch
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

# Core packages required by the rice.
#
# IMPORTANT:
#   Waybar is intentionally NOT here.
#
CORE_PKGS=(
    # Compositor
    niri
    xwayland-satellite

    # Shell / UI
    quickshell
    kitty
    swaync
    wofi

    # Theming
    qt6ct
    nwg-look
    kvantum
    layer-shell-qt
    papirus-icon-theme
    dconf

    # Wallpapers
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

    # Networking / Bluetooth
    networkmanager
    network-manager-applet
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

# Nice everyday applications.
#
# Fastfetch is allowed as an APPLICATION,
# but its CONFIG DIRECTORY IS NEVER INSTALLED.
#
NICE_PKGS=(
    # Browser
    firefox

    # File management
    thunar
    file-roller
    7zip
    unzip
    zip

    # Image / media
    imv

    # Terminal / development
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

# AUR packages.
AUR_PKGS=(
    mpvpaper
    neowall-bin
)

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

    local missing=0
    local path

    for path in "${required[@]}"; do
        if [[ ! -e "$path" ]]; then
            warn "missing: ${path#$DOTFILES/}"
            missing=1
        fi
    done

    if (( missing )); then
        warn "some expected files are missing; installation will continue"
    else
        success "repository looks good"
    fi
}

# ============================================================
# Package manager
# ============================================================

need_command() {
    command -v "$1" >/dev/null 2>&1
}

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

    if [[ $EUID -eq 0 ]]; then
        fail "do not run this installer as root"
        return 1
    fi

    say "installing yay"

    run sudo pacman -Syu --needed --noconfirm base-devel git

    local tmp
    tmp="$(mktemp -d)"

    if (( DRY )); then
        info "[dry] would clone and build yay"
        rm -rf "$tmp"
        return 0
    fi

    git clone https://aur.archlinux.org/yay.git "$tmp/yay"

    (
        cd "$tmp/yay"
        makepkg -si --noconfirm
    )

    rm -rf "$tmp"

    success "yay installed"
}

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

    run sudo pacman -Syu --needed --noconfirm "${valid[@]}"

    success "official packages installed"
}

install_aur_packages() {
    local packages=("$@")

    ((${#packages[@]})) || return 0

    local helper=""

    if helper="$(find_aur_helper)"; then
        :
    else
        warn "no AUR helper was found"

        if (( DRY )); then
            info "[dry] would install yay"
            return 0
        fi

        printf "\n"
        printf "${YELLOW}This setup uses a few AUR packages.${RESET}\n"
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

    run "$helper" -S --needed --noconfirm "${packages[@]}"

    success "AUR packages installed"
}

install_deps() {
    need_command pacman || {
        fail "this installer requires Arch Linux / an Arch-based distro with pacman"
        return 1
    }

    if [[ $EUID -eq 0 ]]; then
        fail "do not run this installer as root"
        return 1
    fi

    local packages=("${CORE_PKGS[@]}")

    if (( ! MINIMAL )); then
        packages+=("${NICE_PKGS[@]}")
    fi

    install_official_packages "${packages[@]}"
    install_aur_packages "${AUR_PKGS[@]}"
}

# ============================================================
# Backup
# ============================================================

backup_destination() {
    local dest="$1"

    if [[ -e "$dest" || -L "$dest" ]]; then
        run mkdir -p "$BACKUP/$(dirname "${dest#$HOME/}")"
        run mv "$dest" "$BACKUP/${dest#$HOME/}"
    fi
}

# ============================================================
# Install files
# ============================================================

replace_home_token() {
    local path="$1"

    (( DRY )) && return 0
    [[ -e "$path" ]] || return 0

    grep -rIl -- '@HOME@' "$path" 2>/dev/null \
        | xargs -r sed -i "s|@HOME@|$HOME|g" \
        || true
}

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
        run rsync -a --exclude=.git "$src/" "$dest/"
    else
        run cp -a "$src" "$dest"
    fi

    replace_home_token "$dest"
}

# ============================================================
# Config installation
# ============================================================

install_configs() {
    say "installing configs"

    run mkdir -p \
        "$CONFIG" \
        "$BIN" \
        "$SHARE" \
        "$HOME/Wallpapers"

    # ========================================================
    # IMPORTANT
    #
    # Fastfetch is NOT in this list.
    # Waybar is NOT in this list.
    #
    # Therefore the installer never touches:
    #
    #   ~/.config/fastfetch
    #   ~/.config/waybar
    #
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
        place "$DOTFILES/$name" "$CONFIG/$name"
    done

    place \
        "$DOTFILES/quickshell/my-shell" \
        "$CONFIG/quickshell/my-shell"

    success "desktop configs installed"
    info "Fastfetch config untouched"
    info "Waybar completely untouched"
}

# ============================================================
# Home files
# ============================================================

install_home_files() {
    say "installing shell/theme files"

    local home_items=(
        ".bashrc"
        ".bash_profile"
        ".config/kdeglobals"
        ".local/share/color-schemes/AliceNight.colors"
        ".local/share/themes/AliceNight"
        ".icons/Bibata-Material-Cloud"
    )

    local item

    for item in "${home_items[@]}"; do
        place "$DOTFILES/home/$item" "$HOME/$item"
    done

    success "shell and theme files installed"
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
# Scripts
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

        run chmod +x "$BIN/$name"
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

add_path_to_file() {
    local file="$1"

    [[ -e "$file" ]] || run touch "$file"

    if grep -Fqx 'export PATH="$HOME/.local/bin:$PATH"' "$file" 2>/dev/null; then
        return 0
    fi

    if (( DRY )); then
        info "[dry] would add ~/.local/bin to ${file#$HOME/}"
        return 0
    fi

    {
        printf '\n'
        printf '# Alice dotfiles - local scripts\n'
        printf 'export PATH="$HOME/.local/bin:$PATH"\n'
    } >> "$file"
}

setup_path() {
    say "checking ~/.local/bin PATH"

    # First check the PATH that the installer is actually running with.
    if path_contains_bin; then
        success "~/.local/bin is already in PATH"
        return 0
    fi

    # Make the current installer environment use it immediately.
    if (( ! DRY )); then
        export PATH="$BIN:$PATH"
    fi

    # Persist it for future shell sessions.
    add_path_to_file "$HOME/.profile"
    add_path_to_file "$HOME/.bashrc"

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
        warn "dconf is not installed; skipping GTK settings"
        return 0
    }

    if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
        warn "no D-Bus session bus; GTK settings skipped"
        return 0
    fi

    say "applying GTK settings"

    if (( ! DRY )); then
        mkdir -p "$BACKUP"

        dconf dump /org/gnome/desktop/interface/ \
            > "$BACKUP/interface.dconf.bak" \
            2>/dev/null || true

        dconf load /org/gnome/desktop/interface/ < "$file" \
            || warn "dconf load failed"
    else
        info "[dry] would load dconf settings"
    fi
}

# ============================================================
# Services
# ============================================================

enable_service() {
    local service="$1"
    local pretty="$2"

    if ! need_command systemctl; then
        warn "systemctl unavailable; cannot enable $pretty"
        return 0
    fi

    if ! systemctl list-unit-files "$service" >/dev/null 2>&1; then
        warn "$pretty service not found"
        return 0
    fi

    if systemctl is-enabled "$service" >/dev/null 2>&1; then
        info "$pretty already enabled"
        return 0
    fi

    say "enabling $pretty"

    run sudo systemctl enable "$service"

    if (( ! DRY )); then
        if systemctl is-active --quiet "$service"; then
            success "$pretty already running"
        else
            run sudo systemctl start "$service"
            success "$pretty started"
        fi
    fi
}

setup_services() {
    (( MINIMAL )) && return 0

    printf "\n"
    printf "${PURPLE}${BOLD}desktop services${RESET}\n"
    printf "${GRAY}NetworkManager and Bluetooth are useful on a fresh Niri install.${RESET}\n"
    printf "\n"

    read -rp "enable NetworkManager + Bluetooth? [Y/n] " answer
    answer="${answer:-Y}"

    [[ "$answer" =~ ^[Yy]$ ]] || return 0

    enable_service "NetworkManager.service" "NetworkManager"
    enable_service "bluetooth.service" "Bluetooth"
}

# ============================================================
# Verification
# ============================================================

check_command_status() {
    local cmd="$1"
    local label="$2"

    if need_command "$cmd"; then
        success "$label"
    else
        warn "$label missing"
    fi
}

verify_installation() {
    say "checking installation"

    check_command_status niri "Niri"
    check_command_status quickshell "Quickshell"
    check_command_status kitty "Kitty"
    check_command_status awww "awww"
    check_command_status mpv "mpv"
    check_command_status ffmpeg "ffmpeg"
    check_command_status python "Python"
    check_command_status pavucontrol "pavucontrol"
    check_command_status thunar "Thunar"
    check_command_status firefox "Firefox"
    check_command_status nvim "Neovim"
    check_command_status "$BIN/wallfliper" "Wallfliper"

    # Fastfetch is only checked as an app.
    # Its configuration is intentionally never touched.
    check_command_status fastfetch "Fastfetch"

    # Absolutely no Waybar check here.
    if [[ -d "$CONFIG/waybar" ]]; then
        info "existing Waybar config detected and left untouched"
    fi

    if [[ -f "$SHARE/wallfliper/main.py" ]]; then
        say "checking Wallfliper dependencies"

        if (( DRY )); then
            info "[dry] would run Wallfliper dependency check"
        else
            if python "$SHARE/wallfliper/main.py" --check; then
                success "Wallfliper dependency check passed"
            else
                warn "Wallfliper reported missing dependencies"
            fi
        fi
    fi

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

    success "Niri desktop installed"
    success "Alice rice installed"
    success "Wallfliper installed"
    success "~/.local/bin configured"

    printf "\n"

    printf "${CYAN}untouched:${RESET}\n"
    printf "  ${GRAY}•${RESET} ~/.config/fastfetch\n"
    printf "  ${GRAY}•${RESET} ~/.config/waybar\n"

    if [[ -d "$BACKUP" ]]; then
        printf "\n"
        printf "${CYAN}backup:${RESET} %s\n" "$BACKUP"
    fi

    printf "\n"
    printf "${WHITE}${BOLD}next steps${RESET}\n\n"
    printf "  ${GRAY}•${RESET} log out and select ${PINK}Niri${RESET}\n"
    printf "  ${GRAY}•${RESET} or restart your Niri session\n"
    printf "  ${GRAY}•${RESET} restart Quickshell if needed\n"

    printf "\n"
    printf "${DIM}have fun rice-ing :3${RESET}\n\n"
}

# ============================================================
# Install modes
# ============================================================

do_full_install() {
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
    setup_services
    verify_installation
}

do_configs_only() {
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

do_packages_only() {
    if (( ! DEPS )); then
        warn "--no-deps was supplied; nothing to install"
        return 0
    fi

    install_deps
}

# ============================================================
# Main
# ============================================================

main() {
    cd "$DOTFILES"

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

    local choice

    if (( MINIMAL )); then
        choice=1
    else
        menu \
            "what would you like to install?" \
            "full setup      — Niri + rice + apps + AUR + services" \
            "minimal setup   — Niri + rice + required packages" \
            "configs only    — dotfiles without package installation" \
            "packages only   — install dependencies/apps" \
            "exit"

        choice=$?

        if (( choice == 255 )); then
            clear_screen
            info "bye :3"
            exit 0
        fi
    fi

    case "$choice" in
        0)
            do_full_install
            ;;
        1)
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
        2)
            do_configs_only
            ;;
        3)
            do_packages_only
            ;;
        4)
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
