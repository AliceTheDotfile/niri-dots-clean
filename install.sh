#!/usr/bin/env bash
# alice's niri rice installer. usage: ./install.sh [--no-deps] [--dry-run]
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

# config folders copied to ~/.config/<name>
CONFIGS=(alice-rice btop cava environment.d fastfetch fontconfig gamearch
         gtk-3.0 gtk-4.0 niri qt6ct waybar)

# ---------- packages (edit these lists) ----------
PKGS=(niri waybar kitty cava btop fastfetch qt6ct nwg-look kvantum papirus-icon-theme swaync starship brightnessctl playerctl grim slurp wl-clipboard rsync jq xwayland-satellite python-pyside6 ttf-hack noto-fonts noto-fonts-emoji otf-atkinsonhyperlegiblemono-nerd woff2-font-awesome)
AUR_PKGS=(quickshell awww)

install_deps() {
  command -v pacman >/dev/null || { warn "not an Arch-based system; install deps by hand (see PKGS in install.sh)"; return; }
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

# copy a dir into place, backing up whatever was there, then fill in @HOME@
place() {  # place <src-dir> <dest-dir>
  local src="$1" dest="$2"
  [ -d "$src" ] || { warn "missing $src"; return; }
  if [ -e "$dest" ]; then
    run mkdir -p "$BACKUP/$(dirname "${dest#$HOME/}")"
    run mv "$dest" "$BACKUP/${dest#$HOME/}"
  fi
  run mkdir -p "$dest"
  run rsync -a --exclude=.git "$src/" "$dest/"
  [ "$DRY" = 1 ] || grep -rIl -- '@HOME@' "$dest" 2>/dev/null | xargs -r sed -i "s|@HOME@|$HOME|g" || true
}

[ "$DEPS" = 1 ] && install_deps

say "installing configs to $CONFIG"
run mkdir -p "$CONFIG" "$BIN" "$SHARE" "$HOME/Wallpapers"
for d in "${CONFIGS[@]}"; do place "$DOTFILES/$d" "$CONFIG/$d"; done
place "$DOTFILES/quickshell/my-shell" "$CONFIG/quickshell/my-shell"

say "installing wallfliper"
place "$DOTFILES/wallfliper" "$SHARE/wallfliper"
run mkdir -p "$CONFIG/wallfliper"
run cp -a "$SHARE/wallfliper/config.json" "$CONFIG/wallfliper/config.json" 2>/dev/null || true

say "installing scripts to $BIN"
for f in "$DOTFILES"/local/bin/*; do
  [ -f "$f" ] || continue
  run install -m 755 "$f" "$BIN/$(basename "$f")"
  [ "$DRY" = 1 ] || sed -i "s|@HOME@|$HOME|g" "$BIN/$(basename "$f")"
done

say "installing wallpapers (never overwrites yours)"
for f in "$DOTFILES"/Wallpapers/*; do
  [ -e "$f" ] || continue
  [ -e "$HOME/Wallpapers/$(basename "$f")" ] || run cp -a "$f" "$HOME/Wallpapers/"
done

case ":$PATH:" in *":$BIN:"*) ;; *) warn "$BIN is not in your PATH - add it to your shell profile";; esac
[ -d "$BACKUP" ] && say "old configs backed up to $BACKUP"
say "done :3  log out and pick niri, or restart niri/quickshell/waybar"
