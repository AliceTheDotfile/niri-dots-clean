#!/usr/bin/env python3

"""
Alice's Niri dotfiles reverse synchronizer :3

Copies the LIVE rice back into the dotfiles repository.

Normal sync:
    - updates files already tracked by Git
    - adds nothing unrelated
    - does not scan Waybar/Fastfetch
    - does not adopt random ~/.local/bin files
    - does not adopt random wallpapers
    - NEVER syncs ~/.bashrc
    - NEVER syncs ~/.config/niri/parts/output.kdl
    - NEVER syncs ~/.icons/Bibata-Material-Cloud

Adopt-new mode:
    - also finds recently-created files inside managed rice trees
    - only considers files inside directories already represented
      in the Git repository
    - NEVER adopts ~/.config/niri/parts/output.kdl

Usage:
    ./sync.py
        Interactive menu.

    ./sync.py --dry-run
        Show tracked files that would change.

    ./sync.py --discover
        Find possible new rice files.

    ./sync.py --adopt-new
        Sync tracked changes and adopt recent new rice files.

    ./sync.py --prune
        Remove tracked repository files that are missing live.

    ./sync.py --commit
        Sync and create a Git commit.

    ./sync.py --push
        Sync, commit, and push.

    ./sync.py --help
        Show help.

Never managed:
    ~/.bashrc
    ~/.config/waybar
    ~/.config/fastfetch
    ~/.config/niri/parts/output.kdl
    ~/.local/share/kate/anonymous.katesession
    ~/.icons/Bibata-Material-Cloud
    .qmlls.ini
    *.bak
    *.pyc
    *.log
    __pycache__/
"""

from __future__ import annotations

import filecmp
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


# ============================================================
# Paths
# ============================================================

HOME = Path.home()
CONFIG = Path(os.environ.get("XDG_CONFIG_HOME", HOME / ".config"))
SHARE = Path(os.environ.get("XDG_DATA_HOME", HOME / ".local" / "share"))
BIN = HOME / ".local" / "bin"
DOTFILES = Path(__file__).resolve().parent


# ============================================================
# Colors
# ============================================================

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


# ============================================================
# Managed paths
# ============================================================

CONFIG_DIRS = (
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
)

# ~/.bashrc intentionally NOT included.
HOME_FILES = (
    ".bash_profile",
    ".config/kdeglobals",
    ".config/katerc",
    ".config/katevirc",
    ".config/katemetainfos",
    ".local/share/color-schemes/AliceNight.colors",
)

# Bibata-Material-Cloud intentionally NOT included.
HOME_DIRS = (
    ".config/kate",
    ".local/share/themes/AliceNight",
)

QUICKSHELL_SOURCE = CONFIG / "quickshell" / "my-shell"
QUICKSHELL_REPO = DOTFILES / "quickshell" / "my-shell"

WALLFLIPER_SOURCE = SHARE / "wallfliper"
WALLFLIPER_REPO = DOTFILES / "wallfliper"

WALLFLIPER_CONFIG = CONFIG / "wallfliper" / "config.json"

WALLPAPER_SOURCE = HOME / "Wallpapers"
WALLPAPER_REPO = DOTFILES / "Wallpapers"

LOCAL_BIN_SOURCE = BIN
LOCAL_BIN_REPO = DOTFILES / "local" / "bin"


# ============================================================
# Ignore rules
# ============================================================

IGNORE_NAMES = {
    ".qmlls.ini",
    "anonymous.katesession",
    "__pycache__",
    "sync.py",
    ".bashrc",
}

IGNORE_SUFFIXES = {
    ".bak",
    ".pyc",
    ".log",
}

IGNORE_DIRS = {
    ".git",
    "__pycache__",
}


def ignored(path: Path) -> bool:
    return (
        path.name in IGNORE_NAMES
        or path.suffix in IGNORE_SUFFIXES
        or ".git" in path.parts
        or "__pycache__" in path.parts
    )


def is_niri_output(path: Path) -> bool:
    """
    ~/.config/niri/parts/output.kdl is machine-specific.

    It must never be copied into the repository,
    discovered as a new file, updated, or pruned.
    """
    try:
        return (
            path.relative_to(CONFIG / "niri")
            == Path("parts/output.kdl")
        )
    except ValueError:
        return False


def ignored_for_sync(path: Path) -> bool:
    return (
        ignored(path)
        or is_niri_output(path)
    )


