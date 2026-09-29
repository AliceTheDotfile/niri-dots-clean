
#!/usr/bin/env bash
#
# Alice's Niri dotfiles reverse sync :3
#
# Live system -> dotfiles repository
#
# Usage:
#   ./sync.sh
#   ./sync.sh --dry-run
#   ./sync.sh --prune
#   ./sync.sh --commit
#   ./sync.sh --push
#
# ============================================================

set -Eeuo pipefail

# ============================================================
# Paths
# ============================================================

DOTFILES="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
SHARE="${XDG_DATA_HOME:-$HOME/.local/share}"
BIN="$HOME/.local/bin"

DRY=0
PRUNE=0
AUTO_COMMIT=0
AUTO_PUSH=0

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

pause_screen() {
    printf "\n${GRAY}press enter to continue...${RESET}"
    read -r
}

# ============================================================
# Help
# ============================================================

show_help() {
    cat <<'EOF'
Alice's Niri dotfiles reverse sync :3

Copies your live rice back into the git repository.

Usage:
  ./sync.sh
      Open the interactive menu.

  ./sync.sh --dry-run
      Show every file that would be changed,
      including its live source path and repo destination.

  ./sync.sh --prune
      Also delete repo files that no longer exist
      on the live system.

  ./sync.sh --commit
      Sync and create a git commit.

  ./sync.sh --push
      Sync, commit and push.

Files intentionally NOT synchronized:
  ~/.config/waybar
  ~/.config/fastfetch
  ~/.local/share/kate/anonymous.katesession
EOF
}

# ============================================================
# Arguments
# ============================================================

for arg in "$@"; do
    case "$arg" in
        --dry-run)
            DRY=1
            ;;

        --prune)
            PRUNE=1
            ;;

        --commit)
            AUTO_COMMIT=1
            ;;

        --push)
            AUTO_COMMIT=1
            AUTO_PUSH=1
            ;;

        --help|-h)
            show_help
            exit 0
            ;;

        *)
            fail "unknown option: $arg"
            exit 1
            ;;
    esac
done

# ============================================================
# Safety
# ============================================================

cleanup() {
    printf '\033[0m\n'
}

trap cleanup EXIT
trap 'fail "sync failed on line $LINENO"; exit 1' ERR

if (( EUID == 0 )); then
    fail "do not run this as root"
    exit 1
fi

command -v git >/dev/null 2>&1 || {
    fail "git is required"
    exit 1
}

command -v rsync >/dev/null 2>&1 || {
    fail "rsync is required"
    exit 1
}

[[ -d "$DOTFILES/.git" ]] || {
    fail "this script must be inside your dotfiles git repository"
    exit 1
}

# ============================================================
# Managed config directories
# ============================================================

CONFIG_DIRS=(
    "alice-rice"
    "btop"
    "cava"
    "environment.d"
    "fontconfig"
    "gamearch"
    "gtk-3.0"
    "gtk-4.0"
    "Kvantum"
    "niri"
    "qt6ct"
    "swaync"
)

HOME_ITEMS=(
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

# ============================================================
# Temp files
# ============================================================

TMP_FILES=()

make_temp() {
    local tmp
    tmp="$(mktemp)"
    TMP_FILES+=("$tmp")
    printf '%s\n' "$tmp"
}

cleanup_temp_files() {
    local file

    for file in "${TMP_FILES[@]}"; do
        [[ -e "$file" ]] && rm -f -- "$file"
    done
}

trap cleanup_temp_files EXIT

# ============================================================
# Normalize @HOME@
# ============================================================

normalize_file() {
    local file="$1"

    [[ -f "$file" ]] || return 0

    if grep -Iq . "$file" 2>/dev/null; then
        sed -i "s|$HOME|@HOME@|g" "$file"
    fi
}

normalize_tree() {
    local dir="$1"

    [[ -d "$dir" ]] || return 0

    while IFS= read -r -d '' file; do
        normalize_file "$file"
    done < <(
        find "$dir" \
            -type f \
            -not -path '*/.git/*' \
            -not -name 'anonymous.katesession' \
            -print0
    )
}

# ============================================================
# Show one file mapping
# ============================================================

show_file_mapping() {
    local src="$1"
    local dst="$2"
    local action="$3"

    case "$action" in
        add)
            printf "    ${GREEN}[ADD]${RESET} %s\n" "$src"
            ;;

        update)
            printf "    ${YELLOW}[UPD]${RESET} %s\n" "$src"
            ;;

        delete)
            printf "    ${RED}[DEL]${RESET} %s\n" "$dst"
            ;;

        *)
            printf "    ${CYAN}[SYNC]${RESET} %s\n" "$src"
            ;;
    esac

    if [[ "$action" != "delete" ]]; then
        printf "         ${GRAY}→ %s${RESET}\n" "$dst"
    fi
}

