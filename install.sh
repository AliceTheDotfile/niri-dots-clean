#!/usr/bin/env bash
#
# Alice's Niri dots - single-file installer :3
#
# Everything lives in this file. It contains the Python installer directly,
# so both of these work:
#
# Local:
#   ./install.sh
#
# Remote:
#   curl -fsSL https://raw.githubusercontent.com/AliceTheDotfile/niri-dots-clean/main/install.sh | bash
#

set -Eeuo pipefail

SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
SCRIPT_DIR=""

if [[ -n "$SCRIPT_SOURCE" ]]; then
    SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_SOURCE")" 2>/dev/null && pwd -P)" || true
fi

# When this is a real local install.sh, make the repository discoverable by
# running the embedded installer from the repository directory.
if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/install.sh" && -d "$SCRIPT_DIR/niri" ]]; then
    cd -- "$SCRIPT_DIR"
fi

# The Python installer is embedded below. Keep Bash's stdin alone because
# it may be the curl pipe containing this script. Give Python a separate
# terminal fd instead, so the interactive menu can still read keystrokes.
if [[ ! -t 0 && -r /dev/tty ]]; then
    exec 4</dev/tty
else
    exec 4<&0
fi

command -v python3 >/dev/null 2>&1 || {
    if command -v sudo >/dev/null 2>&1 && command -v pacman >/dev/null 2>&1; then
        printf '\033[38;5;205m::\033[0m Python 3 is required; installing it...\n'
        sudo pacman -Syu --needed --noconfirm python
    else
        printf 'error: python3 is required, and pacman/sudo are unavailable\n' >&2
        exit 1
    fi
}

if ! command -v python3 >/dev/null 2>&1; then
    printf 'error: python3 is still unavailable after bootstrap\n' >&2
    exit 1
fi

python3 /dev/fd/3 "$@" </dev/fd/4 3<<'PYTHON'
"""
Alice's Niri dotfiles installer :3

Python/stdlib-only installer for Arch Linux.

It can run from:
  * a local git clone containing install.sh
  * the single-file install.sh bootstrap

When the repository is not present locally, the installer downloads the
latest main branch archive into a temporary directory and cleans it up when
finished.

Managed:
  Niri, Quickshell, Kate, Wallfliper, themes, local scripts, wallpapers,
  selected desktop configuration, packages, and fresh-system services.

Never managed:
  ~/.config/waybar
  ~/.config/fastfetch
  Kate session files such as ~/.local/share/kate/anonymous.katesession
"""

from __future__ import annotations

import argparse
import datetime as dt
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
from pathlib import Path
from typing import Iterable
from urllib.error import URLError
from urllib.request import Request, urlopen


VERSION = "2.0.0"
REPO_URL = "https://github.com/AliceTheDotfile/niri-dots-clean"
ARCHIVE_URL = (
    "https://codeload.github.com/AliceTheDotfile/"
    "niri-dots-clean/tar.gz/refs/heads/main"
)

HOME = Path.home()
CONFIG = Path(os.environ.get("XDG_CONFIG_HOME", HOME / ".config"))
SHARE = Path(os.environ.get("XDG_DATA_HOME", HOME / ".local/share"))
BIN = HOME / ".local/bin"

BACKUP_ROOT = HOME / ".dotfiles-backup"
CACHE_ROOT = HOME / ".cache/alice-niri-dots"
TIMESTAMP = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
BACKUP = BACKUP_ROOT / TIMESTAMP
LOG_FILE = CACHE_ROOT / f"install-{TIMESTAMP}.log"

RESET = "\033[0m"
BOLD = "\033[1m"
DIM = "\033[2m"
PINK = "\033[38;5;205m"
PURPLE = "\033[38;5;141m"
CYAN = "\033[38;5;81m"
GREEN = "\033[38;5;114m"
YELLOW = "\033[38;5;221m"
RED = "\033[38;5;203m"
WHITE = "\033[97m"
GRAY = "\033[90m"


CORE_PKGS = [
    # Niri
    "niri",
    "xwayland-satellite",
    # Shell / terminal
    "quickshell",
    "kitty",
    "swaync",
    "wofi",
    # KDE / themes
    "kate",
    "qt6ct",
    "nwg-look",
    "kvantum",
    "layer-shell-qt",
    "papirus-icon-theme",
    "dconf",
    # Wallpaper
    "awww",
    "mpv",
    "ffmpeg",
    "pyside6",
    # Audio
    "pipewire",
    "pipewire-pulse",
    "wireplumber",
    "playerctl",
    "pavucontrol",
    # Wayland utilities
    "brightnessctl",
    "grim",
    "slurp",
    "wl-clipboard",
    # Desktop integration
    "xdg-utils",
    "xdg-user-dirs",
    "xdg-desktop-portal",
    "xdg-desktop-portal-gtk",
    # Networking
    "networkmanager",
    "network-manager-applet",
    # Bluetooth
    "bluez",
    "bluez-utils",
    "blueman",
    # General
    "python",
    "jq",
    "rsync",
    "git",
    # Fonts
    "ttf-hack",
    "noto-fonts",
    "noto-fonts-emoji",
    "otf-atkinsonhyperlegiblemono-nerd",
    "woff2-font-awesome",
]

NICE_PKGS = [
    "firefox",
    "thunar",
    "file-roller",
    "7zip",
    "unzip",
    "zip",
    "imv",
    "neovim",
    "fzf",
    "ripgrep",
    "fd",
    "bat",
    "eza",
    "tree",
    "less",
    "fastfetch",
    "man-db",
    "man-pages",
]

FRESH_PKGS = [
    "greetd",
    "greetd-tuigreet",
]

AUR_PKGS = [
    "mpvpaper",
    "neowall-bin",
]

CONFIG_DIRS = [
    "alice-rice",
    "btop",
    "cava",
    "environment.d",
    "fontconfig",
    "gamearch",
    "gtk-3.0",
    "gtk-4.0",
    "Kvantum",
    "niri",
    "qt6ct",
    "swaync",
]

