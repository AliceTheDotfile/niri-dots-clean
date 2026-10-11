#!/usr/bin/env bash
#
# niri-dots-clean installer
#
#   local:   ./install.sh
#   remote:  curl -fsSL https://raw.githubusercontent.com/AliceTheDotfile/niri-dots-clean/main/install.sh | bash
#
# Supports Arch-based systems and Void Linux. Run with --help for options.

set -Eeuo pipefail

# Running from a checkout: work from the repository root.
src="${BASH_SOURCE[0]:-}"
if [[ -n $src && -f $src ]]; then
    dir="$(cd -- "$(dirname -- "$src")" && pwd -P)"
    [[ -d $dir/niri ]] && cd -- "$dir"
fi

# When piped from curl, stdin is the script itself. Hand Python the terminal
# instead so prompts still work.
if [[ ! -t 0 ]] && (: </dev/tty) 2>/dev/null; then
    exec 4</dev/tty
else
    exec 4<&0
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 not found, installing it..." >&2
    if command -v sudo >/dev/null 2>&1; then priv=sudo
    elif command -v doas >/dev/null 2>&1; then priv=doas
    else echo "error: python3 is required (and neither sudo nor doas is available)" >&2; exit 1
    fi
    if command -v pacman >/dev/null 2>&1; then
        $priv pacman -S --needed python
    elif command -v xbps-install >/dev/null 2>&1; then
        $priv xbps-install -S python3
    else
        echo "error: python3 is required" >&2
        exit 1
    fi
fi

exec python3 /dev/fd/3 "$@" <&4 3<<'PYTHON'
"""niri-dots-clean installer (Python standard library only)."""

from __future__ import annotations

import argparse
import datetime as dt
import io
import json
import os
import pwd
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path
from urllib.request import Request, urlopen

NAME = "niri-dots-clean"
VERSION = "3.1.0"
ARCHIVE_URL = (
    "https://codeload.github.com/AliceTheDotfile/niri-dots-clean/"
    "tar.gz/refs/heads/main"
)
NERD_FONT_URL = (
    "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/"
    "AtkinsonHyperlegibleMono.tar.xz"
)

HOME = Path.home()
CONFIG = Path(os.environ.get("XDG_CONFIG_HOME") or HOME / ".config")
SHARE = Path(os.environ.get("XDG_DATA_HOME") or HOME / ".local/share")
BIN = HOME / ".local/bin"
FONT_DIR = SHARE / "fonts/AtkinsonHyperlegibleMonoNerd"

STAMP = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
BACKUP = HOME / ".dotfiles-backup" / STAMP
CACHE = HOME / ".cache" / NAME
LOG_PATH = CACHE / f"install-{STAMP}.log"

MANIFEST = ".alice-sync/update-manifest.json"
HOME_TOKEN = b"@HOME@"

# System locations (module-level so they are easy to see in one place).
GREETD_CFG = Path("/etc/greetd/config.toml")
SESSION_BIN = Path("/usr/local/bin/niri-session")
SV_DIR = Path("/etc/sv")            # Void: available runit services
SERVICE_DIR = Path("/var/service")  # Void: enabled runit services

# --------------------------------------------------------------------------
# Packages
#
# One token per package:  arch-name[:void-name]
#   - no ":"          same name on both
#   - "name:-"        not available on Void (reported as manual)
#   - "name:."        not needed on Void (silently skipped)
#   - "-:name"        Void only
# --------------------------------------------------------------------------

CORE = """
niri xwayland-satellite quickshell kitty swaync:SwayNotificationCenter wofi
kate qt6ct nwg-look kvantum layer-shell-qt papirus-icon-theme dconf awww mpv
ffmpeg pyside6:python3-pyside6 pipewire pipewire-pulse:. wireplumber playerctl
pavucontrol brightnessctl grim slurp wl-clipboard xdg-utils xdg-user-dirs
xdg-desktop-portal xdg-desktop-portal-gtk networkmanager:NetworkManager
network-manager-applet bluez bluez-utils:. blueman python:python3
python-pillow:python3-Pillow python-textual:python3-textual jq rsync git
ttf-hack:font-hack-ttf noto-fonts:noto-fonts-ttf noto-fonts-emoji
otf-atkinsonhyperlegiblemono-nerd:. woff2-font-awesome:font-awesome6 upower
-:dbus -:elogind -:mesa-dri -:mpvpaper
"""

EXTRA = """
firefox thunar:Thunar file-roller 7zip unzip zip imv neovim fzf ripgrep fd bat
eza tree less fastfetch man-db man-pages
"""

FRESH = "greetd greetd-tuigreet:tuigreet"

AUR = ["mpvpaper"]  # Arch only; Void packages it directly

CONFIG_DIRS = [
    "alice-rice", "btop", "cava", "environment.d", "fastfetch", "fontconfig", "gamearch",
    "gtk-3.0", "gtk-4.0", "Kvantum", "niri", "qt6ct", "swaync",
]

HOME_ITEMS = [
    ".bashrc", ".bash_profile", ".config/kdeglobals", ".config/kate",
    ".config/katerc", ".config/katevirc", ".config/katemetainfos",
    ".local/share/color-schemes/AliceNight.colors",
    ".local/share/themes/AliceNight", ".icons/Bibata-Material-Cloud",
]