# ============================================================
# Print rsync changes
#
# Itemized rsync format:
#   position 1 = file type
#
#   f = regular file
#   d = directory
#   L = symlink
#
# Directory timestamp-only entries are not shown because
# the user asked for the actual files being synchronized.
# ============================================================

print_rsync_changes() {
    local log="$1"
    local src_root="$2"
    local dst_root="$3"

    [[ -f "$log" ]] || return 0

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue

        #
        # We use:
        #   %i|%n
        #
        # so split the itemized status from the path.
        #

        local code="${line%%|*}"
        local rel="${line#*|}"

        #
        # Deletions are represented as:
        #   *deleting|path
        #

        if [[ "$code" == \*deleting ]]; then
            show_file_mapping \
                "" \
                "$dst_root/$rel" \
                "delete"

            continue
        fi

        #
        # Ignore directory-only entries.
        #

        local type="${code:1:1}"

        if [[ "$type" == "d" ]]; then
            continue
        fi

        #
        # Ignore entries that contain no actual change.
        #

        [[ "$code" != ".......... " ]] || continue

        local src="$src_root/$rel"
        local dst="$dst_root/$rel"

        if [[ "$code" == "+++++++++++++"* ]]; then
            show_file_mapping "$src" "$dst" "add"
        else
            show_file_mapping "$src" "$dst" "update"
        fi
    done < "$log"
}

# ============================================================
# Sync one file
# ============================================================

sync_file() {
    local src="$1"
    local dst="$2"

    if [[ ! -e "$src" && ! -L "$src" ]]; then
        if (( PRUNE )) && [[ -e "$dst" || -L "$dst" ]]; then
            if (( DRY )); then
                show_file_mapping "" "$dst" "delete"
            else
                show_file_mapping "" "$dst" "delete"
                rm -rf -- "$dst"
            fi
        fi

        return 0
    fi

    local changed=0

    if [[ ! -e "$dst" && ! -L "$dst" ]]; then
        changed=1
    elif [[ -f "$src" && -f "$dst" ]]; then
        if ! cmp -s "$src" "$dst"; then
            changed=1
        fi
    elif [[ -L "$src" || -L "$dst" ]]; then
        if [[ "$(readlink "$src" 2>/dev/null || true)" != "$(readlink "$dst" 2>/dev/null || true)" ]]; then
            changed=1
        fi
    else
        changed=1
    fi

    (( changed )) || return 0

    if (( DRY )); then
        if [[ -e "$dst" || -L "$dst" ]]; then
            show_file_mapping "$src" "$dst" "update"
        else
            show_file_mapping "$src" "$dst" "add"
        fi

        return 0
    fi

    mkdir -p -- "$(dirname -- "$dst")"
    cp -a -- "$src" "$dst"

    normalize_file "$dst"

    if [[ -e "$dst" || -L "$dst" ]]; then
        if [[ -e "$src" ]]; then
            if [[ -e "$dst" ]]; then
                show_file_mapping "$src" "$dst" "update"
            fi
        fi
    fi
}

# ============================================================
# Sync directory
# ============================================================

