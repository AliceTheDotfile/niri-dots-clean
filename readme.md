# niri-dots-clean

my personal Arch Linux dotfiles for a clean, minimal Niri setup.

these configs include Niri, Quickshell, Waybar, Wofi, GTK, Qt, Neowall, Fastfetch, Cava, Btop, and various custom scripts and wallpapers.

## installation

clone the repository and run the installer:

```bash
git clone https://github.com/AliceTheDotfile/niri-dots-clean.git ~/niri-dots-clean
cd ~/niri-dots-clean
./install.sh
```

the installer will copy the included configuration files into `~/.config`, install scripts into `~/.local/bin`, and install the included wallpapers into `~/Wallpapers`.

> **warning:** the installer replaces existing configurations for the components included in this repository. back up your current configs before installing if you want to keep them.

## included

* Niri
* Quickshell
* Waybar
* Wofi
* GTK 3 / GTK 4
* Qt6ct
* Neowall
* Fastfetch
* Cava
* Btop
* Custom scripts
* Wallpapers
* Environment configuration
* Font configuration

## requirements

this setup is primarily intended for Arch Linux and assumes the required applications and dependencies are installed on your system.

some parts of the configuration may need additional packages depending on which features you use.

## updating

to update an existing installation:

```bash
cd ~/niri-dots-clean
git pull
./install.sh
```

## notes

these are my personal dotfiles, so some settings may be specific to my hardware and setup. you may need to modify parts of the configuration for your own system.

have fun rice-ing :3
