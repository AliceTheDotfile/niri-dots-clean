#!/usr/bin/env bash
#
# niri-dots-clean installer
#
#   local:   ./install.sh
#   remote:  curl -fsSL https://raw.githubusercontent.com/AliceTheDotfile/niri-dots-clean/main/install.sh | bash
#
# Supports Arch-based and Debian-based systems. Run with --help for options.

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
    if command -v pacman >/dev/null 2>&1; then
        sudo pacman -S --needed python
    elif command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update && sudo apt-get install -y python3
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
import json
import os
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
VERSION = "3.0.0"
ARCHIVE_URL = (
    "https://codeload.github.com/AliceTheDotfile/niri-dots-clean/"
    "tar.gz/refs/heads/main"
)

HOME = Path.home()
CONFIG = Path(os.environ.get("XDG_CONFIG_HOME") or HOME / ".config")
SHARE = Path(os.environ.get("XDG_DATA_HOME") or HOME / ".local/share")
BIN = HOME / ".local/bin"

STAMP = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
BACKUP = HOME / ".dotfiles-backup" / STAMP
CACHE = HOME / ".cache" / NAME
LOG_PATH = CACHE / f"install-{STAMP}.log"

MANIFEST = ".alice-sync/update-manifest.json"
HOME_TOKEN = b"@HOME@"

# --------------------------------------------------------------------------
# Packages
#
# One token per package:  arch-name[:debian-name]
#   - no ":"          same name on both
#   - ":-"            not packaged on Debian (reported as manual)
#   - ":."            not needed on Debian (silently skipped)
#   - "-:name"        Debian only
#   - "a|b"           first available alternative
#   - "a,b"           install every one of these
# --------------------------------------------------------------------------

PYSIDE = ",".join(
    "python3-pyside6." + m for m in ("qtcore", "qtgui", "qtwidgets", "qtqml", "qtquick")
)

CORE = f"""
niri xwayland-satellite quickshell kitty swaync:sway-notification-center wofi
kate qt6ct nwg-look kvantum:qt6-style-kvantum layer-shell-qt papirus-icon-theme
dconf:dconf-cli awww mpv ffmpeg pyside6:{PYSIDE}
pipewire pipewire-pulse wireplumber playerctl pavucontrol brightnessctl
grim slurp wl-clipboard xdg-utils xdg-user-dirs xdg-desktop-portal
xdg-desktop-portal-gtk networkmanager:network-manager
network-manager-applet:network-manager-gnome bluez bluez-utils:. blueman
python:python3 jq rsync git ttf-hack:fonts-hack noto-fonts:fonts-noto-core
noto-fonts-emoji:fonts-noto-color-emoji otf-atkinsonhyperlegiblemono-nerd:-
woff2-font-awesome:fonts-font-awesome upower
-:dbus-user-session -:xwayland
-:qml6-module-qtquick,qml6-module-qtquick-controls,qml6-module-qtquick-layouts,qml6-module-qtquick-templates,qml6-module-qtquick-window,qml6-module-qtqml-workerscript
"""

EXTRA = """
firefox:firefox-esr|firefox thunar file-roller 7zip:7zip|p7zip-full unzip zip
imv neovim fzf ripgrep fd:fd-find bat eza tree less fastfetch man-db
man-pages:manpages
"""

FRESH = "greetd greetd-tuigreet:tuigreet"

AUR = ["mpvpaper"]  # Arch only

# Debian: tools that are not packaged are built from source (see build_*).
BUILD_BASE = ["build-essential", "git", "pkg-config", "curl", "ca-certificates"]
NIRI_DEPS = [
    "clang", "libudev-dev", "libgbm-dev", "libxkbcommon-dev", "libegl1-mesa-dev",
    "libwayland-dev", "libinput-dev", "libdbus-1-dev", "libsystemd-dev",
    "libseat-dev", "libpipewire-0.3-dev", "libpango1.0-dev", "libdisplay-info-dev",
]
XWAYLAND_DEPS = ["clang", "libxcb1-dev", "libxcb-cursor-dev"]
QUICKSHELL_DEPS = [
    "cmake", "ninja-build", "qt6-base-dev", "qt6-base-private-dev",
    "qt6-declarative-dev", "qt6-declarative-private-dev", "qt6-shadertools-dev",
    "qt6-wayland-dev", "qt6-wayland-private-dev", "qt6-svg-dev", "libcli11-dev",
    "spirv-tools", "libvulkan-dev", "libdrm-dev", "libgbm-dev", "libjemalloc-dev",
    "libpipewire-0.3-dev", "libpam0g-dev", "libxcb1-dev", "libwayland-dev",
    "wayland-protocols",
]
AWWW_DEPS = ["liblz4-dev", "libwayland-dev", "wayland-protocols", "libxkbcommon-dev", "scdoc"]

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

