#!/bin/bash
set -e

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "installing alice's rice..."

configs=(
    alice-rice
    btop
    cava
    environment.d
    fastfetch
    fontconfig
    gamearch
    gtk-3.0
    gtk-4.0
    neowall
    niri
    quickshell
    qt6ct
    waybar
    wofi
)

mkdir -p "$HOME/.config" "$HOME/.local/bin" "$HOME/Wallpapers"

for dir in "${configs[@]}"; do
    echo "installing ~/.config/$dir"
    rm -rf "$HOME/.config/$dir"
    cp -a "$DOTFILES/$dir" "$HOME/.config/$dir"
done

echo "installing wallfliper..."
rm -rf "$HOME/.config/wallfliper" "$HOME/.local/share/wallfliper"
mkdir -p "$HOME/.config/wallfliper" "$HOME/.local/share/wallfliper"
cp -a "$DOTFILES/wallfliper/config.json" "$HOME/.config/wallfliper/config.json"
sed -i "s#"wallpaper_dir": ".*"#"wallpaper_dir": "$HOME/Wallpapers"#" "$HOME/.config/wallfliper/config.json"
rsync -a --exclude="config.json" "$DOTFILES/wallfliper/" "$HOME/.local/share/wallfliper/"

echo "installing scripts..."
for file in "$DOTFILES"/local/bin/*; do
    [ -f "$file" ] || continue
    cp -a "$file" "$HOME/.local/bin/"
    chmod +x "$HOME/.local/bin/$(basename "$file")"
done

echo "installing wallpapers..."
for file in "$DOTFILES"/Wallpapers/*; do
    [ -e "$file" ] || continue

    name="$(basename "$file")"

    if [ ! -e "$HOME/Wallpapers/$name" ]; then
        cp -a "$file" "$HOME/Wallpapers/$name"
        echo "  added $name"
    else
        echo "  keeping existing $name"
    fi
done

echo
echo "rice installed :3"
echo "restart niri/quickshell/waybar or log back in for everything to reload."
