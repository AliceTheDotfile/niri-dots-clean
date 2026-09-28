#
# ~/.bashrc
#

# If not running interactively, don't do anything
[[ $- != *i* ]] && return

alias ls='ls --color=auto'
alias grep='grep --color=auto'
PS1='[\u@\h \W]\$ '
TERM=kitty
export PATH="$HOME/.local/bin:$PATH"
# Detect session and launch matching fastfetch config
if [ "$XDG_CURRENT_DESKTOP" = "niri" ]; then
    fastfetch -c ~/.config/alice-rice/fastfetch.jsonc
elif [ "$XDG_CURRENT_DESKTOP" = "Hyprland" ] || [ -n "$HYPRLAND_INSTANCE_SIGNATURE" ]; then
    fastfetch -c ~/.config/fastfetch/config.jsonc
else
    fastfetch
fi

export PATH="$HOME/.local/bin:$PATH"