VERIFY = ["niri", "quickshell", "kitty", "kate", "awww", "mpv", "ffmpeg"]


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


def query(argv: list[str], env: dict | None = None) -> str:
    """Run a read-only command and return stdout ('' on any failure)."""
    try:
        r = subprocess.run(argv, capture_output=True, text=True, check=False, env=env)
    except OSError:
        return ""
    return r.stdout


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
    """Return (family, pretty name). Family is 'arch', 'debian' or ''."""
    info_map: dict[str, str] = {}
    try:
        for line in Path("/etc/os-release").read_text().splitlines():
            key, _, val = line.partition("=")
            info_map[key] = val.strip().strip('"')
    except OSError:
        pass
    ids = {info_map.get("ID", "")} | set(info_map.get("ID_LIKE", "").split())
    pretty = info_map.get("PRETTY_NAME", "Linux")
    if ids & {"arch", "archlinux"} and have("pacman"):
        return "arch", pretty
    if ids & {"debian", "ubuntu"} and have("apt-get"):
        return "debian", pretty
    if have("pacman"):
        return "arch", pretty
    if have("apt-get"):
        return "debian", pretty
    return "", pretty


def parse_specs(text: str) -> list[tuple[str, str]]:
    specs = []
    for token in text.split():
        arch, sep, deb = token.partition(":")
        specs.append((arch, deb if sep else arch))
    return specs


# --------------------------------------------------------------------------
# Installer
# --------------------------------------------------------------------------