HOME_ITEMS = [
    ".bashrc",
    ".bash_profile",
    ".config/kdeglobals",
    ".config/kate",
    ".config/katerc",
    ".config/katevirc",
    ".config/katemetainfos",
    ".local/share/color-schemes/AliceNight.colors",
    ".local/share/themes/AliceNight",
    ".icons/Bibata-Material-Cloud",
]

REQUIRED_REPO_PATHS = [
    "niri",
    "quickshell/my-shell",
    "wallfliper",
    "local/bin",
    "Wallpapers",
]

OPTIONAL_REPO_PATHS = [
    "home/.config/kate",
    "home/.config/katerc",
    "home/.config/katevirc",
    "home/.config/katemetainfos",
]


class InstallerError(RuntimeError):
    """Expected installer failure."""


class Logger:
    def __init__(self, path: Path, color: bool = True) -> None:
        self.path = path
        self.color = color
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._fp = self.path.open("a", encoding="utf-8")

    def close(self) -> None:
        try:
            self._fp.close()
        except Exception:
            pass

    def _clean(self, text: str) -> str:
        return re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", text)

    def write(self, text: str = "") -> None:
        print(text)
        self._fp.write(self._clean(text) + "\n")
        self._fp.flush()

    def raw(self, text: str = "") -> None:
        print(text, end="")
        self._fp.write(self._clean(text))
        self._fp.flush()

    def command(self, argv: list[str]) -> None:
        rendered = " ".join(shell_quote(part) for part in argv)
        self._fp.write(f"$ {rendered}\n")
        self._fp.flush()