# ============================================================
# Output
# ============================================================

def clear_screen() -> None:
    if sys.stdout.isatty():
        print("\033[2J\033[H", end="")


def say(message: str) -> None:
    print(f"{PINK}::{RESET} {message}", flush=True)


def info(message: str) -> None:
    print(f"{CYAN}→{RESET} {message}", flush=True)


def success(message: str) -> None:
    print(f"{GREEN}✓{RESET} {message}", flush=True)


def warn(message: str) -> None:
    print(f"{YELLOW}!{RESET} {message}", flush=True)


def error(message: str) -> None:
    print(
        f"{RED}✗{RESET} {message}",
        file=sys.stderr,
        flush=True,
    )


def pause() -> None:
    try:
        input(
            f"\n{GRAY}"
            "press enter to continue..."
            f"{RESET}"
        )
    except EOFError:
        pass


# ============================================================
# Git helpers
# ============================================================

def git(
    *args: str,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            "git",
            "-C",
            str(DOTFILES),
            *args,
        ],
        text=True,
        capture_output=True,
        check=check,
    )


def git_status() -> str:
    return git(
        "status",
        "--short",
    ).stdout.strip()


def tracked_files() -> set[str]:
    return {
        value
        for value in git(
            "ls-files",
            "-z",
        ).stdout.split("\0")
        if value
    }


def latest_commit_time() -> float:
    result = git(
        "log",
        "-1",
        "--format=%ct",
        check=False,
    )

    try:
        return float(
            result.stdout.strip()
        )
    except ValueError:
        return 0.0


# ============================================================
# Filesystem helpers
# ============================================================

def exists(path: Path) -> bool:
    return path.exists() or path.is_symlink()


def is_file_like(path: Path) -> bool:
    return path.is_file() or path.is_symlink()


def iter_files(root: Path):
    if not exists(root):
        return

    if is_file_like(root):
        if not ignored_for_sync(root):
            yield root
        return

    try:
        for path in root.rglob("*"):
            if ignored_for_sync(path):
                continue

            if is_file_like(path):
                yield path

    except OSError as exc:
        warn(
            f"could not scan {root}: {exc}"
        )


def is_text_file(path: Path) -> bool:
    if not path.is_file():
        return False

    try:
        data = path.read_bytes()[:65536]

        if b"\x00" in data:
            return False

        data.decode("utf-8")
        return True

    except (
        OSError,
        UnicodeDecodeError,
    ):
        return False


def normalized_text(
    path: Path,
) -> str | None:
    if not is_text_file(path):
        return None

    try:
        text = path.read_text(
            encoding="utf-8"
        )
    except (
        OSError,
        UnicodeDecodeError,
    ):
        return None

    return text.replace(
        str(HOME),
        "@HOME@",
    )


def same_file(
    source: Path,
    destination: Path,
) -> bool:
    if not exists(source):
        return False

    if not exists(destination):
        return False

    if (
        source.is_symlink()
        or destination.is_symlink()
    ):
        if (
            not source.is_symlink()
            or not destination.is_symlink()
        ):
            return False

        try:
            return (
                source.readlink()
                == destination.readlink()
            )
        except OSError:
            return False

    source_text = normalized_text(
        source
    )

    destination_text = normalized_text(
        destination
    )

    if (
        source_text is not None
        and destination_text is not None
    ):
        return (
            source_text
            == destination_text
        )

    try:
        return filecmp.cmp(
            source,
            destination,
            shallow=False,
        )
    except OSError:
        return False


# ============================================================
# Change object
# ============================================================

@dataclass
class Change:
    action: str
    source: Path | None
    destination: Path


# ============================================================
# Repository helpers
# ============================================================

def repo_relative(
    path: Path,
) -> str | None:
    try:
        return str(
            path.relative_to(
                DOTFILES
            )
        )
    except ValueError:
        return None


def is_tracked(
    path: Path,
) -> bool:
    relative = repo_relative(path)

    if relative is None:
        return False

    # output.kdl is deliberately unmanaged even if
    # an old copy happens to exist in the repository.
    if relative == "niri/parts/output.kdl":
        return False

    return relative in TRACKED