sync_dir() {
    local src="$1"
    local dst="$2"

    if [[ ! -d "$src" ]]; then
        if (( PRUNE )) && [[ -d "$dst" ]]; then
            if (( DRY )); then
                printf "    ${RED}[DEL]${RESET} %s\n" "$dst"
            else
                printf "    ${RED}[DEL]${RESET} %s\n" "$dst"
                rm -rf -- "$dst"
            fi
        fi

        return 0
    fi

    local log
    log="$(make_temp)"

    local args=(
        -a
        --itemize-changes
        --out-format='%i|%n'
        --exclude=.git/
        --exclude=__pycache__/
        --exclude='*.pyc'
        --exclude='*.log'
        --exclude='anonymous.katesession'
    )

    if (( PRUNE )); then
        args+=(--delete)
    fi

    #
    # First perform a dry-run to determine exactly what will
    # change. This gives us the full source -> destination paths.
    #

    rsync \
        "${args[@]}" \
        --dry-run \
        "$src/" \
        "$dst/" \
        > "$log"

    print_rsync_changes \
        "$log" \
        "$src" \
        "$dst"

    #
    # Dry-run ends here.
    #

    if (( DRY )); then
        return 0
    fi

    #
    # Nothing else to determine; perform the actual sync.
    #

    rsync \
        -a \
        --exclude=.git/ \
        --exclude=__pycache__/ \
        --exclude='*.pyc' \
        --exclude='*.log' \
        --exclude='anonymous.katesession' \
        $( (( PRUNE)) && printf '%s' '--delete' ) \
        "$src/" \
        "$dst/"

    normalize_tree "$dst"
}

# ============================================================
# Sync ~/.config
# ============================================================

sync_configs() {
    say "syncing ~/.config"

    local name

    for name in "${CONFIG_DIRS[@]}"; do
        sync_dir \
            "$CONFIG/$name" \
            "$DOTFILES/$name"
    done

    sync_dir \
        "$CONFIG/quickshell/my-shell" \
        "$DOTFILES/quickshell/my-shell"

    sync_file \
        "$CONFIG/wallfliper/config.json" \
        "$DOTFILES/wallfliper/config.json"

    success "configuration sync complete"
}

# ============================================================
# Sync home configuration
# ============================================================

sync_home() {
    say "syncing home configuration"

    local item

    for item in "${HOME_ITEMS[@]}"; do
        local src="$HOME/$item"
        local dst="$DOTFILES/home/$item"

        if [[ -d "$src" ]]; then
            sync_dir "$src" "$dst"
        else
            sync_file "$src" "$dst"
        fi
    done

    success "home configuration sync complete"
}

# ============================================================
# Sync Wallfliper
# ============================================================

sync_wallfliper() {
    say "syncing Wallfliper"

    sync_dir \
        "$SHARE/wallfliper" \
        "$DOTFILES/wallfliper"

    sync_file \
        "$CONFIG/wallfliper/config.json" \
        "$DOTFILES/wallfliper/config.json"

    success "Wallfliper sync complete"
}

# ============================================================
# Sync local scripts
# ============================================================

sync_scripts() {
    say "syncing ~/.local/bin"

    sync_dir \
        "$BIN" \
        "$DOTFILES/local/bin"

    success "local scripts sync complete"
}

# ============================================================
# Sync wallpapers
# ============================================================

sync_wallpapers() {
    say "syncing ~/Wallpapers"

    sync_dir \
        "$HOME/Wallpapers" \
        "$DOTFILES/Wallpapers"

    success "wallpaper sync complete"
}

# ============================================================
# Sync dconf
# ============================================================

sync_dconf() {
    local dst="$DOTFILES/dconf/interface.ini"

    command -v dconf >/dev/null 2>&1 || {
        warn "dconf not installed; skipping dconf"
        return 0
    }

    [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] || {
        warn "no D-Bus session; skipping dconf"
        return 0
    }

    say "syncing GNOME/GTK dconf"

    if (( DRY )); then
        info "[dry] ${dst}"
        return 0
    fi

    mkdir -p -- "$(dirname -- "$dst")"

    dconf dump \
        /org/gnome/desktop/interface/ \
        > "$dst"

    printf "    ${CYAN}[SYNC]${RESET} dconf:/org/gnome/desktop/interface/\n"
    printf "         ${GRAY}→ %s${RESET}\n" "$dst"

    success "dconf sync complete"
}

# ============================================================
# Git status
# ============================================================

show_git_status() {
    printf "\n"
    say "repository changes"

    local status
    status="$(git -C "$DOTFILES" status --short)"

    if [[ -z "$status" ]]; then
        success "no changes detected"
        return 0
    fi

    printf "\n%s\n" "$status"
}

# ============================================================
# Commit
# ============================================================

