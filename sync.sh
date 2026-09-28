#!/bin/bash
# live system -> repo, with your real home path replaced by @HOME@
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"
CFG=(alice-rice btop cava environment.d fastfetch fontconfig gamearch gtk-3.0 gtk-4.0 Kvantum niri qt6ct swaync waybar)
HOME_ITEMS=(.bashrc .bash_profile .config/kdeglobals
            .local/share/color-schemes/AliceNight.colors
            .local/share/themes/AliceNight .local/share/themes/AliceNight-Dark-hdpi .local/share/themes/AliceNight-Dark-xhdpi
            .icons/Bibata-Material-Cloud)
BIN=(wallfliper sun-wallpaper.sh app-toggle lid-fade sysdash)
EXC=(--exclude=.qmlls.ini --exclude=__pycache__ --exclude='*.log' --exclude='*.bak')

for d in "${CFG[@]}"; do
  [ -d "$HOME/.config/$d" ] || { echo "skip (not found): $d"; continue; }
  mkdir -p "$d"; rsync -a --delete "${EXC[@]}" "$HOME/.config/$d/" "$d/"
done
mkdir -p quickshell/my-shell local/bin dconf
rsync -a --delete "${EXC[@]}" "$HOME/.config/quickshell/my-shell/" quickshell/my-shell/
for i in "${HOME_ITEMS[@]}"; do
  [ -e "$HOME/$i" ] || { echo "skip (not found): ~/$i"; continue; }
  mkdir -p "home/$(dirname "$i")"
  if [ -d "$HOME/$i" ]; then rsync -a --delete "${EXC[@]}" "$HOME/$i/" "home/$i/"; else cp -a "$HOME/$i" "home/$i"; fi
done
for b in "${BIN[@]}"; do [ -f "$HOME/.local/bin/$b" ] && cp -a "$HOME/.local/bin/$b" local/bin/; done
command -v dconf >/dev/null && dconf dump /org/gnome/desktop/interface/ > dconf/interface.ini || true

# make paths portable (skips this script, the installer and the test)
grep -rIl --exclude-dir=.git --exclude=sync.sh --exclude=install.sh --exclude=test-install.sh -e "$HOME" -e "/home/alice" . \
  | xargs -r sed -i -e "s|$HOME|@HOME@|g" -e "s|/home/alice\b|@HOME@|g" || true

echo "--- sizes (prune anything huge before committing):"; du -sh home dconf Kvantum swaync 2>/dev/null || true
echo "--- possible secrets in personal files (want none):"
grep -rIniE "(api[_-]?key|token|secret|password|sk-[A-Za-z0-9])" home/.bashrc home/.bash_profile home/.config swaync dconf Kvantum 2>/dev/null | cut -c1-140 || true
echo "--- done"