def parent_tracked(
    path: Path,
) -> bool:
    relative = repo_relative(path)

    if relative is None:
        return False

    # Never allow discovery/adoption of machine-local output.kdl.
    if relative == "niri/parts/output.kdl":
        return False

    parent = (
        str(Path(relative).parent)
        + "/"
    )

    return any(
        item.startswith(parent)
        for item in TRACKED
    )


def recent(
    path: Path,
) -> bool:
    try:
        return (
            path.stat().st_mtime
            >= LATEST_COMMIT
        )
    except OSError:
        return False


def normalize_repo(
    path: Path,
) -> None:
    if (
        not path.is_file()
        or ignored_for_sync(path)
        or not is_text_file(path)
    ):
        return

    # Extra safety: output.kdl should never be normalized
    # because it should never enter the repository.
    if is_niri_output(
        CONFIG / "niri" / path.name
    ):
        return

    try:
        text = path.read_text(
            encoding="utf-8"
        )
    except (
        OSError,
        UnicodeDecodeError,
    ):
        return

    home = str(HOME)

    if home in text:
        path.write_text(
            text.replace(
                home,
                "@HOME@",
            ),
            encoding="utf-8",
        )


# ============================================================
# Directory comparison
# ============================================================

def compare_directory(
    source: Path,
    destination: Path,
    *,
    prune: bool = False,
    adopt_new: bool = False,
) -> list[Change]:

    changes: list[Change] = []

    source_files = {}

    if exists(source):
        source_files = {
            path.relative_to(source): path
            for path in iter_files(source)
        }

    destination_files = {}

    if exists(destination):
        destination_files = {
            path.relative_to(destination): path
            for path in iter_files(destination)
        }

    for relative, source_path in sorted(
        source_files.items()
    ):
        destination_path = (
            destination / relative
        )

        # ====================================================
        # Machine-local Niri output configuration.
        #
        # This is intentionally skipped in every mode:
        #   - normal sync
        #   - adopt-new
        #   - discover
        #   - prune
        # ====================================================

        if (
            source == CONFIG / "niri"
            and relative
            == Path("parts/output.kdl")
        ):
            continue

        if (
            destination == DOTFILES / "niri"
            and relative
            == Path("parts/output.kdl")
        ):
            continue

        if exists(destination_path):
            if not same_file(
                source_path,
                destination_path,
            ):
                changes.append(
                    Change(
                        "update",
                        source_path,
                        destination_path,
                    )
                )

            continue

        if (
            adopt_new
            and parent_tracked(
                destination_path
            )
            and recent(source_path)
        ):
            changes.append(
                Change(
                    "add",
                    source_path,
                    destination_path,
                )
            )

    if prune:
        for relative, destination_path in sorted(
            destination_files.items()
        ):
            source_path = source / relative

            # Never prune Niri's machine-specific output.kdl.
            if (
                destination
                == DOTFILES / "niri"
                and relative
                == Path("parts/output.kdl")
            ):
                continue

            if (
                not exists(source_path)
                and is_tracked(
                    destination_path
                )
            ):
                changes.append(
                    Change(
                        "delete",
                        None,
                        destination_path,
                    )
                )

    return changes


# ============================================================
# Explicit file comparison
# ============================================================

def compare_file(
    source: Path,
    destination: Path,
    *,
    prune: bool = False,
) -> list[Change]:

    # Extra protection for the Niri output file.
    if is_niri_output(source):
        return []

    if (
        repo_relative(destination)
        == "niri/parts/output.kdl"
    ):
        return []

    if exists(source):

        if not exists(destination):
            if is_tracked(destination):
                return [
                    Change(
                        "add",
                        source,
                        destination,
                    )
                ]

            return []

        if not same_file(
            source,
            destination,
        ):
            return [
                Change(
                    "update",
                    source,
                    destination,
                )
            ]

        return []

    if (
        prune
        and exists(destination)
        and is_tracked(destination)
    ):
        return [
            Change(
                "delete",
                None,
                destination,
            )
        ]

    return []


# ============================================================
# Tracked-only special directories
# ============================================================

