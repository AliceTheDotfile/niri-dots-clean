#!/bin/sh

case "$1" in
    steam)
        steam
        ;;
    chromium)
        chromium
        ;;
    kitty)
        kitty
        ;;
    files)
        thunar
        ;;
esac