REQUIRED = ["niri", "quickshell/my-shell", "wallfliper", "local/bin", "Wallpapers"]

VERIFY = ["niri", "niri-session", "quickshell", "kitty", "kate", "awww", "mpv", "ffmpeg"]

# Void: services that clash with NetworkManager.
NET_CLASH = ("dhcpcd", "wpa_supplicant", "dhcpcd-eth0")

# Void has no systemd and its niri package ships no niri-session script, so we
# install this launcher. It also loads ~/.config/environment.d, which systemd
# would normally do (GTK_THEME, QT_QPA_PLATFORMTHEME, ...).
SESSION_SCRIPT = r'''#!/bin/sh
# Starts niri as a session on systems without systemd.
# Installed by niri-dots-clean.

[ -r /etc/profile ] && . /etc/profile
export PATH="$HOME/.local/bin:$PATH"

for f in "$HOME"/.config/environment.d/*.conf; do
    [ -r "$f" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
        case $line in
            ''|'#'*|';'*) continue ;;
            [A-Za-z_]*=*) ;;
            *) continue ;;
        esac
        key=${line%%=*}
        val=${line#*=}
        case $val in
            \"*\") val=${val#\"}; val=${val%\"} ;;
            \'*\') val=${val#\'}; val=${val%\'} ;;
        esac
        case $val in
            *'$'*) val=$(printf '%s' "$val" | sed -e "s|\${HOME}|$HOME|g" -e "s|\$HOME|$HOME|g") ;;
        esac
        export "$key=$val"
    done < "$f"
done

if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && command -v dbus-run-session >/dev/null 2>&1; then
    exec dbus-run-session -- niri --session
fi
exec niri --session
'''


class Fail(RuntimeError):
    """Expected, user-facing failure."""


# --------------------------------------------------------------------------
# Output
# --------------------------------------------------------------------------

COLOR = sys.stdout.isatty() and "NO_COLOR" not in os.environ
_ANSI = re.compile(r"\x1b\[[0-9;]*m")
_log = None


def paint(code: str, text: str) -> str:
    return f"\033[{code}m{text}\033[0m" if COLOR else text


def out(text: str = "") -> None:
    global _log
    print(text, flush=True)
    try:
        if _log is None:
            CACHE.mkdir(parents=True, exist_ok=True)
            _log = LOG_PATH.open("a", encoding="utf-8")
        _log.write(_ANSI.sub("", text) + "\n")
        _log.flush()
    except OSError:
        pass


def head(text: str) -> None:
    out()
    out(paint("1", f"==> {text}"))


def ok(text: str) -> None:
    out(f"  {paint('32', 'ok')}    {text}")


def info(text: str) -> None:
    out(f"        {text}")


def warn(text: str) -> None:
    out(f"  {paint('33', 'warn')}  {text}")


# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

SYSPATH = os.pathsep.join(
    [os.environ.get("PATH", ""), "/usr/local/bin", "/usr/local/sbin", "/usr/sbin", "/sbin"]
)


def have(cmd: str) -> bool:
    return shutil.which(cmd, path=SYSPATH) is not None


def lexists(path: Path) -> bool:
    return os.path.lexists(path)


def query(argv: list[str]) -> str:
    """Run a read-only command and return stdout ('' on any failure)."""
    try:
        r = subprocess.run(argv, capture_output=True, text=True, check=False)
    except OSError:
        return ""
    return r.stdout


def user_exists(name: str) -> bool:
    try:
        pwd.getpwnam(name)
    except KeyError:
        return False
    return True


def sub_home(path: Path) -> None:
    """Replace the @HOME@ token in a small text file."""
    try:
        if path.is_symlink() or path.stat().st_size > 4_000_000:
            return
        data = path.read_bytes()
    except OSError:
        return
    if HOME_TOKEN in data:
        path.write_bytes(data.replace(HOME_TOKEN, str(HOME).encode()))


def copy_file(src, dst, *, follow_symlinks=True):
    shutil.copy2(src, dst, follow_symlinks=False)
    sub_home(Path(dst))
    return dst


def detect_distro() -> tuple[str, str]:
    """Return (family, pretty name). Family is 'arch', 'void' or ''."""
    info_map: dict[str, str] = {}
    try:
        for line in Path("/etc/os-release").read_text().splitlines():
            key, _, val = line.partition("=")
            info_map[key] = val.strip().strip('"')
    except OSError:
        pass
    ids = {info_map.get("ID", "")} | set(info_map.get("ID_LIKE", "").split())
    pretty = info_map.get("PRETTY_NAME", "Linux")
    if "void" in ids and have("xbps-install"):
        return "void", pretty
    if ids & {"arch", "archlinux"} and have("pacman"):
        return "arch", pretty
    if have("xbps-install"):
        return "void", pretty
    if have("pacman"):
        return "arch", pretty
    return "", pretty


def parse_specs(text: str) -> list[tuple[str, str]]:
    specs = []
    for token in text.split():
        arch, sep, void = token.partition(":")
        specs.append((arch, void if sep else arch))
    return specs