def compare_tracked_directory(
    source: Path,
    destination: Path,
    *,
    prune: bool = False,
) -> list[Change]:

    changes: list[Change] = []

    if exists(source):
        for source_path in iter_files(
            source
        ):
            relative = (
                source_path.relative_to(
                    source
                )
            )

            destination_path = (
                destination / relative
            )

            if not is_tracked(
                destination_path
            ):
                continue

            if not exists(
                destination_path
            ):
                changes.append(
                    Change(
                        "add",
                        source_path,
                        destination_path,
                    )
                )

            elif not same_file(
                source_path,
                destination_path,
            ):
                changes.append(
                    Change(
                        "update",
                        source_path,
                        destination_path,
                    )
                )

    if (
        prune
        and exists(destination)
    ):
        for destination_path in iter_files(
            destination
        ):
            relative = (
                destination_path.relative_to(
                    destination
                )
            )

            source_path = (
                source / relative
            )

            if (
                not exists(source_path)
                and is_tracked(
                    destination_path
                )
            ):
                changes.append(
                    Change(
                        "delete",
                        None,
                        destination_path,
                    )
                )

    return changes


# ============================================================
# Build plan
# ============================================================

def build_plan(
    *,
    prune: bool = False,
    adopt_new: bool = False,
) -> list[Change]:

    global TRACKED
    global LATEST_COMMIT

    TRACKED = tracked_files()
    LATEST_COMMIT = (
        latest_commit_time()
    )

    say("scanning managed files...")

    changes: list[Change] = []

    #
    # ~/.config
    #
    for name in CONFIG_DIRS:
        changes.extend(
            compare_directory(
                CONFIG / name,
                DOTFILES / name,
                prune=prune,
                adopt_new=adopt_new,
            )
        )

    #
    # Quickshell
    #
    changes.extend(
        compare_directory(
            QUICKSHELL_SOURCE,
            QUICKSHELL_REPO,
            prune=prune,
            adopt_new=adopt_new,
        )
    )

    #
    # Explicit home files.
    #
    # NOTE:
    # ~/.bashrc is intentionally NOT here.
    #
    for item in HOME_FILES:
        changes.extend(
            compare_file(
                HOME / item,
                DOTFILES / "home" / item,
                prune=prune,
            )
        )

    #
    # Explicit home directories.
    #
    # Bibata-Material-Cloud intentionally NOT here.
    #
    for item in HOME_DIRS:
        changes.extend(
            compare_directory(
                HOME / item,
                DOTFILES / "home" / item,
                prune=prune,
                adopt_new=adopt_new,
            )
        )

    #
    # Wallfliper source.
    #
    wall_changes = compare_directory(
        WALLFLIPER_SOURCE,
        WALLFLIPER_REPO,
        prune=prune,
        adopt_new=adopt_new,
    )

    #
    # config.json is managed separately.
    #
    wall_changes = [
        change
        for change in wall_changes
        if change.destination.name
        != "config.json"
    ]

    changes.extend(
        wall_changes
    )

    #
    # Wallfliper config.
    #
    changes.extend(
        compare_file(
            WALLFLIPER_CONFIG,
            WALLFLIPER_REPO
            / "config.json",
            prune=prune,
        )
    )

    #
    # ~/.local/bin:
    # tracked files only.
    #
    changes.extend(
        compare_tracked_directory(
            LOCAL_BIN_SOURCE,
            LOCAL_BIN_REPO,
            prune=prune,
        )
    )

    #
    # Wallpapers:
    # tracked files only.
    #
    changes.extend(
        compare_tracked_directory(
            WALLPAPER_SOURCE,
            WALLPAPER_REPO,
            prune=prune,
        )
    )

    return sorted(
        changes,
        key=lambda change:
            str(change.destination),
    )


# ============================================================
# Discover new files
# ============================================================

def discover_new() -> list[Change]:

    global TRACKED
    global LATEST_COMMIT

    TRACKED = tracked_files()
    LATEST_COMMIT = (
        latest_commit_time()
    )

    say(
        "looking for new rice files..."
    )

    candidates: list[Change] = []

    #
    # Only actual rice/config directories.
    #
    roots = (
        (
            CONFIG / "niri",
            DOTFILES / "niri",
        ),
        (
            QUICKSHELL_SOURCE,
            QUICKSHELL_REPO,
        ),
        (
            CONFIG / "swaync",
            DOTFILES / "swaync",
        ),
        (
            CONFIG / "alice-rice",
            DOTFILES / "alice-rice",
        ),
        (
            CONFIG / "gamearch",
            DOTFILES / "gamearch",
        ),
    )

    for source, destination in roots:
        candidates.extend(
            compare_directory(
                source,
                destination,
                adopt_new=True,
            )
        )

    return candidates