def shell_quote(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


class Installer:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.dotfiles: Path | None = None
        self.bootstrap_dir: Path | None = None
        self.logger = Logger(
            LOG_FILE,
            color=(not args.no_color and sys.stdout.isatty()),
        )
        self.step_no = 0
        self.total_steps = 0
        self.summary: list[str] = []
        self.changed = False
        self.backup_created = False

    # --------------------------------------------------------
    # Output
    # --------------------------------------------------------

    def paint(self, color: str, text: str) -> str:
        if self.logger.color:
            return f"{color}{text}{RESET}"
        return text

    def say(self, message: str) -> None:
        self.logger.write(
            f"{self.paint(PINK, '::')} {message}"
        )

    def info(self, message: str) -> None:
        self.logger.write(
            f"{self.paint(CYAN, '→')} {message}"
        )

    def success(self, message: str) -> None:
        self.logger.write(
            f"{self.paint(GREEN, '✓')} {message}"
        )

    def warn(self, message: str) -> None:
        self.logger.write(
            f"{self.paint(YELLOW, '!')} {message}"
        )

    def fail(self, message: str) -> None:
        self.logger.write(
            f"{self.paint(RED, '✗')} {message}"
        )

    def step(self, message: str) -> None:
        self.step_no += 1
        prefix = f"[{self.step_no}/{self.total_steps}]"
        self.logger.write(
            f"{self.paint(PURPLE, prefix)} {message}"
        )

    def clear(self) -> None:
        if sys.stdout.isatty():
            print("\033[2J\033[H", end="")

    # --------------------------------------------------------
    # Lifecycle
    # --------------------------------------------------------

    def cleanup(self) -> None:
        if self.bootstrap_dir and self.bootstrap_dir.exists():
            shutil.rmtree(self.bootstrap_dir, ignore_errors=True)

        self.logger.close()

    def fail_gracefully(self, exc: BaseException) -> int:
        if isinstance(exc, KeyboardInterrupt):
            self.fail("installation cancelled")
            return 130

        self.fail(str(exc))
        self.info(f"log saved to {LOG_FILE}")
        if self.backup_created:
            self.info(f"backup saved to {BACKUP}")
        return 1

    # --------------------------------------------------------
    # Basic checks
    # --------------------------------------------------------

    @staticmethod
    def command_exists(name: str) -> bool:
        return shutil.which(name) is not None

    def require_arch(self) -> None:
        if not self.command_exists("pacman"):
            raise InstallerError(
                "this installer requires Arch Linux or another "
                "Arch-based system with pacman"
            )

        if os.geteuid() == 0:
            raise InstallerError("do not run this installer as root")

        if not self.command_exists("sudo"):
            raise InstallerError("sudo is required by this installer")

    def ensure_sudo(self) -> None:
        if self.args.dry_run:
            return

        self.say("checking sudo access")
        result = subprocess.run(
            ["sudo", "-v"],
            stdin=sys.stdin,
            stdout=None,
            stderr=None,
            check=False,
        )
        if result.returncode != 0:
            raise InstallerError("sudo authentication failed")

    # --------------------------------------------------------
    # Repository
    # --------------------------------------------------------

    def repo_complete(self, path: Path | None) -> bool:
        if path is None:
            return False

        required = [path / item for item in REQUIRED_REPO_PATHS]
        return all(item.exists() for item in required)

    def discover_local_repo(self) -> Path | None:
        candidates: list[Path] = []

        cwd = Path.cwd().resolve()
        candidates.append(cwd)

        script_value = globals().get("__file__")
        if script_value and not str(script_value).startswith("<"):
            try:
                candidates.append(Path(script_value).resolve().parent)
            except Exception:
                pass

        seen: set[Path] = set()
        for candidate in candidates:
            if candidate in seen:
                continue
            seen.add(candidate)

            if self.repo_complete(candidate):
                return candidate

        return None

    def _safe_extract_tar(self, archive: tarfile.TarFile, destination: Path) -> None:
        destination = destination.resolve()

        for member in archive.getmembers():
            target = (destination / member.name).resolve()
            try:
                target.relative_to(destination)
            except ValueError:
                raise InstallerError(
                    f"refusing unsafe archive path: {member.name}"
                )

        for member in archive.getmembers():
            archive.extract(member, path=destination)

    def download_repo(self) -> Path:
        self.say("downloading latest Alice Niri dots from GitHub")

        self.bootstrap_dir = Path(
            tempfile.mkdtemp(prefix="alice-niri-dots-")
        )

        archive_path = self.bootstrap_dir / "repo.tar.gz"

        request = Request(
            ARCHIVE_URL,
            headers={
                "User-Agent": f"Alice-Niri-Dots-Installer/{VERSION}",
                "Accept": "application/vnd.github+json",
            },
        )

        try:
            with urlopen(request, timeout=60) as response:
                with archive_path.open("wb") as fp:
                    while True:
                        chunk = response.read(1024 * 1024)
                        if not chunk:
                            break
                        fp.write(chunk)
        except (OSError, URLError) as exc:
            raise InstallerError(
                f"could not download the dotfiles repository: {exc}"
            ) from exc

        self.say("extracting repository")

        extract_root = self.bootstrap_dir / "extract"
        extract_root.mkdir()

        try:
            with tarfile.open(archive_path, "r:gz") as archive:
                self._safe_extract_tar(archive, extract_root)
        except (OSError, tarfile.TarError) as exc:
            raise InstallerError(
                f"could not extract the dotfiles archive: {exc}"
            ) from exc

        roots = [p for p in extract_root.iterdir() if p.is_dir()]
        if len(roots) == 1:
            repo = roots[0]
        else:
            repo = extract_root

        if not self.repo_complete(repo):
            raise InstallerError(
                "downloaded repository is missing required files"
            )

        archive_path.unlink(missing_ok=True)
        self.success("latest dotfiles downloaded")
        return repo

    def bootstrap_repo(self) -> None:
        local = self.discover_local_repo()

        if local is not None:
            self.dotfiles = local
            self.info(f"repository: {local}")
            return

        self.dotfiles = self.download_repo()
        self.info(f"temporary repository: {self.dotfiles}")

    def validate_repo(self) -> None:
        assert self.dotfiles is not None

        self.step("checking repository")

        missing = []
        for rel in REQUIRED_REPO_PATHS:
            path = self.dotfiles / rel
            if not path.exists():
                missing.append(rel)

        for rel in OPTIONAL_REPO_PATHS:
            if not (self.dotfiles / rel).exists():
                self.warn(f"optional Kate config not present: {rel}")

        if missing:
            raise InstallerError(
                "repository is missing required paths: "
                + ", ".join(missing)
            )

        self.success("repository looks good")

    def update_repo(self) -> None:
        assert self.dotfiles is not None

        git_dir = self.dotfiles / ".git"

        if not git_dir.is_dir():
            self.say("using latest GitHub snapshot")
            self.success("dotfiles are already at the latest downloaded revision")
            return

        if not self.command_exists("git"):
            raise InstallerError("git is required for local update mode")

        self.step("checking local git repository")

        result = subprocess.run(
            ["git", "-C", str(self.dotfiles), "status", "--porcelain"],
            capture_output=True,
            text=True,
            check=False,
        )

        if result.returncode != 0:
            raise InstallerError("could not inspect git repository")

        status = result.stdout.strip()
        if status:
            self.fail("the dotfiles repository has uncommitted changes")
            self.logger.write()
            self.logger.write(status)
            raise InstallerError(
                "update stopped so your local repository changes "
                "are not overwritten"
            )

        branch = subprocess.run(
            ["git", "-C", str(self.dotfiles), "branch", "--show-current"],
            capture_output=True,
            text=True,
            check=False,
        ).stdout.strip()

        if branch:
            self.info(f"branch: {branch}")
        else:
            self.warn("repository is in detached HEAD state")

        if self.args.dry_run:
            self.info("[dry] would run git pull --ff-only")
            return

        self.say("pulling latest dotfiles")
        self.run(["git", "-C", str(self.dotfiles), "pull", "--ff-only"])
        self.success("dotfiles repository updated")

    # --------------------------------------------------------
    # Command execution
    # --------------------------------------------------------

    def run(
        self,
        argv: list[str],
        *,
        sudo: bool = False,
        cwd: Path | None = None,
        check: bool = True,
        capture: bool = False,
    ) -> subprocess.CompletedProcess[str]:
        command = list(argv)
        if sudo:
            command.insert(0, "sudo")

        self.logger.command(command)

        if self.args.dry_run:
            rendered = " ".join(shell_quote(x) for x in command)
            self.info(f"[dry] {rendered}")
            return subprocess.CompletedProcess(
                command,
                0,
                stdout="" if capture else None,
                stderr="" if capture else None,
            )

        result = subprocess.run(
            command,
            cwd=str(cwd) if cwd else None,
            text=True,
            capture_output=capture,
            check=False,
        )

        if check and result.returncode != 0:
            if capture and result.stderr:
                self.logger.write(result.stderr.rstrip())
            raise InstallerError(
                f"command failed ({result.returncode}): "
                + " ".join(command)
            )

        return result

    # --------------------------------------------------------
    # Interactive helpers
    # --------------------------------------------------------

    def ask(
        self,
        prompt: str,
        *,
        default: bool = True,
    ) -> bool:
        if self.args.assume_yes:
            return True

        if not sys.stdin.isatty():
            return default

        suffix = "[Y/n]" if default else "[y/N]"
        try:
            answer = input(f"{prompt} {suffix} ").strip().lower()
        except EOFError:
            return default

        if not answer:
            return default

        return answer in {"y", "yes"}

    def pause(self) -> None:
        if not sys.stdin.isatty():
            return

        try:
            input("\npress enter to continue...")
        except EOFError:
            pass

    def menu(self) -> int:
        options = [
            "full setup       — Niri + rice + Kate + apps + AUR",
            "update existing  — pull newest repo + update rice",
            "fresh Arch setup — everything + greetd + tuigreet",
            "minimal setup    — Niri + rice + Kate + core packages",
            "configs only     — dotfiles without packages",
            "packages only    — install dependencies/apps",
            "exit",
        ]

        if not sys.stdin.isatty() or not sys.stdout.isatty():
            self.info("interactive installer needs a terminal")
            self.info("use --no-tui for a non-interactive launch")
            return 6

        try:
            import termios
            import tty
        except ImportError as exc:
            raise InstallerError("terminal input support is unavailable") from exc

        selected = 0
        fd = sys.stdin.fileno()
        old = termios.tcgetattr(fd)

        try:
            tty.setcbreak(fd)

            while True:
                self.clear()
                print()
                print(
                    " "
                    + self.paint(PINK, "╭──────────────────────────────────────────────────────╮")
                )
                print(
                    " "
                    + self.paint(PINK, "│")
                    + " "
                    + self.paint(WHITE + BOLD, "alice's niri dots installer")
                    + " "
                    + self.paint(DIM, f"v{VERSION} :3")
                    + "                    "
                    + self.paint(PINK, "│")
                )
                print(
                    " "
                    + self.paint(PINK, "│")
                    + " "
                    + self.paint(GRAY, "python • safe backups • GitHub bootstrap")
                    + "          "
                    + self.paint(PINK, "│")
                )
                print(
                    " "
                    + self.paint(PINK, "╰──────────────────────────────────────────────────────╯")
                )
                print()
                print(
                    " "
                    + self.paint(PURPLE + BOLD, "what would you like to do?")
                )
                print()

                for index, option in enumerate(options):
                    if index == selected:
                        print(
                            "   "
                            + self.paint(PINK, "›")
                            + " "
                            + self.paint(WHITE + BOLD, option)
                        )
                    else:
                        print(
                            "     "
                            + self.paint(GRAY, option)
                        )

                print()
                print(
                    " "
                    + self.paint(GRAY, "↑/↓ or j/k")
                    + "   "
                    + self.paint(GRAY, "Enter")
                    + " select   "
                    + self.paint(GRAY, "q")
                    + " quit"
                )

                key = os.read(fd, 1)

                if key in (b"\n", b"\r"):
                    return selected

                if key in (b"j", b"B"):
                    selected = (selected + 1) % len(options)
                    continue

                if key in (b"k", b"A"):
                    selected = (selected - 1) % len(options)
                    continue

                if key in (b"q", b"Q"):
                    return len(options) - 1

                if key == b"\x1b":
                    second = os.read(fd, 1)
                    if second == b"[":
                        third = os.read(fd, 1)
                        if third == b"A":
                            selected = (selected - 1) % len(options)
                        elif third == b"B":
                            selected = (selected + 1) % len(options)

        finally:
            termios.tcsetattr(fd, termios.TCSADRAIN, old)
            print(RESET, end="")

    # --------------------------------------------------------
    # Package handling
    # --------------------------------------------------------

    def pacman_package_exists(self, package: str) -> bool:
        result = subprocess.run(
            ["pacman", "-Si", package],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        return result.returncode == 0

    def install_official_packages(self, packages: Iterable[str]) -> None:
        package_list = list(dict.fromkeys(packages))
        valid = []
        missing = []

        for package in package_list:
            if self.pacman_package_exists(package):
                valid.append(package)
            else:
                missing.append(package)

        for package in missing:
            self.warn(f"not found in Arch repositories: {package}")

        if not valid:
            return

        self.step(f"installing {len(valid)} official packages")

        self.run(
            [
                "pacman",
                "-Syu",
                "--needed",
                "--noconfirm",
                *valid,
            ],
            sudo=True,
        )
        self.success("official packages installed")

    def aur_helper(self) -> str | None:
        for name in ("yay", "paru"):
            if self.command_exists(name):
                return name
        return None

    def install_yay(self) -> str:
        if self.command_exists("yay"):
            return "yay"

        self.step("bootstrapping yay")

        self.install_official_packages(["base-devel", "git"])

        temp = Path(tempfile.mkdtemp(prefix="alice-yay-"))
        try:
            self.run(
                [
                    "git",
                    "clone",
                    "https://aur.archlinux.org/yay.git",
                    str(temp / "yay"),
                ]
            )

            self.run(
                ["makepkg", "-si", "--noconfirm"],
                cwd=temp / "yay",
            )
        finally:
            shutil.rmtree(temp, ignore_errors=True)

        if not self.command_exists("yay"):
            raise InstallerError("yay installation did not produce a yay command")

        self.success("yay installed")
        return "yay"

    def install_aur_packages(self, packages: Iterable[str]) -> None:
        package_list = list(dict.fromkeys(packages))
        if not package_list:
            return

        helper = self.aur_helper()

        if helper is None:
            self.warn("no AUR helper found")

            if self.args.dry_run:
                self.info("[dry] would offer to install yay")
                return

            if self.args.assume_no:
                self.warn("AUR packages skipped")
                return

            if self.ask("install yay automatically?", default=True):
                helper = self.install_yay()
            else:
                self.warn("AUR packages skipped")
                return

        self.step(f"installing {len(package_list)} AUR packages with {helper}")

        self.run(
            [
                helper,
                "-S",
                "--needed",
                "--noconfirm",
                *package_list,
            ]
        )
        self.success("AUR packages installed")

    def build_package_list(self) -> list[str]:
        packages = list(CORE_PKGS)

        if not self.args.minimal:
            packages.extend(NICE_PKGS)

        if self.args.fresh:
            packages.extend(FRESH_PKGS)

        return list(dict.fromkeys(packages))

    def install_deps(self) -> None:
        self.ensure_sudo()
        self.install_official_packages(self.build_package_list())
        self.install_aur_packages(AUR_PKGS)

    # --------------------------------------------------------
    # Files / backups
    # --------------------------------------------------------

    @staticmethod
    def lexists(path: Path) -> bool:
        return os.path.lexists(path)

    def ensure_backup_root(self) -> None:
        if not self.backup_created:
            if self.args.dry_run:
                self.info(f"[dry] would create backup directory {BACKUP}")
            else:
                BACKUP.mkdir(parents=True, exist_ok=True)
            self.backup_created = True

    def backup_destination(self, destination: Path) -> None:
        if not self.lexists(destination):
            return

        self.ensure_backup_root()

        try:
            relative = destination.relative_to(HOME)
        except ValueError:
            relative = Path("outside-home") / destination.as_posix().lstrip("/")

        target = BACKUP / relative
        target.parent.mkdir(parents=True, exist_ok=True)

        if self.args.dry_run:
            self.info(f"[dry] would move {destination} -> {target}")
            return

        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(destination), str(target))
        self.changed = True

    def replace_home_token(self, path: Path) -> None:
        if self.args.dry_run or not path.exists():
            return

        files: list[Path] = []

        if path.is_file():
            files = [path]
        elif path.is_dir():
            for item in path.rglob("*"):
                if item.is_file() and not item.is_symlink():
                    files.append(item)

        for item in files:
            try:
                data = item.read_bytes()
            except OSError:
                continue

            marker = b"@HOME@"
            if marker not in data:
                continue

            try:
                text = data.decode("utf-8")
            except UnicodeDecodeError:
                continue

            text = text.replace("@HOME@", str(HOME))
            item.write_text(text, encoding="utf-8")

    def place(self, source: Path, destination: Path) -> None:
        if not self.lexists(source):
            self.warn(f"missing in repo: {source.relative_to(self.dotfiles)}")
            return

        if self.lexists(destination):
            self.say(f"backing up {destination}")
            self.backup_destination(destination)

        if self.args.dry_run:
            if source.is_dir():
                self.info(f"[dry] would copy directory {source} -> {destination}")
            else:
                self.info(f"[dry] would copy {source} -> {destination}")
            return

        destination.parent.mkdir(parents=True, exist_ok=True)

        if source.is_dir() and not source.is_symlink():
            shutil.copytree(source, destination, symlinks=True)
        else:
            shutil.copy2(source, destination, follow_symlinks=False)

        try:
            if source.is_file() and not source.is_symlink():
                mode = stat.S_IMODE(source.stat().st_mode)
                if mode & stat.S_IXUSR:
                    destination.chmod(destination.stat().st_mode | stat.S_IXUSR)
        except OSError:
            pass

        self.replace_home_token(destination)
        self.changed = True

    # --------------------------------------------------------
    # Config installation
    # --------------------------------------------------------

    def install_configs(self) -> None:
        assert self.dotfiles is not None
        self.step("installing desktop configs")

        for name in CONFIG_DIRS:
            self.place(
                self.dotfiles / name,
                CONFIG / name,
            )

        self.place(
            self.dotfiles / "quickshell/my-shell",
            CONFIG / "quickshell/my-shell",
        )

        self.success("desktop configs installed")
        self.info("Fastfetch config untouched")
        self.info("Waybar config untouched")

    def install_home_files(self) -> None:
        assert self.dotfiles is not None
        self.step("installing shell, Kate, and theme files")

        for item in HOME_ITEMS:
            self.place(
                self.dotfiles / "home" / item,
                HOME / item,
            )

        self.success("shell, Kate, and theme files installed")
        self.info("Kate session files are not installed")

    # --------------------------------------------------------
    # Wallfliper
    # --------------------------------------------------------

    def install_wallfliper(self) -> None:
        assert self.dotfiles is not None
        self.step("installing Wallfliper")

        self.place(
            self.dotfiles / "wallfliper",
            SHARE / "wallfliper",
        )

        self.place(
            self.dotfiles / "wallfliper/config.json",
            CONFIG / "wallfliper/config.json",
        )

        launcher_source = self.dotfiles / "local/bin/wallfliper"
        launcher = BIN / "wallfliper"

        if not launcher_source.exists():
            if self.lexists(launcher):
                self.say("backing up existing Wallfliper launcher")
                self.backup_destination(launcher)

            if self.args.dry_run:
                self.info(f"[dry] would create {launcher}")
            else:
                BIN.mkdir(parents=True, exist_ok=True)
                launcher.write_text(
                    "#!/usr/bin/env bash\n"
                    f'exec python "{SHARE / "wallfliper/main.py"}" "$@"\n',
                    encoding="utf-8",
                )
                launcher.chmod(launcher.stat().st_mode | stat.S_IXUSR)
                self.changed = True

        self.success("Wallfliper installed")

    # --------------------------------------------------------
    # Local scripts
    # --------------------------------------------------------

    def install_scripts(self) -> None:
        assert self.dotfiles is not None
        self.step("installing scripts to ~/.local/bin")

        source_dir = self.dotfiles / "local/bin"
        BIN.mkdir(parents=True, exist_ok=True) if not self.args.dry_run else None

        if source_dir.is_dir():
            for source in sorted(source_dir.iterdir()):
                if not source.is_file():
                    continue

                destination = BIN / source.name
                self.place(source, destination)

                if not self.args.dry_run:
                    try:
                        destination.chmod(
                            destination.stat().st_mode
                            | stat.S_IXUSR
                            | stat.S_IXGRP
                            | stat.S_IXOTH
                        )
                    except OSError as exc:
                        self.warn(
                            f"could not mark {destination.name} executable: {exc}"
                        )

        self.success("local scripts installed")

    # --------------------------------------------------------
    # Wallpapers
    # --------------------------------------------------------

    def install_wallpapers(self) -> None:
        assert self.dotfiles is not None
        self.step("installing wallpapers")

        source_dir = self.dotfiles / "Wallpapers"
        destination_dir = HOME / "Wallpapers"

        if not self.args.dry_run:
            destination_dir.mkdir(parents=True, exist_ok=True)

        if source_dir.is_dir():
            for source in sorted(source_dir.iterdir()):
                if not source.is_file():
                    continue

                destination = destination_dir / source.name

                if self.lexists(destination):
                    self.info(
                        f"keeping existing wallpaper: {source.name}"
                    )
                    continue

                if self.args.dry_run:
                    self.info(
                        f"[dry] would copy wallpaper: {source.name}"
                    )
                else:
                    shutil.copy2(source, destination)
                    self.changed = True

        self.success("wallpapers installed")

    # --------------------------------------------------------
    # PATH
    # --------------------------------------------------------

    def path_contains_bin(self) -> bool:
        entries = os.environ.get("PATH", "").split(os.pathsep)
        return str(BIN) in entries

    def file_mentions_bin(self, path: Path) -> bool:
        if not path.is_file():
            return False

        try:
            text = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            return False

        patterns = (
            r"(^|:|\$HOME/)\.local/bin",
            r"\.local/bin.*PATH",
            r"PATH=.*\.local/bin",
        )

        return any(re.search(pattern, text) for pattern in patterns)

    def add_path_to_file(self, path: Path) -> None:
        if self.file_mentions_bin(path):
            return

        if self.args.dry_run:
            self.info(f"[dry] would add ~/.local/bin to {path}")
            return

        path.parent.mkdir(parents=True, exist_ok=True)

        with path.open("a", encoding="utf-8") as fp:
            fp.write(
                "\n"
                "# Alice dotfiles - local user scripts\n"
                'export PATH="$HOME/.local/bin:$PATH"\n'
            )

        self.changed = True

    def setup_path(self) -> None:
        self.step("checking ~/.local/bin PATH")

        if self.path_contains_bin():
            self.success("~/.local/bin is already in PATH")
            return

        if not self.args.dry_run:
            os.environ["PATH"] = f"{BIN}{os.pathsep}" + os.environ.get(
                "PATH", ""
            )

        for path in (
            HOME / ".profile",
            HOME / ".bash_profile",
            HOME / ".bashrc",
            HOME / ".zshrc",
        ):
            self.add_path_to_file(path)

        self.success("~/.local/bin added to PATH")

    # --------------------------------------------------------
    # dconf
    # --------------------------------------------------------

    def apply_dconf(self) -> None:
        assert self.dotfiles is not None
        source = self.dotfiles / "dconf/interface.ini"

        if not source.is_file():
            return

        if not self.command_exists("dconf"):
            self.warn("dconf not installed; skipping GTK settings")
            return

        if not os.environ.get("DBUS_SESSION_BUS_ADDRESS"):
            self.warn("no D-Bus session bus; skipping dconf settings")
            return

        self.step("applying GTK interface settings")

        if self.args.dry_run:
            self.info("[dry] would load dconf settings")
            return

        BACKUP.mkdir(parents=True, exist_ok=True)

        dump = subprocess.run(
            ["dconf", "dump", "/org/gnome/desktop/interface/"],
            capture_output=True,
            text=True,
            check=False,
        )

        try:
            (BACKUP / "interface.dconf.bak").write_text(
                dump.stdout,
                encoding="utf-8",
            )
        except OSError as exc:
            self.warn(f"could not save dconf backup: {exc}")

        with source.open("r", encoding="utf-8") as fp:
            result = subprocess.run(
                ["dconf", "load", "/org/gnome/desktop/interface/"],
                stdin=fp,
                text=True,
                check=False,
            )

        if result.returncode != 0:
            self.warn("dconf load failed")
        else:
            self.success("GTK interface settings applied")

    # --------------------------------------------------------
    # greetd / services
    # --------------------------------------------------------

    def setup_greetd(self) -> None:
        self.step("configuring greetd + tuigreet")

        for command, label in (
            ("greetd", "greetd"),
            ("tuigreet", "tuigreet"),
            ("niri-session", "niri-session"),
        ):
            if not self.command_exists(command):
                raise InstallerError(f"{label} is not installed")

        config_path = Path("/etc/greetd/config.toml")

        if config_path.exists():
            self.ensure_backup_root()
            target = BACKUP / "etc/greetd/config.toml"

            if self.args.dry_run:
                self.info(
                    f"[dry] would back up {config_path} -> {target}"
                )
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(config_path, target)
                self.changed = True

        config = """[terminal]
vt = 1

[default_session]
command = "tuigreet --time --remember --remember-session --asterisks --cmd niri-session"
user = "greeter"
"""

        if self.args.dry_run:
            self.info("[dry] would write /etc/greetd/config.toml")
            self.info("[dry] would enable greetd.service")
            return

        temp = Path(tempfile.mkstemp(prefix="greetd-", suffix=".toml")[1])
        try:
            temp.write_text(config, encoding="utf-8")
            self.run(
                ["install", "-d", "-m", "0755", "/etc/greetd"],
                sudo=True,
            )
            self.run(
                ["install", "-m", "0644", str(temp), str(config_path)],
                sudo=True,
            )
            self.run(
                ["systemctl", "enable", "greetd.service"],
                sudo=True,
            )
        finally:
            temp.unlink(missing_ok=True)

        self.success("greetd configured")
        self.success("tuigreet configured")
        self.success("Niri configured as the login session")

    def setup_fresh_services(self) -> None:
        self.step("configuring fresh-system services")

        if not self.command_exists("systemctl"):
            self.warn("systemctl unavailable; cannot configure services")
            return

        for service in (
            "NetworkManager.service",
            "bluetooth.service",
        ):
            result = subprocess.run(
                ["systemctl", "list-unit-files", service],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )

            if result.returncode != 0:
                continue

            self.say(f"enabling {service}")
            self.run(
                ["systemctl", "enable", service],
                sudo=True,
            )

        self.setup_greetd()

    # --------------------------------------------------------
    # Verification
    # --------------------------------------------------------

    def check_command_status(self, command: str, label: str) -> None:
        if self.command_exists(command):
            self.success(label)
        else:
            self.warn(f"{label} missing")

    def verify(self) -> None:
        self.step("checking installation")

        checks = [
            ("niri", "Niri"),
            ("niri-session", "Niri session"),
            ("quickshell", "Quickshell"),
            ("kitty", "Kitty"),
            ("kate", "Kate"),
            ("awww", "awww"),
            ("mpv", "mpv"),
            ("ffmpeg", "ffmpeg"),
            ("python", "Python"),
            ("thunar", "Thunar"),
            ("firefox", "Firefox"),
            ("nvim", "Neovim"),
        ]

        for command, label in checks:
            self.check_command_status(command, label)

        if self.command_exists("fastfetch"):
            self.success("Fastfetch")
        elif not self.args.minimal:
            self.warn("Fastfetch missing")

        if (CONFIG / "waybar").exists():
            self.info("existing Waybar config detected and left untouched")

        if (CONFIG / "fastfetch").exists():
            self.info("existing Fastfetch config detected and left untouched")

        if self.path_contains_bin():
            self.success("~/.local/bin is in PATH")
        else:
            self.warn("~/.local/bin is not currently in PATH")

        if self.args.fresh:
            self.check_command_status("greetd", "greetd")
            self.check_command_status("tuigreet", "tuigreet")

            if Path("/etc/greetd/config.toml").is_file():
                self.success("greetd configuration")
            else:
                self.warn("greetd configuration missing")

        wallfliper = SHARE / "wallfliper/main.py"
        if wallfliper.is_file() and self.command_exists("python"):
            self.step("checking Wallfliper dependencies")

            if self.args.dry_run:
                self.info("[dry] would run Wallfliper dependency check")
            else:
                result = subprocess.run(
                    ["python", str(wallfliper), "--check"],
                    text=True,
                    check=False,
                )

                if result.returncode == 0:
                    self.success("Wallfliper dependency check passed")
                else:
                    self.warn(
                        "Wallfliper reported missing dependencies"
                    )

    # --------------------------------------------------------
    # Install flows
    # --------------------------------------------------------

    def apply_rice(self) -> None:
        self.install_configs()
        self.install_home_files()
        self.install_wallfliper()
        self.install_scripts()
        self.install_wallpapers()
        self.setup_path()
        self.apply_dconf()

    def do_full_install(self) -> None:
        self.args.fresh = False
        self.args.minimal = False

        self.validate_repo()

        if self.args.no_deps:
            self.info("dependency installation disabled")
        else:
            self.install_deps()

        self.apply_rice()
        self.verify()

        self.summary.extend(
            [
                "Niri desktop installed",
                "Kate installed and configured",
                "Wallfliper installed",
            ]
        )

    def do_minimal_install(self) -> None:
        self.args.fresh = False
        self.args.minimal = True

        self.validate_repo()

        if self.args.no_deps:
            self.info("dependency installation disabled")
        else:
            self.install_deps()

        self.apply_rice()
        self.verify()

        self.summary.append("minimal Niri setup installed")

    def do_update(self) -> None:
        self.args.fresh = False
        self.args.minimal = False

        self.say("updating existing Alice rice")

        self.update_repo()
        self.validate_repo()

        if not self.args.dry_run:
            self.logger.write()
            self.logger.write(
                self.paint(
                    YELLOW + BOLD,
                    "the current repo will be installed over your existing rice.",
                )
            )
            self.info("existing managed files are backed up first.")
            self.info("Waybar and Fastfetch remain untouched.")
            self.logger.write()

            if not self.ask("apply the updated rice?", default=True):
                self.info("update cancelled before applying configs")
                return

        self.apply_rice()
        self.verify()

        self.summary.extend(
            [
                "existing rice updated from the latest repo",
                "latest repo configuration applied",
            ]
        )

    def do_fresh_install(self) -> None:
        self.args.fresh = True
        self.args.minimal = False

        self.validate_repo()

        self.logger.write()
        self.logger.write(
            self.paint(YELLOW + BOLD, "fresh Arch setup")
        )
        self.info(
            "this mode assumes this is a mostly-empty Arch installation."
        )
        self.info(
            "it will install greetd and make it the login manager."
        )
        self.logger.write()

        if not self.args.dry_run:
            if not self.ask("continue with fresh-system setup?", default=True):
                self.info("fresh setup cancelled")
                return

        if self.args.no_deps:
            self.warn(
                "--no-deps was supplied; fresh package installation skipped"
            )
        else:
            self.install_deps()

        self.apply_rice()

        if not self.args.no_deps:
            self.ensure_sudo()
            self.setup_fresh_services()
        else:
            self.warn(
                "greetd setup skipped because dependency installation is disabled"
            )

        self.verify()

        self.summary.extend(
            [
                "fresh Arch desktop installed",
                "Niri installed",
                "Kate installed and configured",
                "Wallfliper installed",
                "greetd + tuigreet configured",
                "NetworkManager + Bluetooth configured",
            ]
        )

        if not self.args.dry_run and not self.args.skip_reboot:
            self.logger.write()
            if self.ask("reboot now?", default=False):
                self.say("rebooting")
                self.run(["systemctl", "reboot"], sudo=True)

    def do_configs_only(self) -> None:
        self.args.fresh = False

        self.validate_repo()
        self.apply_rice()
        self.verify()

        self.summary.extend(
            [
                "desktop configs installed",
                "shell / Kate / theme files installed",
                "Wallfliper installed",
            ]
        )

    def do_packages_only(self) -> None:
        if self.args.no_deps:
            self.warn("--no-deps was supplied; nothing to install")
            return

        self.install_deps()

        if self.args.minimal:
            self.summary.append("core packages installed")
        else:
            self.summary.append("desktop packages installed")

    # --------------------------------------------------------
    # Summary / CLI
    # --------------------------------------------------------

    def summary_screen(self) -> None:
        self.clear()

        print()
        print(
            " "
            + self.paint(PINK, "╭──────────────────────────────────────────────────────╮")
        )
        print(
            " "
            + self.paint(PINK, "│")
            + " "
            + self.paint(GREEN + BOLD, "installation complete")
            + " "
            + self.paint(DIM, ":3")
            + "                       "
            + self.paint(PINK, "│")
        )
        print(
            " "
            + self.paint(PINK, "╰──────────────────────────────────────────────────────╯")
        )
        print()

        for item in self.summary:
            self.success(item)

        self.success("~/.local/bin handled")

        print()
        self.logger.write(
            self.paint(CYAN, "intentionally untouched:")
        )
        self.logger.write("  • ~/.config/waybar")
        self.logger.write("  • ~/.config/fastfetch")
        self.logger.write("  • Kate session files")

        if self.backup_created:
            print()
            self.logger.write(
                self.paint(CYAN, f"backup: {BACKUP}")
            )

        print()
        self.logger.write(
            self.paint(CYAN, f"log: {LOG_FILE}")
        )

        if self.args.fresh:
            print()
            self.logger.write(
                self.paint(WHITE + BOLD, "fresh-system next step:")
            )
            self.logger.write("  • reboot if you did not already reboot")
            self.logger.write("  • log in through tuigreet")
            self.logger.write("  • launch Niri")
        elif self.args.mode == "update":
            print()
            self.logger.write(
                self.paint(WHITE + BOLD, "update next step:")
            )
            self.logger.write("  • restart Niri / Quickshell if needed")
            self.logger.write("  • open a new shell if PATH changed")
        elif self.args.mode == "packages":
            print()
            self.logger.write(
                self.paint(WHITE + BOLD, "next step:")
            )
            self.logger.write("  • restart your shell if PATH changed")
        else:
            print()
            self.logger.write(
                self.paint(WHITE + BOLD, "next step:")
            )
            self.logger.write("  • restart Niri / Quickshell if needed")
            self.logger.write("  • open a new shell if PATH changed")

        print()
        self.logger.write(self.paint(DIM, "have fun rice-ing :3"))

    def run(self) -> int:
        try:
            self.require_arch()

            if self.args.mode != "packages":
                self.bootstrap_repo()

            # Set a useful step count after selecting the actual action.
            if self.args.mode == "fresh":
                self.total_steps = 12
            elif self.args.mode == "update":
                self.total_steps = 10
            elif self.args.mode == "minimal":
                self.total_steps = 9
            elif self.args.mode == "configs":
                self.total_steps = 8
            elif self.args.mode == "packages":
                self.total_steps = 3
            else:
                self.total_steps = 10

            if self.args.mode == "fresh":
                self.do_fresh_install()
            elif self.args.mode == "minimal":
                self.do_minimal_install()
            elif self.args.mode == "update":
                self.do_update()
            elif self.args.mode == "configs":
                self.do_configs_only()
            elif self.args.mode == "packages":
                self.do_packages_only()
            else:
                if self.args.no_tui:
                    self.do_full_install()
                else:
                    choice = self.menu()

                    if choice == 0:
                        self.do_full_install()
                    elif choice == 1:
                        self.args.mode = "update"
                        self.do_update()
                    elif choice == 2:
                        self.args.mode = "fresh"
                        self.do_fresh_install()
                    elif choice == 3:
                        self.args.mode = "minimal"
                        self.do_minimal_install()
                    elif choice == 4:
                        self.args.mode = "configs"
                        self.do_configs_only()
                    elif choice == 5:
                        self.args.mode = "packages"
                        self.do_packages_only()
                    else:
                        self.clear()
                        self.info("bye :3")
                        return 0

            self.summary_screen()
            return 0

        except BaseException as exc:
            self.fail_gracefully(exc)
            return 130 if isinstance(exc, KeyboardInterrupt) else 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Alice's Niri dotfiles installer"
    )

    parser.add_argument(
        "--fresh",
        action="store_true",
        help="fresh Arch setup with greetd + tuigreet",
    )
    parser.add_argument(
        "--minimal",
        action="store_true",
        help="install core Niri environment only",
    )
    parser.add_argument(
        "--update",
        dest="mode",
        action="store_const",
        const="update",
        help="update from local git or latest GitHub snapshot",
    )
    parser.add_argument(
        "--configs-only",
        dest="mode",
        action="store_const",
        const="configs",
        help="install configs without packages",
    )
    parser.add_argument(
        "--packages-only",
        dest="mode",
        action="store_const",
        const="packages",
        help="install packages without configs",
    )
    parser.add_argument(
        "--no-deps",
        action="store_true",
        help="skip package installation",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="show actions without changing the system",
    )
    parser.add_argument(
        "--no-tui",
        action="store_true",
        help="skip the interactive menu",
    )
    parser.add_argument(
        "--yes",
        dest="assume_yes",
        action="store_true",
        help="answer yes to installer prompts",
    )
    parser.add_argument(
        "--no",
        dest="assume_no",
        action="store_true",
        help="decline optional installer prompts",
    )
    parser.add_argument(
        "--skip-reboot",
        action="store_true",
        help="never ask to reboot after fresh setup",
    )
    parser.add_argument(
        "--no-color",
        action="store_true",
        help="disable ANSI colors",
    )
    parser.add_argument(
        "--version",
        action="version",
        version=f"%(prog)s {VERSION}",
    )

    args = parser.parse_args()

    # The parser intentionally stores the chosen mode separately so the
    # TUI can still set it later.
    if not hasattr(args, "mode") or args.mode is None:
        args.mode = "menu"

    if args.fresh:
        args.mode = "fresh"

    if args.minimal and args.mode == "menu":
        args.mode = "minimal"

    if args.assume_yes and args.assume_no:
        parser.error("--yes and --no cannot be used together")

    return args


def main() -> int:
    args = build_parser()
    installer = Installer(args)

    # Make SIGTERM/SIGINT end in a controlled cleanup path.
    def handle_signal(signum: int, _frame: object) -> None:
        raise KeyboardInterrupt

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    try:
        return installer.run()
    finally:
        installer.cleanup()


if __name__ == "__main__":
    raise SystemExit(main())

PYTHON
