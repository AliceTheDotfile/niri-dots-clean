#!/bin/bash

PINS="$HOME/.config/gamearch/pinned-apps"

grep -vxF "$1" "$PINS" > "$PINS.tmp"
mv "$PINS.tmp" "$PINS"

pkill -RTMIN+8 waybar