# ============================================================
# dconf
# ============================================================

def dconf_live() -> str | None:
    if shutil.which("dconf") is None:
        return None

    if not os.environ.get(
        "DBUS_SESSION_BUS_ADDRESS"
    ):
        return None

    result = subprocess.run(
        [
            "dconf",
            "dump",
            "/org/gnome/desktop/interface/",
        ],
        text=True,
        capture_output=True,
        check=False,
    )

    if result.returncode != 0:
        return None

    return result.stdout


def sync_dconf(
    live: str | None,
    *,
    dry: bool,
) -> None:

    if live is None:
        return

    destination = (
        DOTFILES
        / "dconf"
        / "interface.ini"
    )

    repo = (
        destination.read_text(
            encoding="utf-8"
        )
        if destination.exists()
        else ""
    )

    if repo == live:
        return

    print()
    print(
        f"    {YELLOW}[UPD]{RESET} "
        "dconf:/org/gnome/desktop/interface/"
    )
    print(
        f"         {GRAY}FROM:{RESET} "
        "dconf:/org/gnome/desktop/interface/"
    )
    print(
        f"         {GRAY}TO:  {RESET} "
        f"{destination}"
    )

    if not dry:
        destination.parent.mkdir(
            parents=True,
            exist_ok=True,
        )

        destination.write_text(
            live,
            encoding="utf-8",
        )


# ============================================================
# Display changes
# ============================================================

def section_for(
    change: Change,
) -> str:

    source = change.source

    if source is None:
        return "repo"

    text = str(source)

    if text.startswith(
        str(CONFIG) + "/"
    ):
        return "~/.config"

    if text.startswith(
        str(BIN) + "/"
    ):
        return "~/.local/bin"

    if text.startswith(
        str(WALLPAPER_SOURCE) + "/"
    ):
        return "~/Wallpapers"

    if text.startswith(
        str(WALLFLIPER_SOURCE) + "/"
    ):
        return "~/.local/share/wallfliper"

    return "~"


def print_change(
    change: Change,
) -> None:

    if change.action == "add":
        label = "ADD"
        color = GREEN

    elif change.action == "update":
        label = "UPD"
        color = YELLOW

    else:
        label = "DEL"
        color = RED

    print(
        f"    {color}"
        f"[{label}]"
        f"{RESET}"
    )

    if change.source is not None:
        print(
            f"         "
            f"{GRAY}FROM:{RESET} "
            f"{change.source}"
        )

    print(
        f"         "
        f"{GRAY}TO:  {RESET} "
        f"{change.destination}"
    )


def print_changes(
    changes: list[Change],
) -> None:

    if not changes:
        print()
        success(
            "no changes detected"
        )
        return

    current = None

    for change in changes:
        section = section_for(
            change
        )

        if section != current:
            print()
            say(
                f"syncing {section}"
            )
            current = section

        print_change(
            change
        )


# ============================================================
# Apply
# ============================================================

def apply_change(
    change: Change,
) -> None:

    # Absolute last line of defense:
    # output.kdl must never be written by this synchronizer.
    if (
        repo_relative(change.destination)
        == "niri/parts/output.kdl"
    ):
        return

    destination = (
        change.destination
    )

    if change.action == "delete":
        if (
            destination.is_dir()
            and not destination.is_symlink()
        ):
            shutil.rmtree(
                destination
            )
        else:
            destination.unlink(
                missing_ok=True
            )

        return

    source = change.source

    if source is None:
        return

    destination.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    if exists(destination):
        if (
            destination.is_dir()
            and not destination.is_symlink()
        ):
            shutil.rmtree(
                destination
            )
        else:
            destination.unlink()

    if source.is_symlink():
        destination.symlink_to(
            source.readlink()
        )
    else:
        shutil.copy2(
            source,
            destination,
        )

        normalize_repo(
            destination
        )


# ============================================================
# Git status
# ============================================================

def show_git_status() -> None:
    print()
    say("repository status")

    status = git_status()

    if status:
        print(status)
    else:
        success(
            "repository is clean"
        )


def make_commit() -> None:
    if not git_status():
        info(
            "nothing to commit"
        )
        return

    git(
        "add",
        "-A",
    )

    result = git(
        "commit",
        "-m",
        "sync: update rice from live system",
        check=False,
    )

    if result.returncode != 0:
        raise RuntimeError(
            result.stderr.strip()
            or "git commit failed"
        )

    success(
        "git commit created"
    )


