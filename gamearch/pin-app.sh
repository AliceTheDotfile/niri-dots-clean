#!/bin/bash

PINS="$HOME/.config/gamearch/pinned-apps"

mkdir -p "$(dirname "$PINS")"
touch "$PINS"

# Get installed desktop applications.
apps=$(
    find \
        "$HOME/.local/share/applications" \
        /usr/local/share/applications \
        /usr/share/applications \
        -type f -name '*.desktop' 2>/dev/null |
    while read -r file; do
        name=$(grep -m1 '^Name=' "$file" | cut -d= -f2-)
        id=$(basename "$file" .desktop)

        [ -n "$name" ] && printf '%s\t%s\n' "$name" "$id"
    done |
    sort -f |
    uniq -w 0
)

choice=$(printf '%s\n' "$apps" |
    cut -f1 |
    wofi --dmenu \
        --prompt "Add application" \
        --width 400)

[ -z "$choice" ] && exit 0

desktop_id=$(printf '%s\n' "$apps" |
    awk -F '\t' -v name="$choice" '$1 == name {print $2; exit}')

[ -z "$desktop_id" ] && exit 0

if ! grep -qxF "$desktop_id" "$PINS"; then
    echo "$desktop_id" >> "$PINS"
fi

pkill -RTMIN+8 waybar