def priv_cmd() -> list[str]:
    for tool in ("sudo", "doas"):
        if have(tool):
            return [tool]
    return []


# --------------------------------------------------------------------------
# Installer
# --------------------------------------------------------------------------


class Installer:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.dry = args.dry_run
        self.family, self.distro_name = detect_distro()
        self.priv = priv_cmd()
        self.repo: Path | None = None
        self.tmp: Path | None = None
        self.sudo_ready = False
        self.backed_up = False
        self.unavailable: list[str] = []
        self.fresh = args.mode == "fresh"
        self.minimal = args.mode == "minimal" or args.minimal

    # ---- plumbing --------------------------------------------------------

    def run(self, argv: list[str], *, sudo: bool = False, cwd: Path | None = None) -> None:
        """Run a command that changes the system (honours --dry-run)."""
        if sudo:
            if not self.priv and not self.dry:
                hint = ""
                if self.family == "void":
                    hint = " (as root: xbps-install -S sudo, then add your user to the wheel group)"
                raise Fail("sudo or doas is required" + hint)
            argv = [*(self.priv or ["sudo"]), *argv]
        rendered = " ".join(shlex.quote(a) for a in argv)
        if self.dry:
            info(f"[dry-run] {rendered}")
            return
        if sudo and self.priv == ["sudo"] and not self.sudo_ready:
            if subprocess.run(["sudo", "-v"]).returncode != 0:
                raise Fail("sudo authentication failed")
            self.sudo_ready = True
        if _log:
            _log.write(f"$ {rendered}\n")
        if subprocess.run(argv, cwd=cwd).returncode != 0:
            raise Fail(f"command failed: {rendered}")

    def ask(self, prompt: str, default: bool = True, auto: bool = True) -> bool:
        """Yes/no question. `auto=False` ignores --yes (used for anything destructive)."""
        if self.args.assume_yes and auto:
            return True
        if not sys.stdin.isatty():
            return default
        try:
            answer = input(f"{prompt} [{'Y/n' if default else 'y/N'}] ").strip().lower()
        except EOFError:
            return default
        return default if not answer else answer in ("y", "yes")

    # ---- repository ------------------------------------------------------

    @staticmethod
    def is_repo(path: Path) -> bool:
        return all((path / rel).exists() for rel in REQUIRED)

    def get_repo(self) -> None:
        cwd = Path.cwd().resolve()
        if self.is_repo(cwd):
            self.repo = cwd
            return

        head("Downloading latest dotfiles")
        self.tmp = Path(tempfile.mkdtemp(prefix=f"{NAME}-"))
        archive = self.tmp / "repo.tar.gz"
        req = Request(ARCHIVE_URL, headers={"User-Agent": f"{NAME}-installer/{VERSION}"})
        try:
            with urlopen(req, timeout=60) as resp, archive.open("wb") as fp:
                shutil.copyfileobj(resp, fp, 1 << 20)
            dest = self.tmp / "src"
            dest.mkdir()
            with tarfile.open(archive, "r:gz") as tar:
                if hasattr(tarfile, "data_filter"):
                    tar.extractall(dest, filter="data")
                else:
                    root = dest.resolve()
                    for m in tar.getmembers():
                        if not (root / m.name).resolve().is_relative_to(root):
                            raise Fail(f"unsafe path in archive: {m.name}")
                    tar.extractall(dest)
        except (OSError, tarfile.TarError) as exc:
            raise Fail(f"could not download the repository: {exc}") from exc
        archive.unlink(missing_ok=True)

        roots = [p for p in dest.iterdir() if p.is_dir()]
        self.repo = roots[0] if len(roots) == 1 else dest
        ok("downloaded")

    def check_repo(self) -> None:
        assert self.repo
        missing = [rel for rel in REQUIRED if not (self.repo / rel).exists()]
        if missing:
            raise Fail("repository is missing: " + ", ".join(missing))

    def git_pull(self) -> None:
        assert self.repo
        if not (self.repo / ".git").is_dir():
            return
        if not have("git"):
            raise Fail("git is required to update a local checkout")
        head("Updating repository")
        if query(["git", "-C", str(self.repo), "status", "--porcelain"]).strip():
            raise Fail("the repository has uncommitted changes; commit or stash them first")
        self.run(["git", "-C", str(self.repo), "-c", "core.hooksPath=/dev/null",
                  "pull", "--ff-only"])
        ok("up to date")

    # ---- packages --------------------------------------------------------

    def wanted(self) -> list[tuple[str, str]]:
        specs = parse_specs(CORE)
        if not self.minimal:
            specs += parse_specs(EXTRA)
        if self.fresh:
            specs += parse_specs(FRESH)
        return specs

    # Arch

    def plan_arch(self) -> tuple[list[str], list[str]]:
        names = list(dict.fromkeys(a for a, _ in self.wanted() if a != "-"))
        known = set(query(["pacman", "-Slq"]).split())
        if known:  # databases synced: drop names that do not exist
            found = [n for n in names if n in known]
            missing = [n for n in names if n not in known]
        else:
            found, missing = names, []
        # `pacman -T` prints only the names that are NOT installed.
        todo = query(["pacman", "-T", *found]).split()
        return todo, missing

    def aur_helper(self) -> str | None:
        return next((h for h in ("yay", "paru") if have(h)), None)

    def install_aur(self) -> None:
        todo = query(["pacman", "-T", *AUR]).split()
        if not todo or self.args.no_aur:
            if todo:
                self.unavailable += todo
            return
        helper = self.aur_helper()
        if helper is None:
            if not self.ask("No AUR helper found. Build yay from the AUR?"):
                self.unavailable += todo
                return
            self.run(["pacman", "-S", "--needed", "base-devel", "git"], sudo=True)
            tmp = Path(tempfile.mkdtemp(prefix="yay-"))
            try:
                self.run(["git", "clone", "--depth", "1",
                          "https://aur.archlinux.org/yay.git", str(tmp / "yay")])
                self.run(["makepkg", "-si"], cwd=tmp / "yay")
            finally:
                shutil.rmtree(tmp, ignore_errors=True)
            helper = "yay"
        self.run([helper, "-S", "--needed", *todo])
        ok(f"AUR: {', '.join(todo)}")

    # Void

    @staticmethod
    def void_name(pkgver: str) -> str:
        return pkgver.rsplit("-", 1)[0]

    def void_known(self, names: list[str]) -> dict[str, bool]:
        """name -> installed, for the names present in the repository index."""
        esc = [re.sub(r"([.+])", r"\\\1", n) for n in names]
        found: dict[str, bool] = {}
        for line in query(["xbps-query", "-R", "--regex", "-s", "^(" + "|".join(esc) + ")$"]
                          ).splitlines():
            parts = line.split()
            if len(parts) >= 2 and parts[0] in ("[*]", "[-]"):
                found[self.void_name(parts[1])] = parts[0] == "[*]"
        return found

    def plan_void(self) -> tuple[list[str], list[str]]:
        names: list[str] = []
        missing: list[str] = []
        for arch, void in self.wanted():
            if void == ".":
                continue
            if void == "-":
                missing.append(arch)
            else:
                names.append(void)
        names = list(dict.fromkeys(names))

        installed = set()
        for line in query(["xbps-query", "-l"]).splitlines():
            parts = line.split()
            if len(parts) >= 2:
                installed.add(self.void_name(parts[1]))
        todo = [n for n in names if n not in installed]

        if todo:
            known = self.void_known(todo)
            if not known and not self.dry:  # index never synced
                self.run(["xbps-install", "-S", *(["-y"] if self.args.assume_yes else [])],
                         sudo=True)
                known = self.void_known(todo)
            if known:
                missing += [n for n in todo if n not in known]
                todo = [n for n in todo if n in known]
        return todo, missing

    def install_void(self) -> None:
        yes = ["-y"] if self.args.assume_yes else []
        todo, missing = self.plan_void()
        if todo:
            info(f"installing {len(todo)} package(s)")
            try:
                self.run(["xbps-install", "-Su", *yes], sudo=True)
            except Fail:  # xbps itself must be updated first
                self.run(["xbps-install", "-u", *yes, "xbps"], sudo=True)
                self.run(["xbps-install", "-Su", *yes], sudo=True)
            try:
                self.run(["xbps-install", *yes, *todo], sudo=True)
            except Fail:
                warn("bulk install failed; retrying packages one by one")
                failed = []
                for pkg in todo:
                    try:
                        self.run(["xbps-install", *yes, pkg], sudo=True)
                    except Fail:
                        failed.append(pkg)
                missing += failed
                todo = [p for p in todo if p not in failed]
        ok(f"{len(todo)} installed, rest already present" if todo else "all present")
        self.unavailable += missing
        self.install_nerd_font()
        self.ensure_niri_session()

    def install_nerd_font(self) -> None:
        """Void has no package for Atkinson Hyperlegible Mono Nerd Font; fetch just that one."""
        label = "Atkinson Hyperlegible Mono Nerd Font"
        if FONT_DIR.is_dir() and any(FONT_DIR.glob("*.[ot]tf")):
            return
        if re.search(r"atkinson.*mono.*nerd", query(["fc-list"]), re.I):
            return
        if self.dry:
            info(f"[dry-run] download {label}")
            return
        try:
            req = Request(NERD_FONT_URL, headers={"User-Agent": f"{NAME}-installer/{VERSION}"})
            with urlopen(req, timeout=120) as resp:
                data = resp.read()
            FONT_DIR.mkdir(parents=True, exist_ok=True)
            count = 0
            with tarfile.open(fileobj=io.BytesIO(data), mode="r:xz") as tar:
                for member in tar.getmembers():
                    base = Path(member.name).name
                    if member.isfile() and base.lower().endswith((".ttf", ".otf")):
                        (FONT_DIR / base).write_bytes(tar.extractfile(member).read())
                        count += 1
            if not count:
                raise Fail("archive contained no font files")
            if have("fc-cache"):
                query(["fc-cache", "-f", str(FONT_DIR)])
            ok(label)
        except (OSError, tarfile.TarError, Fail) as exc:
            warn(f"could not install {label}: {exc}")
            self.unavailable.append(label)

    def ensure_niri_session(self) -> None:
        """Void's niri package has no niri-session; install a launcher for it."""
        if self.family != "void" or have("niri-session") or SESSION_BIN.exists():
            return
        fd, tmp = tempfile.mkstemp(suffix=".sh")
        os.close(fd)
        try:
            Path(tmp).write_text(SESSION_SCRIPT)
            self.run(["install", "-Dm755", tmp, str(SESSION_BIN)], sudo=True)
        finally:
            Path(tmp).unlink(missing_ok=True)
        ok("niri-session launcher")

    def install_packages(self) -> None:
        if self.args.no_deps:
            return
        if not self.family:
            raise Fail("unsupported system: this installer supports Arch-based distros "
                       "and Void Linux")
        head(f"Packages ({self.family})")
        if self.family == "void":
            self.install_void()
            return
        yes = ["--noconfirm"] if self.args.assume_yes else []
        todo, missing = self.plan_arch()
        if todo:
            info(f"installing {len(todo)} package(s)")
            self.run(["pacman", "-Syu", "--needed", *yes, *todo], sudo=True)
        ok(f"{len(todo)} installed, rest already present" if todo else "all present")
        self.unavailable += missing
        self.install_aur()

    # ---- files -----------------------------------------------------------

    def backup(self, dest: Path) -> None:
        if not lexists(dest):
            return
        try:
            rel = dest.relative_to(HOME)
        except ValueError:
            rel = Path("outside-home") / str(dest).lstrip("/")
        if self.dry:
            info(f"[dry-run] back up {dest}")
            return
        target = BACKUP / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(dest), str(target))
        self.backed_up = True

    def place(self, src: Path, dest: Path) -> bool:
        if not lexists(src):
            warn("not in repository: " + (str(src.relative_to(self.repo)) if self.repo else src.name))
            return False
        self.backup(dest)
        if self.dry:
            info(f"[dry-run] install {dest}")
            return True
        dest.parent.mkdir(parents=True, exist_ok=True)
        if src.is_dir() and not src.is_symlink():
            shutil.copytree(src, dest, symlinks=True, copy_function=copy_file)
        else:
            copy_file(src, dest)
        return True

    @staticmethod
    def make_executable(path: Path) -> None:
        try:
            path.chmod(path.stat().st_mode | 0o111)
        except OSError:
            pass

    def install_configs(self) -> None:
        assert self.repo
        n = sum(self.place(self.repo / d, CONFIG / d) for d in CONFIG_DIRS)
        n += self.place(self.repo / "quickshell/my-shell", CONFIG / "quickshell/my-shell")
        ok(f"{n} config directories")

    def install_home(self) -> None:
        assert self.repo
        n = sum(self.place(self.repo / "home" / i, HOME / i) for i in HOME_ITEMS)
        ok(f"{n} shell and theme files")

    def install_wallfliper(self) -> None:
        assert self.repo
        self.place(self.repo / "wallfliper", SHARE / "wallfliper")
        self.place(self.repo / "wallfliper/config.json", CONFIG / "wallfliper/config.json")
        launcher = BIN / "wallfliper"
        if not (self.repo / "local/bin/wallfliper").exists() and not self.dry:
            self.backup(launcher)
            BIN.mkdir(parents=True, exist_ok=True)
            launcher.write_text(
                f'#!/usr/bin/env bash\nexec python3 "{SHARE / "wallfliper/main.py"}" "$@"\n'
            )
            self.make_executable(launcher)
        ok("wallfliper")

    def install_scripts(self) -> None:
        assert self.repo
        n = 0
        for src in sorted((self.repo / "local/bin").iterdir()):
            if src.is_file():
                dest = BIN / src.name
                n += self.place(src, dest)
                if not self.dry:
                    self.make_executable(dest)
        ok(f"{n} scripts in ~/.local/bin")

    def install_wallpapers(self) -> None:
        assert self.repo
        dest_dir = HOME / "Wallpapers"
        added = 0
        if not self.dry:
            dest_dir.mkdir(parents=True, exist_ok=True)
        for src in sorted((self.repo / "Wallpapers").iterdir()):
            if src.is_file() and not lexists(dest_dir / src.name):
                if not self.dry:
                    shutil.copy2(src, dest_dir / src.name)
                added += 1
        ok(f"{added} wallpaper(s)")

    def setup_path(self) -> None:
        if str(BIN) in os.environ.get("PATH", "").split(os.pathsep):
            return
        os.environ["PATH"] = f"{BIN}{os.pathsep}{os.environ.get('PATH', '')}"
        files = [HOME / n for n in (".bashrc", ".zshrc", ".profile", ".bash_profile")]
        targets = [f for f in files if f.is_file()] or [HOME / ".profile"]
        line = f'\n# {NAME}\nexport PATH="$HOME/.local/bin:$PATH"\n'
        for f in targets:
            try:
                if f.exists() and ".local/bin" in f.read_text(errors="ignore"):
                    continue
            except OSError:
                continue
            if self.dry:
                info(f"[dry-run] add ~/.local/bin to {f}")
            else:
                with f.open("a", encoding="utf-8") as fp:
                    fp.write(line)
        ok("~/.local/bin added to PATH")

    @staticmethod
    def dconf_cmd(argv: list[str]) -> list[str] | None:
        """dconf needs a session bus; start a temporary one when there is none (TTY installs)."""
        if os.environ.get("DBUS_SESSION_BUS_ADDRESS"):
            return argv
        if have("dbus-run-session"):
            return ["dbus-run-session", "--", *argv]
        return None

    def apply_dconf(self) -> None:
        assert self.repo
        src = self.repo / "dconf/interface.ini"
        load = self.dconf_cmd(["dconf", "load", "/org/gnome/desktop/interface/"])
        dump = self.dconf_cmd(["dconf", "dump", "/org/gnome/desktop/interface/"])
        if not src.is_file() or not have("dconf") or not load or not dump:
            return
        if self.dry:
            info("[dry-run] load GTK interface settings")
            return
        BACKUP.mkdir(parents=True, exist_ok=True)
        (BACKUP / "interface.dconf").write_text(query(dump))
        self.backed_up = True
        with src.open() as fp:
            r = subprocess.run(load, stdin=fp)
        if r.returncode == 0:
            ok("GTK settings")
        else:
            warn("dconf load failed")

    def apply_rice(self) -> None:
        head("Configuration")
        self.install_configs()
        self.install_home()
        self.install_wallfliper()
        self.install_scripts()
        self.install_wallpapers()
        self.setup_path()
        self.apply_dconf()

    # ---- manifest updates ------------------------------------------------

    def load_manifest(self) -> tuple[set[str], set[str]]:
        assert self.repo
        path = self.repo / MANIFEST
        if not path.is_file():
            warn(f"{MANIFEST} not found; nothing will be overwritten")
            return set(), set()
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise Fail(f"cannot read {MANIFEST}: {exc}") from exc
        if not isinstance(data, dict) or data.get("version") != 1:
            raise Fail(f"unsupported {MANIFEST}")

        def norm(key: str) -> set[str]:
            values = data.get(key, [])
            if not isinstance(values, list):
                raise Fail(f"invalid '{key}' list in {MANIFEST}")
            result = set()
            for v in values:
                p = Path(v.strip()) if isinstance(v, str) else None
                if (p is None or not str(p).strip() or p.is_absolute() or ".." in p.parts
                        or "\\" in v or p.as_posix() == "."):
                    raise Fail(f"invalid path in {MANIFEST}: {v!r}")
                result.add(p.as_posix())
            return result

        managed, deleted = norm("managed"), norm("deleted")
        return managed | deleted, deleted

    @staticmethod
    def live_path(rel: str) -> Path | None:
        if rel == "dconf/interface.ini":
            return None
        if rel == "wallfliper/config.json":
            return CONFIG / rel
        if rel.startswith("wallfliper/"):
            return SHARE / rel
        if rel.startswith("local/bin/"):
            return BIN / rel[len("local/bin/"):]
        if rel.startswith("Wallpapers/"):
            return HOME / rel
        if rel.startswith("home/"):
            return HOME / rel[len("home/"):]
        if rel.startswith("quickshell/my-shell/"):
            return CONFIG / rel
        if any(rel == d or rel.startswith(d + "/") for d in CONFIG_DIRS):
            return CONFIG / rel
        return None

    @staticmethod
    def same_content(src: Path, dest: Path) -> bool:
        if not (lexists(src) and lexists(dest)) or src.is_dir() or dest.is_dir():
            return False
        if src.is_symlink() or dest.is_symlink():
            return src.is_symlink() and dest.is_symlink() and os.readlink(src) == os.readlink(dest)
        try:
            return src.read_bytes().replace(HOME_TOKEN, str(HOME).encode()) == dest.read_bytes()
        except OSError:
            return False

    def apply_manifest(self, managed: set[str], deleted: set[str]) -> None:
        assert self.repo
        head("Applying update")
        changed = same = skipped = 0
        dconf = False
        for rel in sorted(managed):
            src, dest = self.repo / rel, self.live_path(rel)
            if rel == "dconf/interface.ini":
                dconf = dconf or (rel not in deleted and src.is_file())
                continue
            if dest is None:
                warn(f"no install location for {rel}")
                skipped += 1
            elif rel in deleted:
                if lexists(dest):
                    self.backup(dest)
                    info(f"removed {rel}")
                    changed += 1
            elif not lexists(src) or src.is_dir():
                warn(f"not a file in repository: {rel}")
                skipped += 1
            elif self.same_content(src, dest):
                same += 1
            else:
                self.place(src, dest)
                info(f"updated {rel}")
                changed += 1
        if dconf:
            self.apply_dconf()
            changed += 1
        ok(f"{changed} changed, {same} unchanged, {skipped} skipped")

    # ---- services / login manager ---------------------------------------

    def write_greetd(self, vt: int) -> bool:
        """Write /etc/greetd/config.toml. Returns False when it cannot be set up."""
        session = shutil.which("niri-session", path=SYSPATH) or (
            str(SESSION_BIN) if SESSION_BIN.exists() else None)
        if not (have("greetd") and session):
            warn("greetd or niri-session is missing; login manager not configured")
            return False
        if have("tuigreet"):
            greeter = f"tuigreet --time --remember --remember-session --asterisks --cmd {session}"
        elif have("agreety"):
            greeter = f"agreety --cmd {session}"
            warn("tuigreet unavailable; using the plain agreety greeter")
        else:
            warn("no greeter found; login manager not configured")
            return False
        user = next((u for u in ("_greeter", "greeter", "_greetd", "greetd")
                     if user_exists(u)), "greeter")

        if GREETD_CFG.exists() and not self.dry:
            target = BACKUP / "etc/greetd/config.toml"
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(GREETD_CFG, target)
            self.backed_up = True
        text = (
            f"[terminal]\nvt = {vt}\n\n[default_session]\n"
            f'command = "{greeter}"\n'
            f'user = "{user}"\n'
        )
        fd, tmp = tempfile.mkstemp(suffix=".toml")
        os.close(fd)
        try:
            Path(tmp).write_text(text)
            self.run(["install", "-Dm644", tmp, str(GREETD_CFG)], sudo=True)
            if greeter.startswith("tuigreet"):
                self.run(["install", "-d", "-o", user, "-g", user, "-m755",
                          "/var/cache/tuigreet"], sudo=True)
        finally:
            Path(tmp).unlink(missing_ok=True)
        ok(f"greetd ({greeter.split()[0]}), session: niri")
        return True

    def setup_services_systemd(self) -> None:
        if not have("systemctl"):
            warn("systemd not found; enable NetworkManager and Bluetooth yourself")
            return
        for unit in ("NetworkManager.service", "bluetooth.service"):
            if query(["systemctl", "list-unit-files", unit]).count(unit):
                self.run(["systemctl", "enable", unit], sudo=True)
                ok(f"enabled {unit}")
        if self.write_greetd(vt=1):
            self.run(["systemctl", "enable", "--force", "greetd.service"], sudo=True)

    def sv_enabled(self, name: str) -> bool:
        return lexists(SERVICE_DIR / name)

    def enable_sv(self, name: str) -> bool:
        """Enable a runit service by linking it into the service directory."""
        if self.sv_enabled(name):
            return True
        if not self.dry and not (SV_DIR / name).is_dir():
            warn(f"service {name} is not installed")
            return False
        self.run(["ln", "-s", str(SV_DIR / name), str(SERVICE_DIR / name)], sudo=True)
        ok(f"enabled {name}")
        return True

    def setup_network_void(self) -> None:
        if self.sv_enabled("NetworkManager"):
            return
        clash = [s for s in NET_CLASH if self.sv_enabled(s)]
        if clash and not self.ask(
                f"NetworkManager replaces {', '.join(clash)} (your connection restarts). "
                "Switch now?", default=False, auto=False):
            info("networking left as it is")
            return
        for name in clash:
            self.run(["rm", "-f", str(SERVICE_DIR / name)], sudo=True)
        self.enable_sv("NetworkManager")

    def setup_services_void(self) -> None:
        if not SERVICE_DIR.is_dir():
            warn(f"{SERVICE_DIR} not found; enable dbus, elogind and greetd yourself")
            return
        self.ensure_niri_session()
        for name in ("dbus", "elogind", "bluetoothd"):
            self.enable_sv(name)
        self.setup_network_void()
        # vt 7: the default agetty services use tty1-6, so greetd never fights a login prompt.
        if self.write_greetd(vt=7):
            self.enable_sv("greetd")

    def setup_services(self) -> None:
        head("Services")
        if self.family == "void":
            self.setup_services_void()
        else:
            self.setup_services_systemd()

    # ---- verification ----------------------------------------------------

    def verify(self) -> None:
        head("Checking")
        gone = [c for c in VERIFY if not have(c)]
        if gone:
            warn("missing commands: " + ", ".join(gone))
        else:
            ok("core commands present")
        if self.family == "void" and SERVICE_DIR.is_dir() and not self.dry:
            off = [s for s in ("dbus", "elogind") if not self.sv_enabled(s)]
            if off:
                warn("services not enabled: " + ", ".join(off)
                     + " (niri needs them; use Fresh system, or: sudo ln -s /etc/sv/NAME "
                     "/var/service/)")
        wf = SHARE / "wallfliper/main.py"
        if wf.is_file() and have("python3") and not self.dry:
            r = subprocess.run(["python3", str(wf), "--check"], capture_output=True, text=True)
            if r.returncode == 0:
                ok("wallfliper dependencies")
            else:
                warn("wallfliper reports missing dependencies")

    def finish(self) -> None:
        head("Done")
        alias = {"greetd-tuigreet": "tuigreet"}
        left = [u for u in dict.fromkeys(self.unavailable) if not have(alias.get(u, u))]
        if left:
            warn("not installed (install manually): " + ", ".join(left))
        if self.backed_up:
            info(f"backup: {BACKUP}")
        info("restart niri to apply")

    # ---- modes -----------------------------------------------------------

    def full(self) -> None:
        self.check_repo()
        self.install_packages()
        self.apply_rice()
        self.verify()

    def update(self) -> None:
        self.git_pull()
        self.check_repo()
        managed, deleted = self.load_manifest()
        head("Update")
        info(f"{len(managed)} shared file(s)")
        if not managed:
            return
        if not self.dry and not self.ask("Apply update?"):
            info("cancelled")
            return
        self.apply_manifest(managed, deleted)
        self.verify()

    def fresh_system(self) -> None:
        self.check_repo()
        head("Fresh system")
        if not self.dry and not self.ask("Continue?"):
            info("cancelled")
            return
        self.install_packages()
        self.apply_rice()
        if not self.args.no_deps:
            try:
                self.setup_services()
            except (Fail, OSError) as exc:
                warn(f"login manager setup failed: {exc}")
        self.verify()
        if (not self.dry and not self.args.skip_reboot
                and self.ask("Reboot now?", default=False, auto=False)):
            self.run(["systemctl", "reboot"] if have("systemctl") else ["reboot"], sudo=True)

    def execute(self) -> int:
        if os.geteuid() == 0:
            raise Fail("do not run as root; sudo or doas is used when needed")
        mode = self.args.mode
        if mode == "menu":
            mode = self.menu()
            if mode is None:
                return 0
            self.args.mode = mode
            self.fresh = mode == "fresh"
            self.minimal = mode == "minimal" or self.args.minimal

        out(paint("1", f"{NAME} {VERSION}") + f"  ({self.distro_name})")
        if mode != "packages":
            self.get_repo()

        if mode == "update":
            self.update()
        elif mode == "fresh":
            self.fresh_system()
        elif mode == "configs":
            self.check_repo()
            self.apply_rice()
            self.verify()
        elif mode == "packages":
            self.install_packages()
        else:
            self.full()
        self.finish()
        return 0

    def menu(self) -> str | None:
        options = [
            ("Install", "full",
             "Packages, configs and wallpapers. Existing files are backed up first."),
            ("Update", "update",
             "Applies only the files the repo marks as shared. Your own changes stay."),
            ("Fresh system", "fresh",
             "Everything in Install, plus the login manager and system services."),
            ("Minimal", "minimal",
             "Core packages only (no extra apps), plus configs."),
            ("Configs only", "configs",
             "Copies configs without installing any packages."),
            ("Packages only", "packages",
             "Installs packages without touching your configs."),
        ]
        if not sys.stdin.isatty():
            return "full"
        out(paint("1", f"{NAME} {VERSION}") + f"  ({self.distro_name})")
        out()
        for i, (label, _, desc) in enumerate(options, 1):
            out(f"  {i}) {label}")
            out(paint("2", f"     {desc}"))
        out("  q) Quit")
        out()
        while True:
            try:
                choice = input("Select [1]: ").strip().lower()
            except EOFError:
                return None
            if choice in ("", "1"):
                return options[0][1]
            if choice in ("q", "quit", "exit", "0"):
                return None
            if choice.isdigit() and 1 <= int(choice) <= len(options):
                return options[int(choice) - 1][1]
            out(f"Enter a number from 1 to {len(options)}, or q.")

    def cleanup(self) -> None:
        if self.tmp:
            shutil.rmtree(self.tmp, ignore_errors=True)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(prog="install.sh", description=f"{NAME} installer")
    p.add_argument("--fresh", action="store_true",
                   help="fresh system setup (adds login manager and services)")
    p.add_argument("--minimal", action="store_true", help="core packages only")
    p.add_argument("--update", dest="mode", action="store_const", const="update",
                   help="apply shared updates from the repository")
    p.add_argument("--configs-only", dest="mode", action="store_const", const="configs",
                   help="install configs, skip packages")
    p.add_argument("--packages-only", dest="mode", action="store_const", const="packages",
                   help="install packages, skip configs")
    p.add_argument("--no-deps", action="store_true", help="skip package installation")
    p.add_argument("--no-aur", action="store_true", help="skip AUR packages (Arch)")
    p.add_argument("--dry-run", action="store_true", help="show what would change")
    p.add_argument("-y", "--yes", dest="assume_yes", action="store_true",
                   help="answer yes to every prompt")
    p.add_argument("--skip-reboot", action="store_true", help="never offer to reboot")
    p.add_argument("--no-color", action="store_true", help="disable colors")
    p.add_argument("--version", action="version", version=f"{NAME} {VERSION}")
    args = p.parse_args()

    global COLOR
    if args.no_color:
        COLOR = False
    if args.fresh:
        args.mode = "fresh"
    elif args.mode is None:
        args.mode = "minimal" if args.minimal else "menu"
    return args


def main() -> int:
    args = parse_args()
    installer = Installer(args)

    def stop(_sig, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)

    try:
        return installer.execute()
    except KeyboardInterrupt:
        out()
        out("cancelled")
        return 130
    except Fail as exc:
        out(f"{paint('31', 'error')}: {exc}")
        out(f"log: {LOG_PATH}")
        return 1
    finally:
        installer.cleanup()


if __name__ == "__main__":
    raise SystemExit(main())
PYTHON