def push_repo() -> None:
    result = git(
        "push",
        check=False,
    )

    if result.returncode != 0:
        raise RuntimeError(
            result.stderr.strip()
            or "git push failed"
        )

    success(
        "repository pushed"
    )


# ============================================================
# Remote repo -> project folder
# ============================================================

def sync_project_from_remote() -> None:

    clear_screen()

    print()
    print(
        f"{PINK}{BOLD}"
        "sync project folder from remote repo"
        f"{RESET} {DIM}:3{RESET}"
    )

    print(
        f"{GRAY}{DOTFILES}{RESET}"
    )

    print()

    if git_status():
        warn(
            "project folder has uncommitted changes"
        )

        print()
        print(
            git_status()
        )

        print()
        warn(
            "nothing was changed"
        )

        return

    branch = git(
        "branch",
        "--show-current",
    ).stdout.strip()

    if not branch:
        raise RuntimeError(
            "repository is in detached HEAD state"
        )

    upstream = git(
        "rev-parse",
        "--abbrev-ref",
        "--symbolic-full-name",
        "@{u}",
        check=False,
    ).stdout.strip()

    if not upstream:
        raise RuntimeError(
            f"branch '{branch}' has no upstream remote"
        )

    info(
        f"branch: {branch}"
    )

    info(
        f"upstream: {upstream}"
    )

    info(
        "fetching remote..."
    )

    result = git(
        "fetch",
        "--prune",
        check=False,
    )

    if result.returncode != 0:
        raise RuntimeError(
            result.stderr.strip()
            or "git fetch failed"
        )

    local = git(
        "rev-parse",
        "HEAD",
    ).stdout.strip()

    remote = git(
        "rev-parse",
        "@{u}",
    ).stdout.strip()

    if local == remote:
        success(
            "project folder is already up to date :3"
        )
        return

    info(
        "pulling latest changes..."
    )

    result = git(
        "pull",
        "--ff-only",
        check=False,
    )

    if result.returncode != 0:
        raise RuntimeError(
            result.stderr.strip()
            or "git pull failed"
        )

    success(
        "project folder synced from remote repo :3"
    )


# ============================================================
# Sync operation
# ============================================================

def run_sync(
    *,
    dry: bool = False,
    prune: bool = False,
    adopt_new: bool = False,
    commit: bool = False,
    push: bool = False,
) -> None:

    clear_screen()

    print()
    print(
        f"{PINK}{BOLD}"
        "alice's reverse rice sync"
        f"{RESET} {DIM}:3{RESET}"
    )

    print(
        f"{GRAY}"
        "live system → dotfiles repository"
        f"{RESET}"
    )

    if dry:
        print(
            f"{YELLOW}"
            "DRY RUN: nothing will be changed"
            f"{RESET}"
        )

    if adopt_new:
        print(
            f"{CYAN}"
            "ADOPT NEW: recent managed files may be added"
            f"{RESET}"
        )

    if prune:
        print(
            f"{RED}"
            "PRUNE: tracked repo files missing live "
            "can be deleted"
            f"{RESET}"
        )

    print()

    changes = build_plan(
        prune=prune,
        adopt_new=adopt_new,
    )

    print_changes(
        changes
    )

    sync_dconf(
        dconf_live(),
        dry=dry,
    )

    if dry:
        print()
        success(
            f"dry-run finished: "
            f"{len(changes)} file change(s)"
        )
        return

    for change in changes:
        apply_change(
            change
        )

    print()
    show_git_status()

    if commit:
        print()
        make_commit()

    if push:
        print()
        push_repo()

    print()
    success(
        "reverse sync finished :3"
    )


# ============================================================
# Menu
# ============================================================

MENU = (
    ("1", "sync tracked changes"),
    ("2", "sync + adopt new rice files"),
    ("3", "discover new rice files"),
    ("4", "dry-run tracked changes"),
    ("5", "sync + commit"),
    ("6", "sync + commit + push"),
    ("7", "sync + prune tracked files"),
    ("8", "show git status"),
    ("9", "sync project folder from remote repo"),
    ("10", "exit"),
)


