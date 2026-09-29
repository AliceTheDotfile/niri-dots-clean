#!/usr/bin/env python3
"""
Alice's Niri reverse rice sync :3

LIVE SYSTEM -> DOTFILES REPOSITORY

Normal sync:
    * updates only managed/tracked files
    * never touches Waybar or Fastfetch config
    * never syncs ~/.bashrc
    * never syncs ~/.config/niri/parts/output.kdl
    * never syncs ~/.icons/Bibata-Material-Cloud
    * never adopts random ~/.local/bin files
    * never adopts random wallpapers
    * never commits unrelated pre-existing repository changes
      (including files that were already staged)

Adopt-new mode:
    * discovers recently-created files inside already represented repo trees
    * still excludes machine-specific / ignored files

Remote handling:
    * fetches before push
    * only stashes unrelated working-tree changes when the branch actually
      has to be fast-forwarded / rebased / reset
    * restores the stash with `stash apply` and rolls back cleanly on a
      conflict, so conflict markers are never left in your files
    * refuses to commit/push while the index has unresolved merge conflicts
    * detects remote-ahead/diverged branches
    * reconciles old sync-only commits using managed-path diffs
    * safely removes accidental unrelated files from old sync commits
    * rebases normal local commits when appropriate
    * retries once when the remote changes during a push
    * never force-pushes

Usage:
    ./sync.py
    ./sync.py --dry-run
    ./sync.py --discover
    ./sync.py --adopt-new
    ./sync.py --prune
    ./sync.py --commit
    ./sync.py --push
    ./sync.py --remote-sync
    ./sync.py --help
"""

from __future__ import annotations

import filecmp
import os
import shutil
import subprocess
import sys
import tempfile
import time
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

SYNC_COMMIT_MESSAGE = "sync: update rice from live system"


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

HOME_FILES = (
    ".bash_profile",
    ".config/kdeglobals",
    ".config/katerc",
    ".config/katevirc",
    ".config/katemetainfos",
    ".local/share/color-schemes/AliceNight.colors",
)

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

# Populated by build_plan() / discover_new().
TRACKED: set[str] = set()
LATEST_COMMIT: float = 0.0


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


def is_niri_output(path: Path) -> bool:
    """The machine-specific Niri output file is always unmanaged."""
    try:
        return path.resolve(strict=False) == (
            CONFIG / "niri" / "parts" / "output.kdl"
        ).resolve(strict=False)
    except OSError:
        return False


def ignored(path: Path) -> bool:
    if path.name in IGNORE_NAMES:
        return True
    if path.suffix in IGNORE_SUFFIXES:
        return True
    if ".git" in path.parts:
        return True
    if "__pycache__" in path.parts:
        return True
    if is_niri_output(path):
        return True
    return False


# ============================================================
# Output
# ============================================================

COLOR = sys.stdout.isatty()


def c(color: str, text: str) -> str:
    return f"{color}{text}{RESET}" if COLOR else text


def clear_screen() -> None:
    if COLOR:
        print("\033[2J\033[H", end="")


def say(message: str) -> None:
    print(f"{c(PINK, '::')} {message}", flush=True)


def info(message: str) -> None:
    print(f"{c(CYAN, '→')} {message}", flush=True)


def success(message: str) -> None:
    print(f"{c(GREEN, '✓')} {message}", flush=True)


def warn(message: str) -> None:
    print(f"{c(YELLOW, '!')} {message}", flush=True)


def error(message: str) -> None:
    print(f"{c(RED, '✗')} {message}", file=sys.stderr, flush=True)


def pause() -> None:
    try:
        input(f"\n{c(GRAY, 'press enter to continue...')}")
    except (EOFError, KeyboardInterrupt):
        pass


# ============================================================
# Git helpers
# ============================================================


def git(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        ["git", "-C", str(DOTFILES), *args],
        text=True,
        capture_output=True,
        check=False,
    )
    if check and result.returncode != 0:
        message = (result.stderr or result.stdout).strip()
        raise RuntimeError(message or f"git {' '.join(args)} failed")
    return result


