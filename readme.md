
# alice's niri dots

my personal Niri desktop rice for Arch Linux :3

this repository contains my Niri configuration, Quickshell shell, themes, Wallfliper setup, local scripts, wallpapers, and the supporting packages needed to run the desktop.

the installer is designed to be usable both from a local git clone and directly from GitHub.

---

## quick install

the easiest way to install the rice is:

```bash
curl -fsSL https://raw.githubusercontent.com/AliceTheDotfile/niri-dots-clean/main/install.sh | bash
````

the installer will:

1. download the latest repository from GitHub
2. extract it into a temporary directory
3. install the requested configuration and packages
4. clean up the temporary repository when it exits

nothing needs to be cloned into your home directory.

---

## non-interactive install

the normal command opens the keyboard-driven installer menu.

for a normal full install without the menu:

```bash
curl -fsSL https://raw.githubusercontent.com/AliceTheDotfile/niri-dots-clean/main/install.sh | bash -s -- --no-tui
```

minimal installation:

```bash
curl -fsSL https://raw.githubusercontent.com/AliceTheDotfile/niri-dots-clean/main/install.sh | bash -s -- --minimal
```

fresh Arch installation:

```bash
curl -fsSL https://raw.githubusercontent.com/AliceTheDotfile/niri-dots-clean/main/install.sh | bash -s -- --fresh
```

---

## local installation

you can also clone the repository normally:

```bash
git clone https://github.com/AliceTheDotfile/niri-dots-clean.git
cd niri-dots-clean
./install.sh
```

when `install.sh` is executed from a complete local checkout, it uses that checkout directly instead of downloading another copy.

---

## what the installer installs

the core desktop setup includes:

* Niri
* xwayland-satellite
* Quickshell
* Kitty
* SwayNC
* Wofi
* Kate
* qt6ct
* nwg-look
* Kvantum
* Papirus icons
* awww
* mpv
* ffmpeg
* Python
* PipeWire
* WirePlumber
* playerctl
* pavucontrol
* brightnessctl
* grim
* slurp
* wl-clipboard
* NetworkManager
* Bluetooth support
* useful command-line utilities
* fonts

the normal non-minimal installation also adds applications such as:

* Firefox
* Thunar
* File Roller
* 7zip
* unzip
* zip
* imv
* Neovim
* fzf
* ripgrep
* fd
* bat
* eza
* tree
* less
* Fastfetch
* man-db
* man-pages

AUR packages:

* mpvpaper
* neowall-bin

if `yay` or `paru` is already installed, the installer uses it.

if neither is installed, the installer can bootstrap `yay` automatically.

---

## installer modes

### normal installation

```bash
./install.sh
```

opens the interactive installer menu.

---

### full installation

```bash
./install.sh --no-tui
```

installs the full desktop, configuration, applications, and AUR packages without showing the menu.

---

### minimal installation

```bash
./install.sh --minimal
```

installs the core Niri environment without the additional "nice to have" applications.

---

### fresh Arch setup

```bash
./install.sh --fresh
```

fresh mode is intended for a mostly-empty Arch installation.

in addition to the regular desktop setup, it installs and configures:

* greetd
* greetd-tuigreet
* NetworkManager
* Bluetooth

greetd is configured to launch Niri through `niri-session`.

---

### update an existing local clone

```bash
./install.sh --update
```

when running from a local git repository, update mode:

1. checks the working tree
2. refuses to continue if there are uncommitted changes
3. runs `git pull --ff-only`
4. applies the updated rice
5. backs up existing managed files first

local repository changes are never automatically overwritten.

---

### update directly from GitHub

the same command can be used through the one-line installer:

```bash
curl -fsSL https://raw.githubusercontent.com/AliceTheDotfile/niri-dots-clean/main/install.sh | bash -s -- --update
```

because the installer has already downloaded the latest GitHub snapshot, it does not need a local `.git` directory.

the downloaded repository is removed automatically when the installer exits.

---

### configs only

```bash
./install.sh --configs-only
```

installs the rice without installing packages.

---

### packages only

```bash
./install.sh --packages-only
```

installs the requested packages without copying configuration files.

this mode does not need to download the repository.

---

### skip dependency installation

```bash
./install.sh --no-deps
```

skips package installation and only applies the configuration.

this is useful when the required packages are already installed.

---

### dry run

```bash
./install.sh --dry-run
```

shows what the installer intends to do without performing the commands passed through the install helper.

---

### no TUI

```bash
./install.sh --no-tui
```

runs the normal full installation directly.

options can be combined.

for example:

```bash
./install.sh --minimal --no-deps
```

or:

```bash
curl -fsSL https://raw.githubusercontent.com/AliceTheDotfile/niri-dots-clean/main/install.sh | bash -s -- --minimal --no-deps
```

---

## files intentionally left alone

the installer deliberately does **not** manage everything on the system.

### Waybar

the installer never:

* installs Waybar
* copies Waybar configuration
* backs up Waybar configuration
* verifies Waybar configuration

existing:

```text
~/.config/waybar
```

is left untouched.

---

### Fastfetch

Fastfetch may be installed as an application, but the installer never copies or modifies:

```text
~/.config/fastfetch
```

an existing Fastfetch configuration is left alone.

---

### Kate sessions

reusable Kate configuration is installed:

```text
~/.config/kate
~/.config/katerc
~/.config/katevirc
~/.config/katemetainfos
```

Kate session files are intentionally not installed.

in particular:

```text
~/.local/share/kate/anonymous.katesession
```

is not copied.

---

## configuration files

the main configuration directories are installed into:

```text
~/.config/
```

including:

```text
alice-rice
btop
cava
environment.d
fontconfig
gamearch
gtk-3.0
gtk-4.0
Kvantum
niri
qt6ct
swaync
```

Quickshell is installed to:

```text
~/.config/quickshell/my-shell
```

---

## shell and theme files

the installer manages:

```text
~/.bashrc
~/.bash_profile
~/.config/kdeglobals
~/.config/kate
~/.config/katerc
~/.config/katevirc
~/.config/katemetainfos
~/.local/share/color-schemes/AliceNight.colors
~/.local/share/themes/AliceNight
~/.icons/Bibata-Material-Cloud
```

the installer also makes sure:

```text
~/.local/bin
```

is available in `PATH`.

---

## Wallfliper

Wallfliper is installed into:

```text
~/.local/share/wallfliper
```

with its configuration at:

```text
~/.config/wallfliper/config.json
```

the executable launcher is placed in:

```text
~/.local/bin/wallfliper
```

if a matching launcher already exists, it is backed up before replacement.

---

## local scripts

every regular file in:

```text
local/bin/
```

is copied to:

```text
~/.local/bin/
```

and marked executable.

---

## wallpapers

wallpapers from:

```text
Wallpapers/
```

are copied to:

```text
~/Wallpapers/
```

existing wallpapers are not overwritten.

---

## backups

before replacing an existing managed file or directory, the installer moves it into:

```text
~/.dotfiles-backup/<timestamp>/
```

for example:

```text
~/.dotfiles-backup/20260929-143500/
```

this makes it possible to recover previous configuration files after an installation or update.

wallpapers are treated differently: an existing wallpaper is kept rather than backed up or overwritten.

---

## GitHub bootstrap details

the one-line installer downloads:

```text
https://github.com/AliceTheDotfile/niri-dots-clean
```

using the GitHub `main` branch archive.

the archive is extracted into a temporary directory similar to:

```text
/tmp/alice-niri-dots.XXXXXXXX/
```

the installer then uses that directory as its `$DOTFILES` source.

once the installer exits, the temporary directory is deleted automatically.

no repository is permanently cloned by the one-line installer.

---

## requirements

the installer is intended for:

* Arch Linux
* Arch-based distributions using `pacman`
* a normal non-root user
* `sudo`
* an internet connection for package/repository downloads

for the GitHub one-line installer, `curl` and `tar` must also be available.

---

## fresh setup notes

fresh mode configures greetd as the login manager.

the generated greetd configuration launches:

```text
tuigreet
    ↓