def show_menu() -> None:
    clear_screen()

    print()
    print(
        f"{PINK}"
        "╭──────────────────────────────────────────────╮"
        f"{RESET}"
    )

    print(
        f"{PINK}│{RESET} "
        f"{WHITE}{BOLD}"
        "alice's reverse rice sync"
        f"{RESET} {DIM}:3{RESET}"
    )

    print(
        f"{PINK}│{RESET} "
        f"{GRAY}"
        "live system → dotfiles repository"
        f"{RESET}"
    )

    print(
        f"{PINK}"
        "╰──────────────────────────────────────────────╯"
        f"{RESET}"
    )

    print()

    print(
        f"{PURPLE}{BOLD}"
        "what should i do?"
        f"{RESET}"
    )

    print()

    for number, label in MENU:
        print(
            f"  {PINK}{number:>2}{RESET}  "
            f"{label}"
        )

    print()


def interactive() -> None:

    while True:
        show_menu()

        try:
            choice = input(
                f"{WHITE}choice: {RESET}"
            ).strip()

        except (
            EOFError,
            KeyboardInterrupt,
        ):
            print()
            info(
                "bye :3"
            )
            return

        try:
            if choice == "1":
                run_sync()

            elif choice == "2":
                run_sync(
                    adopt_new=True
                )

            elif choice == "3":
                clear_screen()

                print()
                print(
                    f"{PINK}{BOLD}"
                    "new rice file discovery"
                    f"{RESET} {DIM}:3{RESET}"
                )

                print()

                candidates = (
                    discover_new()
                )

                print_changes(
                    candidates
                )

                pause()
                continue

            elif choice == "4":
                run_sync(
                    dry=True
                )

            elif choice == "5":
                run_sync(
                    commit=True
                )

            elif choice == "6":
                run_sync(
                    commit=True,
                    push=True,
                )

            elif choice == "7":
                run_sync(
                    prune=True
                )

            elif choice == "8":
                clear_screen()
                show_git_status()

            elif choice == "9":
                sync_project_from_remote()

            elif choice in {
                "10",
                "q",
                "Q",
            }:
                clear_screen()
                info(
                    "bye :3"
                )
                return

            else:
                warn(
                    "please enter 1-10"
                )

        except Exception as exc:
            error(
                str(exc)
            )

        pause()


# ============================================================
# CLI
# ============================================================

def print_help() -> None:
    print(__doc__)


def handle_cli(
    args: list[str],
) -> bool:

    if not args:
        return False

    if (
        "--help" in args
        or "-h" in args
    ):
        print_help()
        return True

    valid = {
        "--dry-run",
        "--discover",
        "--adopt-new",
        "--prune",
        "--commit",
        "--push",
    }

    unknown = [
        arg
        for arg in args
        if arg not in valid
    ]

    if unknown:
        raise RuntimeError(
            f"unknown option: {unknown[0]}"
        )

    if "--discover" in args:
        run_discover_cli()
        return True

    run_sync(
        dry="--dry-run" in args,
        prune="--prune" in args,
        adopt_new="--adopt-new" in args,
        commit=(
            "--commit" in args
            or "--push" in args
        ),
        push="--push" in args,
    )

    return True


def run_discover_cli() -> None:
    clear_screen()

    print()
    print(
        f"{PINK}{BOLD}"
        "new rice file discovery"
        f"{RESET} {DIM}:3{RESET}"
    )

    print()

    candidates = discover_new()

    print_changes(
        candidates
    )


# ============================================================
# Validation
# ============================================================

def validate() -> None:

    if os.geteuid() == 0:
        raise RuntimeError(
            "do not run this script as root"
        )

    if shutil.which("git") is None:
        raise RuntimeError(
            "git is required"
        )

    if not (
        DOTFILES / ".git"
    ).exists():
        raise RuntimeError(
            "this script must be inside "
            "your dotfiles git repository"
        )


# ============================================================
# Main
# ============================================================

def main() -> int:

    try:
        validate()

        if handle_cli(
            sys.argv[1:]
        ):
            return 0

        interactive()
        return 0

    except KeyboardInterrupt:
        print()
        info(
            "cancelled :3"
        )
        return 130

    except subprocess.CalledProcessError as exc:
        error(
            exc.stderr.strip()
            if exc.stderr
            else "command failed"
        )

        return (
            exc.returncode
            or 1
        )

    except Exception as exc:
        error(
            str(exc)
        )

        return 1


if __name__ == "__main__":
    raise SystemExit(
        main()
    )