class Installer:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.dry = args.dry_run
        self.family, self.distro_name = detect_distro()
        self.repo: Path | None = None
        self.tmp: Path | None = None
        self.sudo_ready = False
        self.backed_up = False
        self.unavailable: list[str] = []
        self.build_dirs: list[Path] = []
        self.fresh = args.mode == "fresh"
        self.minimal = args.mode == "minimal" or args.minimal

    # ---- plumbing --------------------------------------------------------

    def run(self, argv: list[str], *, sudo: bool = False, cwd: Path | None = None,
            env: dict | None = None) -> None:
        """Run a command that changes the system (honours --dry-run)."""
        if sudo:
            if not have("sudo") and not self.dry:
                raise Fail("sudo is required")
            argv = ["sudo", *argv]
        rendered = " ".join(shlex.quote(a) for a in argv)
        if self.dry:
            info(f"[dry-run] {rendered}")
            return
        if sudo and not self.sudo_ready:
            if subprocess.run(["sudo", "-v"]).returncode != 0:
                raise Fail("sudo authentication failed")
            self.sudo_ready = True
        if _log:
            _log.write(f"$ {rendered}\n")
        if subprocess.run(argv, cwd=cwd, env=env).returncode != 0:
            raise Fail(f"command failed: {rendered}")

    def ask(self, prompt: str, default: bool = True) -> bool:
        if self.args.assume_yes:
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

    def deb_state(self, names: list[str]) -> dict[str, tuple[bool, bool]]:
        """name -> (installed, installable) from a single apt-cache call."""
        state: dict[str, tuple[bool, bool]] = {}
        cur, inst, cand = None, False, False
        for line in query(["apt-cache", "policy", *names]).splitlines():
            if line and not line.startswith(" "):
                if cur:
                    state[cur] = (inst, cand)
                cur, inst, cand = line.rstrip(":").strip(), False, False
            elif "Installed:" in line:
                inst = "(none)" not in line
            elif "Candidate:" in line:
                cand = "(none)" not in line
        if cur:
            state[cur] = (inst, cand)
        return state

    def plan_debian(self) -> tuple[list[str], list[str]]:
        groups: list[list[list[str]]] = []  # package -> required parts -> alternatives
        labels: list[str] = []
        for arch, deb in self.wanted():
            if deb == ".":
                continue
            if deb == "-":
                labels.append(arch)
                groups.append([])
                continue
            labels.append(arch if arch != "-" else deb)
            groups.append([part.split("|") for part in deb.split(",")])

        flat = sorted({alt for g in groups for part in g for alt in part})
        state = self.deb_state(flat)
        if not any(c for _, c in state.values()) and not self.dry:
            self.run(["apt-get", "update"], sudo=True)  # empty package lists
            state = self.deb_state(flat)

        todo: list[str] = []
        missing: list[str] = []
        for label, g in zip(labels, groups):
            if not g:
                missing.append(label)
                continue
            for part in g:
                pick = next((a for a in part if state.get(a, (False, False))[1]
                             or state.get(a, (False, False))[0]), None)
                if pick is None:
                    missing.append(label)
                elif not state[pick][0]:
                    todo.append(pick)
        return list(dict.fromkeys(todo)), list(dict.fromkeys(missing))

    # ---- Debian: build what isn't packaged -------------------------------

    def apt_deps(self, pkgs: list[str]) -> None:
        state = self.deb_state(pkgs)
        gone = [p for p in pkgs if not any(state.get(p, (False, False)))]
        if gone:
            raise Fail("missing from your repositories: " + ", ".join(gone)
                       + " (a newer Debian or Ubuntu release may have them)")
        todo = [p for p in pkgs if not state[p][0]]
        if todo:
            self.run(["apt-get", "install", *(["-y"] if self.args.assume_yes else []), *todo],
                     sudo=True)

    def fetch_source(self, url: str, tags: str = "v*") -> Path:
        tmp = Path(tempfile.mkdtemp(prefix="build-"))
        self.build_dirs.append(tmp)
        tag = query(["git", "ls-remote", "--tags", "--refs", "--sort=-v:refname", url, tags])
        branch = ["--branch", tag.splitlines()[0].split("refs/tags/")[-1]] if tag.strip() else []
        self.run(["git", "-c", "advice.detachedHead=false", "clone", "-q", "--depth", "1",
                  *branch, url, str(tmp / "src")])
        return tmp / "src"

    def rust_env(self, minimum: tuple[int, int]) -> dict:
        """Environment with a Rust toolchain at least `minimum` (installs rustup if needed)."""
        env = dict(os.environ)
        cargo_home = Path(os.environ.get("CARGO_HOME") or HOME / ".cargo")
        env["PATH"] = f"{cargo_home / 'bin'}{os.pathsep}{SYSPATH}"

        def current() -> tuple[int, int]:
            m = re.search(r"rustc (\d+)\.(\d+)", query(["rustc", "--version"], env=env))
            return (int(m[1]), int(m[2])) if m else (0, 0)

        if current() < minimum:
            info("installing the Rust toolchain (rustup)")
            self.run(["sh", "-c", "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs"
                      " | sh -s -- -y --profile minimal"],
                     env={**env, "RUSTUP_INIT_SKIP_PATH_CHECK": "yes"})
            if current() < minimum:
                raise Fail(f"could not get Rust {minimum[0]}.{minimum[1]} or newer")
        return env

    @staticmethod
    def msrv(src: Path, default: tuple[int, int] = (1, 85)) -> tuple[int, int]:
        try:
            m = re.search(r'rust-version\s*=\s*"(\d+)\.(\d+)', (src / "Cargo.toml").read_text())
        except OSError:
            m = None
        return (int(m[1]), int(m[2])) if m else default

    def build_niri(self) -> None:
        self.apt_deps(BUILD_BASE + NIRI_DEPS)
        src = self.fetch_source("https://github.com/YaLTeR/niri")
        env = self.rust_env(self.msrv(src))
        self.run(["cargo", "build", "--release", "--locked"], cwd=src, env=env)
        res = src / "resources"
        for mode, source, dest in (
            ("755", src / "target/release/niri", "/usr/local/bin/niri"),
            ("755", res / "niri-session", "/usr/local/bin/niri-session"),
            ("644", res / "niri.desktop", "/usr/local/share/wayland-sessions/niri.desktop"),
            ("644", res / "niri-portals.conf",
             "/usr/local/share/xdg-desktop-portal/niri-portals.conf"),
            ("644", res / "niri.service", "/etc/systemd/user/niri.service"),
            ("644", res / "niri-shutdown.target", "/etc/systemd/user/niri-shutdown.target"),
        ):
            self.run(["install", f"-Dm{mode}", str(source), dest], sudo=True)

    def build_xwayland_satellite(self) -> None:
        self.apt_deps(BUILD_BASE + XWAYLAND_DEPS)
        src = self.fetch_source("https://github.com/Supreeeme/xwayland-satellite")
        env = self.rust_env(self.msrv(src))
        self.run(["cargo", "build", "--release", "--locked"], cwd=src, env=env)
        self.run(["install", "-Dm755", str(src / "target/release/xwayland-satellite"),
                  "/usr/local/bin/xwayland-satellite"], sudo=True)

    def build_awww(self) -> None:
        self.apt_deps(BUILD_BASE + AWWW_DEPS)
        src = self.fetch_source("https://codeberg.org/LGFae/awww")
        env = self.rust_env(self.msrv(src))
        self.run(["cargo", "build", "--release", "--locked"], cwd=src, env=env)
        for name in ("awww", "awww-daemon"):
            self.run(["install", "-Dm755", str(src / "target/release" / name),
                      f"/usr/local/bin/{name}"], sudo=True)

    def build_quickshell(self) -> None:
        qt = re.search(r"Candidate: (?:\d+:)?(\d+)\.(\d+)",
                       query(["apt-cache", "policy", "qt6-base-dev"]))
        if not qt or (int(qt[1]), int(qt[2])) < (6, 6):
            raise Fail("needs Qt 6.6 or newer (Debian 13 / Ubuntu 25.04 and up)")
        self.apt_deps(BUILD_BASE + QUICKSHELL_DEPS)
        src = self.fetch_source("https://github.com/quickshell-mirror/quickshell")
        self.run(["cmake", "-GNinja", "-B", "build", "-DCMAKE_BUILD_TYPE=Release",
                  "-DCRASH_HANDLER=OFF", "-DSERVICE_POLKIT=OFF",
                  f"-DDISTRIBUTOR={NAME} installer"], cwd=src)
        self.run(["cmake", "--build", "build"], cwd=src)
        self.run(["cmake", "--install", "build"], cwd=src, sudo=True)

    def build_tuigreet(self) -> None:
        self.apt_deps(BUILD_BASE)
        env = self.rust_env((1, 85))
        root = Path(tempfile.mkdtemp(prefix="tuigreet-"))
        self.build_dirs.append(root)
        self.run(["cargo", "install", "--locked", "--root", str(root), "tuigreet"], env=env)
        self.run(["install", "-Dm755", str(root / "bin/tuigreet"), "/usr/local/bin/tuigreet"],
                 sudo=True)

    def build_missing(self) -> None:
        todo = [t for t in ("niri", "xwayland-satellite", "quickshell", "awww") if not have(t)]
        if self.fresh and not have("tuigreet"):
            todo.append("tuigreet")
        if not todo:
            return
        head("Building from source")
        info("not packaged for this system: " + ", ".join(todo))
        info("this can take a while")
        for name in todo:
            if self.dry:
                info(f"[dry-run] build {name}")
                continue
            try:
                getattr(self, "build_" + name.replace("-", "_"))()
                ok(name)
            except Fail as exc:
                warn(f"{name}: {exc}")

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

    def install_packages(self) -> None:
        if self.args.no_deps:
            return
        if not self.family:
            raise Fail("unsupported system: need an Arch-based or Debian-based distro")
        head(f"Packages ({self.family})")
        yes = ["--noconfirm"] if self.args.assume_yes else []

        if self.family == "arch":
            todo, missing = self.plan_arch()
            if todo:
                info(f"installing {len(todo)} package(s)")
                self.run(["pacman", "-Syu", "--needed", *yes, *todo], sudo=True)
            ok(f"{len(todo)} installed, rest already present" if todo else "all present")
            self.unavailable += missing
            self.install_aur()
        else:
            todo, missing = self.plan_debian()
            if todo:
                info(f"installing {len(todo)} package(s)")
                self.run(["apt-get", "install", *(["-y"] if yes else []), *todo], sudo=True)
            ok(f"{len(todo)} installed, rest already present" if todo else "all present")
            self.unavailable += missing + AUR
            self.build_missing()

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

    def apply_dconf(self) -> None:
        assert self.repo
        src = self.repo / "dconf/interface.ini"
        if not src.is_file() or not have("dconf") or not os.environ.get("DBUS_SESSION_BUS_ADDRESS"):
            return
        if self.dry:
            info("[dry-run] load GTK interface settings")
            return
        BACKUP.mkdir(parents=True, exist_ok=True)
        (BACKUP / "interface.dconf").write_text(
            query(["dconf", "dump", "/org/gnome/desktop/interface/"]))
        self.backed_up = True
        with src.open() as fp:
            r = subprocess.run(["dconf", "load", "/org/gnome/desktop/interface/"], stdin=fp)
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

    def setup_services(self) -> None:
        head("Services")
        if not have("systemctl"):
            warn("systemd not found; enable NetworkManager and Bluetooth yourself")
        else:
            for unit in ("NetworkManager.service", "bluetooth.service"):
                if query(["systemctl", "list-unit-files", unit]).count(unit):
                    self.run(["systemctl", "enable", unit], sudo=True)
                    ok(f"enabled {unit}")

        if not (have("greetd") and have("niri-session")):
            warn("greetd or niri-session is missing; login manager not configured")
            return
        if not have("systemctl"):
            warn("skipping greetd (needs systemd)")
            return
        if have("tuigreet"):
            greeter = "tuigreet --time --remember --remember-session --asterisks --cmd niri-session"
        elif have("agreety"):
            greeter = "agreety --cmd niri-session"
            warn("tuigreet unavailable; using the plain agreety greeter")
        else:
            warn("no greeter found; login manager not configured")
            return
        user = next((u for u in ("greeter", "_greetd", "greetd")
                     if query(["getent", "passwd", u]).strip()), "greeter")

        cfg = Path("/etc/greetd/config.toml")
        if cfg.exists() and not self.dry:
            target = BACKUP / "etc/greetd/config.toml"
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(cfg, target)
            self.backed_up = True
        text = (
            "[terminal]\nvt = 1\n\n[default_session]\n"
            f'command = "{greeter}"\n'
            f'user = "{user}"\n'
        )
        fd, tmp = tempfile.mkstemp(suffix=".toml")
        os.close(fd)
        try:
            Path(tmp).write_text(text)
            self.run(["install", "-Dm644", tmp, str(cfg)], sudo=True)
            if greeter.startswith("tuigreet"):
                self.run(["install", "-d", "-o", user, "-g", user, "-m755",
                          "/var/cache/tuigreet"], sudo=True)
            self.run(["systemctl", "enable", "--force", "greetd.service"], sudo=True)
        finally:
            Path(tmp).unlink(missing_ok=True)
        ok(f"greetd ({greeter.split()[0]}), session: niri")

    # ---- verification ----------------------------------------------------

    def verify(self) -> None:
        head("Checking")
        gone = [c for c in VERIFY if not have(c)]
        if gone:
            warn("missing commands: " + ", ".join(gone))
        else:
            ok("core commands present")
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
            self.setup_services()
        self.verify()
        if not self.dry and not self.args.skip_reboot and self.ask("Reboot now?", default=False):
            self.run(["systemctl", "reboot"], sudo=True)

    def execute(self) -> int:
        if os.geteuid() == 0:
            raise Fail("do not run as root; sudo is used when needed")
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
             "Everything in Install, plus the greetd login manager. For new setups."),
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
        for d in [self.tmp, *self.build_dirs]:
            if d:
                shutil.rmtree(d, ignore_errors=True)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(prog="install.sh", description=f"{NAME} installer")
    p.add_argument("--fresh", action="store_true", help="fresh system setup (adds greetd)")
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