niri-session
```

NetworkManager and Bluetooth services are also enabled when their service units are available.

after a successful fresh installation, rebooting is recommended.

---

## updating

for a normal local clone:

```bash
cd ~/niri-dots-clean
./install.sh --update
```

the repository must have a clean working tree.

check it manually with:

```bash
git status
```

the installer uses:

```bash
git pull --ff-only
```

so it will not automatically create a merge commit or overwrite local modifications.

for machines that do not have a permanent clone, use:

```bash
curl -fsSL https://raw.githubusercontent.com/AliceTheDotfile/niri-dots-clean/main/install.sh | bash -s -- --update
```

---

## troubleshooting

### installer says curl is missing

install `curl` first:

```bash
sudo pacman -S curl
```

then run the one-line installer again.

---

### installer says tar is missing

install `tar`:

```bash
sudo pacman -S tar
```

then run the one-line installer again.

---

### AUR packages were skipped

the installer looks for:

```text
yay
paru
```

if neither exists, it offers to install `yay`.

you can install an AUR helper yourself and rerun the installer.

---

### configuration was backed up

look in:

```text
~/.dotfiles-backup/
```

each installation gets its own timestamped directory.

---

### Waybar changed

it should not have.

the installer intentionally leaves:

```text
~/.config/waybar
```

untouched.

---

### Fastfetch configuration changed

it should not have.

the installer never copies:

```text
~/.config/fastfetch
```

---

## manually inspecting the installer

you can download the installer without executing it:

```bash
curl -fsSL \
    https://raw.githubusercontent.com/AliceTheDotfile/niri-dots-clean/main/install.sh \
    -o install.sh
```

then inspect it:

```bash
less install.sh
```

and run it yourself:

```bash
bash install.sh
```

---

## repository

GitHub:

https://github.com/AliceTheDotfile/niri-dots-clean

raw installer:

https://raw.githubusercontent.com/AliceTheDotfile/niri-dots-clean/main/install.sh

---

have fun rice-ing :3

```