def git_live(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    command = ["git", "-C", str(DOTFILES), *args]
    info("git " + " ".join(args))
    result = subprocess.run(command, text=True, check=False)
    if check and result.returncode != 0:
        raise RuntimeError(
            f"git {' '.join(args)} failed with exit code {result.returncode}"
        )
    return result


def git_status() -> str:
    return git("status", "--short").stdout.strip()


def git_status_paths() -> set[str]:
    result = git("status", "--porcelain=v1", "-z")
    raw = result.stdout
    paths: set[str] = set()
    parts = raw.split("\0")

    i = 0
    while i < len(parts):
        entry = parts[i]
        if not entry:
            i += 1
            continue

        # Normal v1 entry: XY<space>path
        path = entry[3:] if len(entry) >= 4 else ""
        if path:
            paths.add(path)

        # Rename/copy entries have the original path as the next NUL item.
        status_code = entry[:2]
        if status_code[0] in {"R", "C"} or status_code[1] in {"R", "C"}:
            if i + 1 < len(parts) and parts[i + 1]:
                paths.add(parts[i + 1])
            i += 1

        i += 1

    return paths


def unmerged_paths() -> list[str]:
    """Paths with unresolved merge conflicts in the index (UU, AA, ...)."""
    result = git("ls-files", "--unmerged", "-z", check=False)
    if result.returncode != 0:
        return []

    paths: set[str] = set()
    for entry in result.stdout.split("\0"):
        if not entry:
            continue
        # "<mode> <sha> <stage>\t<path>"
        _, _, path = entry.partition("\t")
        if path:
            paths.add(path)

    return sorted(paths)


def unmerged_message(paths: list[str]) -> str:
    listing = ", ".join(paths)
    return (
        f"unresolved merge conflicts in: {listing}\n"
        "    fix the files (remove any <<<<<<< / ======= / >>>>>>> markers),\n"
        "    run `git add <file>` for each one, then re-run sync"
    )


def ensure_no_unmerged() -> None:
    paths = unmerged_paths()
    if paths:
        raise RuntimeError(unmerged_message(paths))


def tracked_files() -> set[str]:
    result = git("ls-files", "-z")
    return {item for item in result.stdout.split("\0") if item}


def current_branch() -> str:
    return git("branch", "--show-current").stdout.strip()


def upstream_ref() -> str | None:
    result = git(
        "rev-parse",
        "--abbrev-ref",
        "--symbolic-full-name",
        "@{u}",
        check=False,
    )
    if result.returncode != 0:
        return None
    value = result.stdout.strip()
    return value or None


def remote_counts() -> tuple[int, int]:
    """Return (behind, ahead) relative to the configured upstream."""
    result = git(
        "rev-list",
        "--left-right",
        "--count",
        "HEAD...@{u}",
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError("could not determine local/remote divergence")

    fields = result.stdout.strip().split()
    if len(fields) != 2:
        raise RuntimeError("could not parse local/remote divergence")

    # left = local-only (ahead), right = remote-only (behind)
    ahead = int(fields[0])
    behind = int(fields[1])
    return behind, ahead


def latest_commit_time() -> float:
    result = git("log", "-1", "--format=%ct", check=False)
    try:
        return float(result.stdout.strip())
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
        if not ignored(root):
            yield root
        return

    try:
        for path in root.rglob("*"):
            if ignored(path):
                continue
            if is_file_like(path):
                yield path
    except OSError as exc:
        warn(f"could not scan {root}: {exc}")


def is_text_file(path: Path) -> bool:
    if not path.is_file():
        return False
    try:
        data = path.read_bytes()[:65536]
        if b"\x00" in data:
            return False
        data.decode("utf-8")
        return True
    except (OSError, UnicodeDecodeError):
        return False


def normalized_text(path: Path) -> str | None:
    if not is_text_file(path):
        return None
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return None
    return text.replace(str(HOME), "@HOME@")


def same_file(source: Path, destination: Path) -> bool:
    if not exists(source) or not exists(destination):
        return False

    if source.is_symlink() or destination.is_symlink():
        if not source.is_symlink() or not destination.is_symlink():
            return False
        try:
            return source.readlink() == destination.readlink()
        except OSError:
            return False

    source_text = normalized_text(source)
    destination_text = normalized_text(destination)

    if source_text is not None and destination_text is not None:
        return source_text == destination_text

    try:
        return filecmp.cmp(source, destination, shallow=False)
    except OSError:
        return False


# ============================================================
# Change object
# ============================================================


@dataclass(frozen=True)
class Change:
    action: str
    source: Path | None
    destination: Path


# ============================================================
# Repository helpers
# ============================================================


def repo_relative(path: Path) -> str | None:
    try:
        return path.relative_to(DOTFILES).as_posix()
    except ValueError:
        return None


def is_tracked(path: Path) -> bool:
    relative = repo_relative(path)
    return relative is not None and relative in TRACKED


def parent_tracked(path: Path) -> bool:
    relative = repo_relative(path)
    if relative is None or relative == "niri/parts/output.kdl":
        return False

    parent = Path(relative).parent.as_posix()
    prefix = "" if parent == "." else parent + "/"

    return any(item.startswith(prefix) for item in TRACKED)


def recent(path: Path) -> bool:
    try:
        return path.stat().st_mtime >= LATEST_COMMIT
    except OSError:
        return False


def should_skip_destination(path: Path) -> bool:
    relative = repo_relative(path)
    return (
        relative == "niri/parts/output.kdl"
        or ignored(path)
    )


# ============================================================
# Comparison
# ============================================================


def compare_directory(
    source: Path,
    destination: Path,
    *,
    prune: bool = False,
    adopt_new: bool = False,
    tracked_only: bool = False,
) -> list[Change]:
    changes: list[Change] = []

    source_files: dict[Path, Path] = {}
    destination_files: dict[Path, Path] = {}

    if exists(source):
        source_files = {
            path.relative_to(source): path
            for path in iter_files(source)
        }

    if exists(destination):
        destination_files = {
            path.relative_to(destination): path
            for path in iter_files(destination)
        }

    for relative, source_path in sorted(source_files.items()):
        destination_path = destination / relative

        if should_skip_destination(destination_path):
            continue

        if tracked_only and not is_tracked(destination_path):
            continue

        if exists(destination_path):
            if not same_file(source_path, destination_path):
                changes.append(Change("update", source_path, destination_path))
            continue

        if adopt_new and parent_tracked(destination_path) and recent(source_path):
            changes.append(Change("add", source_path, destination_path))

    if prune and exists(destination):
        for relative, destination_path in sorted(destination_files.items()):
            source_path = source / relative

            if should_skip_destination(destination_path):
                continue

            if tracked_only and not is_tracked(destination_path):
                continue

            if not exists(source_path) and is_tracked(destination_path):
                changes.append(Change("delete", None, destination_path))

    return changes


def compare_file(
    source: Path,
    destination: Path,
    *,
    prune: bool = False,
) -> list[Change]:
    if should_skip_destination(destination):
        return []

    if exists(source):
        if not exists(destination):
            if is_tracked(destination):
                return [Change("add", source, destination)]
            return []

        if not same_file(source, destination):
            return [Change("update", source, destination)]

        return []

    if prune and exists(destination) and is_tracked(destination):
        return [Change("delete", None, destination)]

    return []


# ============================================================
# Plan
# ============================================================


def build_plan(*, prune: bool = False, adopt_new: bool = False) -> list[Change]:
    global TRACKED, LATEST_COMMIT
    TRACKED = tracked_files()
    LATEST_COMMIT = latest_commit_time()

    say("scanning managed files...")

    changes: list[Change] = []

    for name in CONFIG_DIRS:
        changes.extend(
            compare_directory(
                CONFIG / name,
                DOTFILES / name,
                prune=prune,
                adopt_new=adopt_new,
            )
        )

    changes.extend(
        compare_directory(
            QUICKSHELL_SOURCE,
            QUICKSHELL_REPO,
            prune=prune,
            adopt_new=adopt_new,
        )
    )

    for item in HOME_FILES:
        changes.extend(
            compare_file(
                HOME / item,
                DOTFILES / "home" / item,
                prune=prune,
            )
        )

    for item in HOME_DIRS:
        changes.extend(
            compare_directory(
                HOME / item,
                DOTFILES / "home" / item,
                prune=prune,
                adopt_new=adopt_new,
            )
        )

    wall_changes = compare_directory(
        WALLFLIPER_SOURCE,
        WALLFLIPER_REPO,
        prune=prune,
        adopt_new=adopt_new,
    )
    changes.extend(
        change
        for change in wall_changes
        if change.destination.name != "config.json"
    )

    changes.extend(
        compare_file(
            WALLFLIPER_CONFIG,
            WALLFLIPER_REPO / "config.json",
            prune=prune,
        )
    )

    changes.extend(
        compare_directory(
            LOCAL_BIN_SOURCE,
            LOCAL_BIN_REPO,
            prune=prune,
            tracked_only=True,
        )
    )

    changes.extend(
        compare_directory(
            WALLPAPER_SOURCE,
            WALLPAPER_REPO,
            prune=prune,
            tracked_only=True,
        )
    )

    return sorted(changes, key=lambda change: str(change.destination))


# ============================================================
# Discovery
# ============================================================


def discover_new() -> list[Change]:
    global TRACKED, LATEST_COMMIT
    TRACKED = tracked_files()
    LATEST_COMMIT = latest_commit_time()

    say("looking for new rice files...")

    roots = (
        (CONFIG / "niri", DOTFILES / "niri"),
        (QUICKSHELL_SOURCE, QUICKSHELL_REPO),
        (CONFIG / "swaync", DOTFILES / "swaync"),
        (CONFIG / "alice-rice", DOTFILES / "alice-rice"),
        (CONFIG / "gamearch", DOTFILES / "gamearch"),
        (CONFIG / "kate", DOTFILES / "home" / ".config" / "kate"),
    )

    candidates: list[Change] = []
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
    if not os.environ.get("DBUS_SESSION_BUS_ADDRESS"):
        return None

    result = subprocess.run(
        ["dconf", "dump", "/org/gnome/desktop/interface/"],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        return None
    return result.stdout


def dconf_change(live: str | None) -> Change | None:
    if live is None:
        return None

    destination = DOTFILES / "dconf" / "interface.ini"
    existing = destination.read_text(encoding="utf-8") if destination.exists() else ""

    if existing == live:
        return None

    # The Change source expects a real file. It is only used while applying,
    # then removed by apply_dconf_change (or on dry-run / skip).
    try:
        fd, temp_name = tempfile.mkstemp(prefix="alice-dconf-sync-", suffix=".ini")
        with os.fdopen(fd, "w", encoding="utf-8") as fp:
            fp.write(live)
    except OSError as exc:
        raise RuntimeError(f"could not prepare dconf sync: {exc}") from exc

    return Change("update", Path(temp_name), destination)


# ============================================================
# Display
# ============================================================


def section_for(change: Change) -> str:
    source = change.source
    if source is None:
        return "repo"

    text = str(source)
    if text.startswith(str(CONFIG) + os.sep):
        return "~/.config"
    if text.startswith(str(BIN) + os.sep):
        return "~/.local/bin"
    if text.startswith(str(WALLPAPER_SOURCE) + os.sep):
        return "~/Wallpapers"
    if text.startswith(str(WALLFLIPER_SOURCE) + os.sep):
        return "~/.local/share/wallfliper"
    return "~"


def print_change(change: Change) -> None:
    if change.action == "add":
        label, color = "ADD", GREEN
    elif change.action == "update":
        label, color = "UPD", YELLOW
    else:
        label, color = "DEL", RED

    print(f"    {c(color, '[' + label + ']')}")
    if change.source is not None:
        print(f"         {c(GRAY, 'FROM:')} {change.source}")
    print(f"         {c(GRAY, 'TO:  ')} {change.destination}")


def print_changes(changes: list[Change]) -> None:
    if not changes:
        print()
        success("no changes detected")
        return

    current = None
    for change in changes:
        section = section_for(change)
        if section != current:
            print()
            say(f"syncing {section}")
            current = section
        print_change(change)


# ============================================================
# Safety around pre-existing repo changes
# ============================================================


def filter_conflicts(
    changes: list[Change],
    initial_dirty: set[str],
) -> list[Change]:
    if not initial_dirty:
        return changes

    allowed: list[Change] = []
    for change in changes:
        relative = repo_relative(change.destination)
        if relative in initial_dirty:
            warn(
                f"skipping {relative}: repository file already had local changes"
            )
            continue
        allowed.append(change)

    return allowed


# ============================================================
# Apply
# ============================================================


def apply_change(change: Change) -> None:
    destination = change.destination

    if should_skip_destination(destination):
        return

    if change.action == "delete":
        if destination.is_dir() and not destination.is_symlink():
            shutil.rmtree(destination)
        else:
            destination.unlink(missing_ok=True)
        return

    if change.source is None:
        return

    destination.parent.mkdir(parents=True, exist_ok=True)

    if exists(destination):
        if destination.is_dir() and not destination.is_symlink():
            shutil.rmtree(destination)
        else:
            destination.unlink()

    source = change.source
    if source.is_symlink():
        destination.symlink_to(source.readlink())
    elif source.is_file():
        shutil.copy2(source, destination)
    else:
        raise RuntimeError(f"unsupported sync source: {source}")

    # The live system's $HOME is portable only as @HOME@ inside the repo.
    if destination.is_file() and is_text_file(destination):
        text = destination.read_text(encoding="utf-8")
        home = str(HOME)
        if home in text:
            destination.write_text(text.replace(home, "@HOME@"), encoding="utf-8")


def apply_dconf_change(change: Change) -> None:
    source = change.source
    destination = change.destination
    if source is None:
        return

    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(source.read_text(encoding="utf-8"), encoding="utf-8")
    source.unlink(missing_ok=True)


# ============================================================
# Commit only what this run changed
# ============================================================


def make_commit(changes: list[Change], dconf: Change | None) -> bool:
    paths: list[str] = []

    for change in changes:
        relative = repo_relative(change.destination)
        if relative is not None:
            paths.append(relative)

    if dconf is not None:
        relative = repo_relative(dconf.destination)
        if relative is not None:
            paths.append(relative)

    paths = sorted(set(paths))

    if not paths:
        info("this sync produced no repository changes to commit")
        return False

    ensure_no_unmerged()

    git("add", "-A", "--", *paths)

    # Only the paths this sync actually changed.
    ours = [
        p
        for p in git(
            "diff", "--cached", "--name-only", "-z", "--", *paths
        ).stdout.split("\0")
        if p
    ]

    if not ours:
        info("nothing from this sync is staged")
        return False

    everything_staged = {
        p
        for p in git("diff", "--cached", "--name-only", "-z").stdout.split("\0")
        if p
    }
    foreign = everything_staged - set(ours)
    if foreign:
        warn(
            f"{len(foreign)} unrelated file(s) were already staged; "
            "they will NOT be part of the sync commit:"
        )
        for path in sorted(foreign):
            print(f"    {c(GRAY, path)}")

    print()
    say("creating sync commit")
    info(f"git commit --only ({len(ours)} synced file(s))")

    # `--only -- <paths>` commits exactly those paths and leaves everything
    # else that is staged untouched. A bare `git commit` would sweep in every
    # staged file, which is how unrelated files leaked into old sync commits.
    result = git("commit", "-m", SYNC_COMMIT_MESSAGE, "--only", "--", *ours)
    if result.stdout.strip():
        print(result.stdout.rstrip())

    success("git commit created")
    return True


# ============================================================
# Remote synchronization
# ============================================================


def fetch_remote() -> None:
    say("fetching remote...")
    result = git_live("fetch", "--prune", check=False)
    if result.returncode != 0:
        raise RuntimeError("git fetch failed")


def stash_worktree_for_git_operation() -> str | None:
    """
    Temporarily stash pre-existing worktree changes so merge/rebase/reset can
    operate on a clean checkout.

    The stash includes untracked files. It does not include ignored files.
    Returns the stash object id when something was stashed.
    """
    ensure_no_unmerged()

    if not git_status():
        return None

    info("temporarily stashing existing repository changes...")
    info("your local changes will NOT be committed")

    result = git_live(
        "stash",
        "push",
        "--include-untracked",
        "-m",
        "alice-sync temporary worktree protection",
        check=False,
    )

    if result.returncode != 0:
        raise RuntimeError(
            "could not temporarily stash existing repository changes"
        )

    stash = git(
        "stash",
        "list",
        "-1",
        "--format=%H",
        check=False,
    )

    stash_hash = stash.stdout.strip()
    if stash.returncode != 0 or not stash_hash:
        raise RuntimeError(
            "temporary stash was created but could not be verified"
        )

    success("existing repository changes safely stashed")
    return stash_hash


def find_stash_ref(stash_hash: str) -> str | None:
    result = git("stash", "list", "--format=%gd %H", check=False)
    for line in result.stdout.splitlines():
        ref, _, value = line.partition(" ")
        if value.strip() == stash_hash:
            return ref
    return None


def rollback_failed_apply() -> None:
    """
    Undo a partially-applied (conflicted) stash.

    This is only called when the worktree was completely clean before the
    apply, so everything present now was put there by the failed apply. The
    stash itself is kept, so nothing is lost.
    """
    git("reset", "--hard", "HEAD", check=False)
    git("clean", "-fd", check=False)


def restore_worktree_stash(stash_hash: str | None) -> None:
    """
    Restore the temporary stash.

    Uses `stash apply` + `stash drop` instead of `stash pop`: a conflicted
    pop writes <<<<<<< markers into your files and leaves them unmerged,
    which then blocks every later stash/commit. On any failure the worktree
    is rolled back to clean and the stash is kept.
    """
    if not stash_hash:
        return

    print()
    info("restoring your pre-existing repository changes...")

    ref = find_stash_ref(stash_hash)
    if ref is None:
        warn("temporary stash could not be found in the stash list")
        warn(f"if your changes are missing, look for commit {stash_hash}")
        return

    if git_status():
        warn("repository is not clean; not restoring automatically")
        warn(f"your changes remain safely stored in {ref} ({stash_hash})")
        return

    for flags in (("--index",), ()):
        result = git("stash", "apply", *flags, ref, check=False)
        if result.returncode == 0:
            git("stash", "drop", ref, check=False)
            success("pre-existing repository changes restored")
            return

        rollback_failed_apply()

    warn("your local changes could not be restored cleanly")
    warn("the repository was left clean; nothing was lost")
    warn(f"your changes are kept in {ref} ({stash_hash})")
    warn("inspect with `git stash show -p`, restore with `git stash apply`")


def managed_repo_paths() -> list[str]:
    """Return repository-relative paths owned by the reverse synchronizer."""
    paths: list[str] = []

    paths.extend(CONFIG_DIRS)
    paths.append("quickshell/my-shell")
    paths.append("wallfliper")
    paths.append("dconf/interface.ini")
    paths.append("local/bin")
    paths.append("Wallpapers")

    paths.extend(f"home/{item}" for item in HOME_FILES)
    paths.extend(f"home/{item}" for item in HOME_DIRS)

    return list(dict.fromkeys(paths))


def local_sync_commits() -> list[tuple[str, str]]:
    """Return local-only commits as (sha, subject), oldest first."""
    result = git(
        "log",
        "--reverse",
        "--format=%H%x09%s",
        "@{u}..HEAD",
        check=False,
    )

    if result.returncode != 0:
        raise RuntimeError("could not inspect local commits")

    commits: list[tuple[str, str]] = []
    for line in result.stdout.splitlines():
        if "\t" not in line:
            continue
        sha, subject = line.split("\t", 1)
        commits.append((sha, subject))

    return commits


def make_recovery_ref() -> str:
    stamp = str(int(time.time()))
    ref = f"refs/alice-sync/recovery-{stamp}"
    git("update-ref", ref, "HEAD")
    return ref


def restore_branch_from_ref(ref: str) -> None:
    git_live("reset", "--hard", ref)


def rewrite_old_sync_history() -> bool:
    """
    Repair an old reverse-sync commit that accidentally committed unrelated
    repository files.

    A sync commit is reconstructed from the net diff of all local-only
    sync commits, restricted to managed repository paths. This deliberately
    excludes files such as install.sh, README.md, install.py, and sync.py.

    Returns True when the branch was rewritten, otherwise False.
    """
    commits = local_sync_commits()
    if not commits:
        return False

    if not all(subject.startswith(SYNC_COMMIT_MESSAGE) for _, subject in commits):
        return False

    merge_base = git(
        "merge-base",
        "HEAD",
        "@{u}",
    ).stdout.strip()
    if not merge_base:
        raise RuntimeError("could not determine the branch merge base")

    pathspecs = managed_repo_paths()
    diff_pathspecs = [
        *pathspecs,
        ":(exclude)niri/parts/output.kdl",
    ]

    diff = git(
        "diff",
        "--binary",
        "--no-ext-diff",
        merge_base,
        "HEAD",
        "--",
        *diff_pathspecs,
    ).stdout

    recovery_ref = make_recovery_ref()
    info(f"saved old local history at {recovery_ref}")

    info("discarding unrelated files from old sync history")
    git_live("reset", "--hard", "@{u}")

    if not diff.strip():
        success(
            "old sync commit contained no managed changes; local branch aligned with remote"
        )
        info(f"recovery ref retained: {recovery_ref}")
        return True

    info("reapplying managed changes from the old sync commit")

    result = subprocess.run(
        [
            "git",
            "-C",
            str(DOTFILES),
            "apply",
            "--3way",
            "--index",
            "-",
        ],
        input=diff,
        text=True,
        capture_output=True,
        check=False,
    )

    if result.returncode != 0:
        restore_branch_from_ref(recovery_ref)
        message = (result.stderr or result.stdout).strip()
        raise RuntimeError(
            "could not safely reapply managed changes from the old sync "
            + (f"commit: {message}" if message else "commit")
            + f"; repository restored from {recovery_ref}"
        )

    staged = git(
        "diff",
        "--cached",
        "--name-only",
    ).stdout.splitlines()

    allowed = set(pathspecs)
    if any(
        not any(path == spec or path.startswith(spec.rstrip("/") + "/")
                for spec in allowed)
        for path in staged
    ):
        # This should never happen because the patch was path-limited, but
        # keep a belt-and-suspenders check before creating a new commit.
        restore_branch_from_ref(recovery_ref)
        raise RuntimeError(
            "managed-history repair selected an unexpected repository path; "
            f"repository restored from {recovery_ref}"
        )

    git_live(
        "commit",
        "-m",
        SYNC_COMMIT_MESSAGE,
    )

    success("old sync history rebuilt using managed files only")
    info(f"recovery ref retained: {recovery_ref}")
    return True


def integrate_remote() -> None:
    upstream = upstream_ref()
    if upstream is None:
        branch = current_branch()
        if not branch:
            raise RuntimeError("repository is in detached HEAD state")
        warn(f"branch '{branch}' has no upstream remote")
        return

    behind, ahead = remote_counts()
    info(f"remote status: {ahead} ahead locally, {behind} behind remote")

    if behind == 0:
        return

    if ahead == 0:
        say("fast-forwarding local repository")
        git_live("merge", "--ff-only", "@{u}")
        success("local repository fast-forwarded")
        return

    # Old versions of this synchronizer could accidentally create a
    # `sync:` commit containing every dirty repository file. If that old
    # commit is all the local branch has, repair it from managed paths rather
    # than trying to rebase unrelated installer/docs files.
    if rewrite_old_sync_history():
        return

    say("remote contains commits not in the local branch")
    info("rebasing local commits onto the remote branch...")

    result = git_live(
        "rebase",
        "@{u}",
        check=False,
    )

    if result.returncode != 0:
        abort = git_live(
            "rebase",
            "--abort",
            check=False,
        )
        if abort.returncode == 0:
            warn("automatic rebase could not reconcile the branches")
            warn("the rebase was safely aborted")
        else:
            warn("rebase failed and Git could not automatically abort it")
        raise RuntimeError("git rebase failed")

    success("local commits rebased onto remote")


def push_repo() -> None:
    ensure_no_unmerged()

    upstream = upstream_ref()

    if upstream is None:
        branch = current_branch()
        if not branch:
            raise RuntimeError("repository is in detached HEAD state")

        remotes = git("remote").stdout.splitlines()
        if not remotes:
            raise RuntimeError("repository has no configured git remote")

        remote = remotes[0].strip()

        # Pushing a new upstream never touches the worktree, so there is no
        # reason to stash anything here.
        say(f"setting upstream: {remote}/{branch}")
        result = git_live(
            "push",
            "-u",
            remote,
            branch,
            check=False,
        )
        if result.returncode != 0:
            raise RuntimeError("git push failed")

        success("repository pushed")
        return

    for attempt in range(2):
        fetch_remote()
        behind, _ahead = remote_counts()

        stash_hash: str | None = None
        try:
            # Only touch the worktree (stash) when the branch really has to
            # be fast-forwarded, rebased or rebuilt.
            if behind:
                stash_hash = stash_worktree_for_git_operation()
                integrate_remote()

            say("pushing to GitHub...")
            result = git_live("push", check=False)
        finally:
            restore_worktree_stash(stash_hash)

        if result.returncode == 0:
            success("repository pushed")
            return

        if attempt == 0:
            warn("push was rejected; fetching again")
            time.sleep(1)
            continue

        raise RuntimeError(
            "git push was rejected after retrying "
            "(remote changed again, or authentication failed)"
        )


# ============================================================
# Remote -> local project sync
# ============================================================


def sync_project_from_remote() -> None:
    clear_screen()
    print()
    print(
        f"{c(PINK + BOLD, 'sync project folder from remote repo')} "
        f"{c(DIM, ':3')}"
    )
    print(c(GRAY, str(DOTFILES)))
    print()

    unmerged = unmerged_paths()
    if unmerged:
        raise RuntimeError(unmerged_message(unmerged))

    status = git_status()
    if status:
        warn("project folder has uncommitted changes")
        print()
        print(status)
        print()
        warn("nothing was changed")
        return

    branch = current_branch()
    if not branch:
        raise RuntimeError("repository is in detached HEAD state")

    upstream = upstream_ref()
    if upstream is None:
        raise RuntimeError(
            f"branch '{branch}' has no upstream remote"
        )

    info(f"branch: {branch}")
    info(f"upstream: {upstream}")

    fetch_remote()
    behind, ahead = remote_counts()

    if behind == 0:
        if ahead:
            info("local branch is ahead; no remote changes to pull")
        else:
            success("project folder is already up to date :3")
        return

    if ahead == 0:
        say("pulling latest changes...")
        git_live("merge", "--ff-only", "@{u}")
        success("project folder synced from remote repo :3")
        return

    say("local and remote branches have diverged")
    info("rebasing local commits onto the remote branch...")
    result = git_live("rebase", "@{u}", check=False)
    if result.returncode != 0:
        git_live("rebase", "--abort", check=False)
        warn("rebase stopped because Git reported a conflict; it was aborted")
        raise RuntimeError("git rebase failed; resolve the divergence manually")

    success("project folder reconciled with remote repo :3")


# ============================================================
# Main sync operation
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
    print(c(PINK + BOLD, "alice's reverse rice sync") + " " + c(DIM, ":3"))
    print(c(GRAY, "live system → dotfiles repository"))

    if dry:
        print(c(YELLOW, "DRY RUN: nothing will be changed"))
    if adopt_new:
        print(c(CYAN, "ADOPT NEW: recent managed files may be added"))
    if prune:
        print(c(RED, "PRUNE: tracked repo files missing live can be deleted"))

    print()

    # Unresolved conflicts make commit/stash/push fail halfway through, so
    # stop before touching anything if we are going to need them.
    unmerged = unmerged_paths()
    if unmerged:
        if (commit or push) and not dry:
            raise RuntimeError(unmerged_message(unmerged))
        warn("unresolved merge conflicts in: " + ", ".join(unmerged))
        warn("resolve them and `git add` before using --commit / --push")

    # Snapshot repository state before doing anything. These are NOT ours.
    initial_dirty = git_status_paths()
    if initial_dirty:
        warn("existing repository changes detected; they will not be committed")
        for path in sorted(initial_dirty):
            print(f"    {c(GRAY, path)}")

    changes = build_plan(
        prune=prune,
        adopt_new=adopt_new,
    )
    changes = filter_conflicts(changes, initial_dirty)

    print_changes(changes)

    dconf = dconf_change(dconf_live())
    if dconf is not None:
        rel = repo_relative(dconf.destination)
        if rel in initial_dirty:
            warn(f"skipping {rel}: repository file already had local changes")
            if dconf.source is not None:
                dconf.source.unlink(missing_ok=True)
            dconf = None
        else:
            print()
            print(f"    {c(YELLOW, '[UPD]')} dconf:/org/gnome/desktop/interface/")
            print(f"         {c(GRAY, 'TO:  ')} {dconf.destination}")

    if dry:
        if dconf is not None and dconf.source is not None:
            dconf.source.unlink(missing_ok=True)
        print()
        success(f"dry-run finished: {len(changes)} file change(s)")
        return

    for change in changes:
        apply_change(change)

    if dconf is not None:
        apply_dconf_change(dconf)

    print()
    say("repository status")
    status_after = git_status()
    if status_after:
        print(status_after)
    else:
        success("repository is clean")

    if commit or push:
        make_commit(changes, dconf)

    if push:
        print()
        push_repo()

    print()
    success("reverse sync finished :3")


# ============================================================
# Discovery / status helpers
# ============================================================


def show_status() -> None:
    clear_screen()
    print()
    say("repository status")
    status = git_status()
    if status:
        print(status)
    else:
        success("repository is clean")

    unmerged = unmerged_paths()
    if unmerged:
        print()
        warn(unmerged_message(unmerged))

    upstream = upstream_ref()
    if upstream:
        try:
            fetch_remote()
            behind, ahead = remote_counts()
            print()
            info(f"upstream: {upstream}")
            info(f"ahead: {ahead}   behind: {behind}")
        except Exception as exc:
            warn(str(exc))


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
    ("8", "show git + remote status"),
    ("9", "sync project folder from remote repo"),
    ("10", "exit"),
)


def show_menu() -> None:
    clear_screen()
    print()
    print(c(PINK, "╭──────────────────────────────────────────────╮"))
    print(
        c(PINK, "│") + " " +
        c(WHITE + BOLD, "alice's reverse rice sync") + " " +
        c(DIM, ":3")
    )
    print(
        f"{c(PINK, '│')} "
        f"{c(GRAY, 'live system → dotfiles repository')}"
    )
    print(c(PINK, "╰──────────────────────────────────────────────╯"))
    print()
    print(c(PURPLE + BOLD, "what should i do?"))
    print()
    for number, label in MENU:
        print(f"  {c(PINK, number.rjust(2))}  {label}")
    print()


def interactive() -> None:
    while True:
        show_menu()
        try:
            choice = input(f"{WHITE}choice: {RESET}").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            info("bye :3")
            return

        try:
            if choice == "1":
                run_sync()
            elif choice == "2":
                run_sync(adopt_new=True)
            elif choice == "3":
                clear_screen()
                print()
                print(c(PINK + BOLD, "new rice file discovery") + " " + c(DIM, ":3"))
                print()
                print_changes(discover_new())
            elif choice == "4":
                run_sync(dry=True)
            elif choice == "5":
                run_sync(commit=True)
            elif choice == "6":
                run_sync(commit=True, push=True)
            elif choice == "7":
                run_sync(prune=True)
            elif choice == "8":
                show_status()
            elif choice == "9":
                sync_project_from_remote()
            elif choice in {"10", "q", "Q"}:
                clear_screen()
                info("bye :3")
                return
            else:
                warn("please enter 1-10")
        except Exception as exc:
            error(str(exc))

        pause()


# ============================================================
# CLI
# ============================================================


def usage() -> None:
    print(__doc__.strip())


def validate_repo() -> None:
    if os.geteuid() == 0:
        raise RuntimeError("do not run this script as root")
    if shutil.which("git") is None:
        raise RuntimeError("git is required")
    if not (DOTFILES / ".git").exists():
        raise RuntimeError("sync.py must be inside your dotfiles git repository")


def main(argv: list[str]) -> int:
    validate_repo()

    if not argv:
        interactive()
        return 0

    if argv == ["--help"] or argv == ["-h"]:
        usage()
        return 0

    allowed = {
        "--dry-run",
        "--discover",
        "--adopt-new",
        "--prune",
        "--commit",
        "--push",
        "--remote-sync",
    }

    unknown = [arg for arg in argv if arg not in allowed]
    if unknown:
        raise RuntimeError(f"unknown option: {unknown[0]}")

    if "--remote-sync" in argv:
        sync_project_from_remote()
        return 0

    if "--discover" in argv:
        run_sync(dry=True, adopt_new=True)
        return 0

    run_sync(
        dry="--dry-run" in argv,
        adopt_new="--adopt-new" in argv,
        prune="--prune" in argv,
        commit=("--commit" in argv or "--push" in argv),
        push="--push" in argv,
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        print()
        info("cancelled :3")
        raise SystemExit(130)
    except subprocess.CalledProcessError as exc:
        error(exc.stderr.strip() if exc.stderr else "command failed")
        raise SystemExit(exc.returncode or 1)
    except Exception as exc:
        error(str(exc))
        raise SystemExit(1)
