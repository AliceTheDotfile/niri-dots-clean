#!/usr/bin/env bash
# alice's niri rice installer. usage: ./install.sh [--no-deps] [--dry-run]
# never deletes: anything it replaces is moved to ~/.dotfiles-backup/<timestamp>/
set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
SHARE="${XDG_DATA_HOME:-$HOME/.local/share}"
BIN="$HOME/.local/bin"
BACKUP="$HOME/.dotfiles-backup/$(date +%Y%m%d-%H%M%S)"
DEPS=1; DRY=0
for a in "$@"; do case $a in --no-deps) DEPS=0;; --dry-run) DRY=1;; *) echo "unknown flag $a"; exit 1;; esac; done

say()  { printf '\033[1;35m::\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
run()  { if [ "$DRY" = 1 ]; then echo "  [dry] $*"; else "$@"; fi; }

# folders installed to ~/.config/<name>
CONFIGS=(alice-rice btop cava environment.d fastfetch fontconfig gamearch gtk-3.0 gtk-4.0 Kvantum niri qt6ct swaync waybar)
# files/folders installed to ~/<path> (stored under home/ in the repo)
HOME_ITEMS=(.bashrc .bash_profile .config/kdeglobals
            .local/share/color-schemes/AliceNight.colors
            .local/share/themes/AliceNight
            .icons/Bibata-Material-Cloud)

# ---------- packages (edit these lists) ----------
PKGS=(niri waybar kitty cava btop fastfetch qt6ct nwg-look kvantum papirus-icon-theme swaync
      brightnessctl playerctl grim slurp wl-clipboard rsync jq dconf xwayland-satellite pyside6
      ttf-hack noto-fonts noto-fonts-emoji otf-atkinsonhyperlegiblemono-nerd woff2-font-awesome)
AUR_PKGS=(quickshell awww)

install_deps() {
  command -v pacman >/dev/null || { warn "not an Arch-based system; install deps by hand (see PKGS in install.sh)"; return 0; }
  local helper=""; for h in yay paru; do command -v $h >/dev/null && { helper=$h; break; }; done
  say "installing packages"
  for p in "${PKGS[@]}" "${AUR_PKGS[@]}"; do
    if pacman -Qq "$p" &>/dev/null; then continue; fi
    if pacman -Si "$p" &>/dev/null; then
      run sudo pacman -S --needed --noconfirm "$p" || warn "failed: $p"
    elif [ -n "$helper" ]; then
      run "$helper" -S --needed --noconfirm "$p" || warn "failed (AUR): $p"
    else
      warn "$p needs an AUR helper (install yay or paru) - skipped"
    fi
  done
}

# place <src> <dest>: file or folder. backs up whatever is at dest, then fills in @HOME@
place() {
  local src="$1" dest="$2"
  [ -e "$src" ] || { warn "missing in repo: ${src#$DOTFILES/}"; return 0; }
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    run mkdir -p "$BACKUP/$(dirname "${dest#$HOME/}")"
    run mv "$dest" "$BACKUP/${dest#$HOME/}"
  fi
  run mkdir -p "$(dirname "$dest")"
  if [ -d "$src" ]; then run mkdir -p "$dest"; run rsync -a --exclude=.git "$src/" "$dest/"
  else run cp -a "$src" "$dest"; fi
  if [ "$DRY" != 1 ]; then grep -rIl -- '@HOME@' "$dest" 2>/dev/null | xargs -r sed -i "s|@HOME@|$HOME|g" || true; fi
}

apply_dconf() {
  local f="$DOTFILES/dconf/interface.ini" real
  [ -f "$f" ] || return 0
  command -v dconf >/dev/null || { warn "dconf not installed - skipping GTK desktop settings"; return 0; }
  real="$(getent passwd "$(id -u)" | cut -d: -f6)"
  if [ "$HOME" != "$real" ]; then say "HOME is not your real home - skipping dconf (test mode)"; return 0; fi
  say "loading GTK/GNOME interface settings (dconf)"
  run mkdir -p "$BACKUP"
  [ "$DRY" = 1 ] || dconf dump /org/gnome/desktop/interface/ > "$BACKUP/interface.dconf.bak" 2>/dev/null || true
  run dconf load /org/gnome/desktop/interface/ < "$f" || warn "dconf load failed (needs a running session bus)"
}

if [ "$DEPS" = 1 ]; then install_deps; fi

say "installing configs to $CONFIG"
run mkdir -p "$CONFIG" "$BIN" "$SHARE" "$HOME/Wallpapers"
for d in "${CONFIGS[@]}"; do place "$DOTFILES/$d" "$CONFIG/$d"; done
place "$DOTFILES/quickshell/my-shell" "$CONFIG/quickshell/my-shell"

say "installing shell, GTK/KDE themes and cursors"
for i in "${HOME_ITEMS[@]}"; do place "$DOTFILES/home/$i" "$HOME/$i"; done

say "installing wallfliper"
place "$DOTFILES/wallfliper" "$SHARE/wallfliper"
place "$DOTFILES/wallfliper/config.json" "$CONFIG/wallfliper/config.json"

say "installing scripts to $BIN"
for f in "$DOTFILES"/local/bin/*; do
  [ -f "$f" ] || continue
  place "$f" "$BIN/$(basename "$f")"
  run chmod +x "$BIN/$(basename "$f")"
done

say "installing wallpapers (never overwrites yours)"
for f in "$DOTFILES"/Wallpapers/*; do
  [ -e "$f" ] || continue
  [ -e "$HOME/Wallpapers/$(basename "$f")" ] || run cp -a "$f" "$HOME/Wallpapers/"
done

apply_dconf

case ":$PATH:" in *":$BIN:"*) ;; *) warn "$BIN is not in your PATH - add it to your shell profile";; esac
if [ -d "$BACKUP" ]; then say "old files backed up to $BACKUP"; fi
say "done :3  log out and pick niri, or restart niri/quickshell/waybar"
