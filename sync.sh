#!/bin/bash
# live ~/.config -> repo, with $HOME replaced by @HOME@
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"
CFG=(alice-rice btop cava environment.d fastfetch fontconfig gamearch gtk-3.0 gtk-4.0 niri qt6ct waybar)
BIN=(wallfliper sun-wallpaper.sh app-toggle lid-fade sysdash)
EXC=(--exclude=.qmlls.ini --exclude=__pycache__ --exclude='*.log' --exclude='*.bak')

for d in "${CFG[@]}"; do rsync -a --delete "${EXC[@]}" "$HOME/.config/$d/" "$d/"; done
mkdir -p quickshell/my-shell local/bin
rsync -a --delete "${EXC[@]}" "$HOME/.config/quickshell/my-shell/" quickshell/my-shell/
for b in "${BIN[@]}"; do [ -f "$HOME/.local/bin/$b" ] && cp -a "$HOME/.local/bin/$b" local/bin/; done

# make paths portable
grep -rIl --exclude-dir=.git --exclude=sync.sh --exclude=install.sh -e "$HOME" -e "/home/alice" . | xargs -r sed -i -e "s|$HOME|@HOME@|g" -e "s|/home/alice\b|@HOME@|g"
echo "--- done"