make_commit() {
    local message="sync: update rice from live system"

    if ! git -C "$DOTFILES" status --short | grep -q .; then
        info "nothing to commit"
        return 0
    fi

    if (( DRY )); then
        info "[dry] would create commit: $message"
        return 0
    fi

    git -C "$DOTFILES" add -A

    git -C "$DOTFILES" commit \
        -m "$message"

    success "commit created"
}

# ============================================================
# Push
# ============================================================

push_repo() {
    (( AUTO_PUSH )) || return 0

    if (( DRY )); then
        info "[dry] would git push"
        return 0
    fi

    git -C "$DOTFILES" push

    success "repository pushed"
}

# ============================================================
# Full sync
# ============================================================

do_sync() {
    clear_screen

    printf "\n"
    printf " ${PINK}╭──────────────────────────────────────────────────────╮${RESET}\n"
    printf " ${PINK}│${RESET} ${BOLD}${WHITE}alice's reverse rice sync${RESET} ${DIM}:3${RESET}                  ${PINK}│${RESET}\n"
    printf " ${PINK}│${RESET} ${GRAY}live system → git repository${RESET}                     ${PINK}│${RESET}\n"
    printf " ${PINK}╰──────────────────────────────────────────────────────╯${RESET}\n\n"

    if (( DRY )); then
        info "dry-run mode"
    fi

    if (( PRUNE )); then
        warn "prune mode enabled"
    fi

    printf "\n"

    sync_configs
    sync_home
    sync_wallfliper
    sync_scripts
    sync_wallpapers
    sync_dconf

    show_git_status

    if (( AUTO_COMMIT )); then
        printf "\n"
        make_commit
        push_repo
    fi

    printf "\n"
    success "reverse sync finished :3"
}

# ============================================================
# Interactive menu
# ============================================================

draw_menu() {
    clear_screen

    printf "\n"
    printf " ${PINK}╭──────────────────────────────────────────────────────╮${RESET}\n"
    printf " ${PINK}│${RESET} ${BOLD}${WHITE}alice's reverse rice sync${RESET} ${DIM}:3${RESET}                  ${PINK}│${RESET}\n"
    printf " ${PINK}│${RESET} ${GRAY}live system → dotfiles repository${RESET}              ${PINK}│${RESET}\n"
    printf " ${PINK}╰──────────────────────────────────────────────────────╯${RESET}\n\n"

    printf " ${PURPLE}${BOLD}what should i do?${RESET}\n\n"
    printf "   ${PINK}1${RESET}  sync live rice → repo\n"
    printf "   ${PINK}2${RESET}  sync + commit\n"
    printf "   ${PINK}3${RESET}  sync + commit + push\n"
    printf "   ${PINK}4${RESET}  dry-run\n"
    printf "   ${PINK}5${RESET}  sync + prune deleted files\n"
    printf "   ${PINK}6${RESET}  show git status\n"
    printf "   ${PINK}7${RESET}  exit\n"
    printf "\n"
}

interactive() {
    while true; do
        draw_menu

        read -rp " ${WHITE}choice: ${RESET}" choice

        case "$choice" in
            1)
                DRY=0
                PRUNE=0
                AUTO_COMMIT=0
                AUTO_PUSH=0
                do_sync
                pause_screen
                ;;

            2)
                DRY=0
                PRUNE=0
                AUTO_COMMIT=1
                AUTO_PUSH=0
                do_sync
                pause_screen
                ;;

            3)
                DRY=0
                PRUNE=0
                AUTO_COMMIT=1
                AUTO_PUSH=1
                do_sync
                pause_screen
                ;;

            4)
                DRY=1
                PRUNE=0
                AUTO_COMMIT=0
                AUTO_PUSH=0
                do_sync
                pause_screen
                ;;

            5)
                DRY=0
                PRUNE=1
                AUTO_COMMIT=0
                AUTO_PUSH=0
                do_sync
                pause_screen
                ;;

            6)
                clear_screen
                show_git_status
                pause_screen
                ;;

            7|q|Q)
                clear_screen
                info "bye :3"
                exit 0
                ;;

            *)
                warn "invalid choice"
                sleep 1
                ;;
        esac
    done
}

# ============================================================
# Main
# ============================================================

main() {
    cd -- "$DOTFILES"

    if (($# > 0)); then
        do_sync
        return 0
    fi

    interactive
}

main "$@"

