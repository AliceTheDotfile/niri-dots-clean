#!/usr/bin/env python3
"""Alice's rice sync :3

The dotfiles repository is a BASELINE, not a forever-managed copy of every
computer.

This tool is intentionally simple:

    1. choose the part of the rice you intentionally changed
    2. review its changed/new/deleted files
    3. choose which files are shared by future installs/updates
    4. copy those files into the repository
    5. record them in .alice-sync/update-manifest.json
    6. commit only those files

Fresh installs still get the complete baseline repository.
Future UPDATE installs use update-manifest.json, so machine-specific changes
that were never selected here are left alone.

Waybar and Fastfetch are intentionally not managed by this script.

Usage:
    ./sync.py
    ./sync.py --part quickshell
    ./sync.py --part niri,quickshell --push
    ./sync.py --dry-run
    ./sync.py --manifest
    ./sync.py --help
"""

from __future__ import annotations

import filecmp
import json
import os
import shlex
import shutil
import subprocess
import sys
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator, TextIO


# ============================================================
# Paths
# ============================================================

HOME = Path.home()
CONFIG = Path(os.environ.get("XDG_CONFIG_HOME", HOME / ".config"))
SHARE = Path(os.environ.get("XDG_DATA_HOME", HOME / ".local" / "share"))
BIN = HOME / ".local" / "bin"
ROOT = Path(__file__).resolve().parent
MANIFEST = ROOT / ".alice-sync" / "update-manifest.json"


# ============================================================
# UI colors
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
COLOR = sys.stdout.isatty()


# ============================================================
# Managed groups
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


@dataclass(frozen=True)
class Mapping:
    live: Path
    repo: Path


@dataclass(frozen=True)
class Candidate:
    path: str
    live: Path | None
    repo: Path
    action: str  # update, add, delete, keep
    conflict: bool = False


GROUPS: dict[str, tuple[str, tuple[Mapping, ...]]] = {
    "niri": (
        "Niri",
        (Mapping(CONFIG / "niri", ROOT / "niri"),),
    ),
    "quickshell": (
        "Quickshell",
        (Mapping(CONFIG / "quickshell" / "my-shell", ROOT / "quickshell" / "my-shell"),),
    ),
    "desktop": (
        "Desktop configs",
        tuple(
            Mapping(CONFIG / name, ROOT / name)
            for name in (
                "alice-rice",
                "btop",
                "cava",
                "environment.d",
                "fontconfig",
                "gamearch",
                "gtk-3.0",
                "gtk-4.0",
                "Kvantum",
                "qt6ct",
                "swaync",
            )
        ),
    ),
    "home": (
        "Home / KDE / Kate / themes",
        tuple(
            Mapping(HOME / rel, ROOT / "home" / rel)
            for rel in (
                ".bash_profile",
                ".config/kdeglobals",
                ".config/katerc",
                ".config/katevirc",
                ".config/katemetainfos",
                ".local/share/color-schemes/AliceNight.colors",
                ".local/share/themes/AliceNight",
                ".config/kate",
            )
        ),
    ),
    "wallfliper": (
        "Wallfliper",
        (
            Mapping(
                CONFIG / "wallfliper" / "config.json",
                ROOT / "wallfliper" / "config.json",
            ),
            Mapping(
                SHARE / "wallfliper",
                ROOT / "wallfliper",
            ),
        ),
    ),
    "scripts": (
        "Local scripts",
        (Mapping(BIN, ROOT / "local" / "bin"),),
    ),
    "wallpapers": (
        "Wallpapers",
        (Mapping(HOME / "Wallpapers", ROOT / "Wallpapers"),),
    ),
}

TRACKED: set[str] = set()


# ============================================================
# Output
# ============================================================


def paint(color: str, text: str) -> str:
    return f"{color}{text}{RESET}" if COLOR else text


def say(text: str) -> None:
    print(f"{paint(PINK, '::')} {text}", flush=True)


def info(text: str) -> None:
    print(f"{paint(CYAN, '→')} {text}", flush=True)


def ok(text: str) -> None:
    print(f"{paint(GREEN, '✓')} {text}", flush=True)


def warn(text: str) -> None:
    print(f"{paint(YELLOW, '!')} {text}", flush=True)


def fail(text: str) -> None:
    print(f"{paint(RED, '✗')} {text}", file=sys.stderr, flush=True)


def clear() -> None:
    if COLOR:
        print("\033[2J\033[H", end="")


# ============================================================
# Terminal input
# ============================================================


@contextmanager
def input_terminal() -> Iterator[TextIO]:
    """Use /dev/tty when available so sync.py works from launchers/pipes too."""
    if sys.stdin.isatty():
        yield sys.stdin
        return

    try:
        tty = open("/dev/tty", "r", encoding="utf-8", errors="replace")
    except OSError:
        raise RuntimeError(
            "interactive input is unavailable; run sync.py from a terminal "
            "or use --part <name>"
        )

    try:
        yield tty
    finally:
        tty.close()


def ask(prompt: str) -> str:
    with input_terminal() as stream:
        print(prompt, end="", flush=True)
        value = stream.readline()

    if value == "":
        raise RuntimeError(
            "input ended unexpectedly; sync.py needs an interactive terminal"
        )

    return value.rstrip("\r\n")


# ============================================================
# Git helpers
# ============================================================


def git(
    *args: str,
    live: bool = False,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    command = ["git", "-C", str(ROOT), *args]

    if live:
        info("git " + " ".join(shlex.quote(x) for x in args))
        result = subprocess.run(
            command,
            text=True,
            check=False,
        )
    else:
        result = subprocess.run(
            command,
            text=True,
            capture_output=True,
            check=False,
        )

    if check and result.returncode != 0:
        message = (result.stderr or result.stdout or "").strip()
        raise RuntimeError(
            message or f"git {' '.join(args)} failed"
        )

    return result


def status_paths() -> set[str]:
    result = git("status", "--porcelain=v1", "-z")
    parts = result.stdout.split("\0")
    paths: set[str] = set()
    index = 0

    while index < len(parts):
        entry = parts[index]
        if not entry:
            index += 1
            continue

        if len(entry) >= 4:
            paths.add(entry[3:])

        if entry[:2] and (
            entry[0] in "RC"
            or entry[1] in "RC"
        ):
            if index + 1 < len(parts) and parts[index + 1]:
                paths.add(parts[index + 1])
            index += 1

        index += 1

    return paths


def unmerged() -> list[str]:
    result = git(
        "ls-files",
        "--unmerged",
        "-z",
        check=False,
    )

    return sorted({
        item.partition("\t")[2]
        for item in result.stdout.split("\0")
        if "\t" in item
    })


def tracked_files() -> set[str]:
    return {
        item
        for item in git("ls-files", "-z").stdout.split("\0")
        if item
    }


def upstream() -> str | None:
    result = git(
        "rev-parse",
        "--abbrev-ref",
        "--symbolic-full-name",
        "@{u}",
        check=False,
    )

    return (
        result.stdout.strip()
        if result.returncode == 0
        else None
    ) or None


def remote_counts() -> tuple[int, int]:
    result = git(
        "rev-list",
        "--left-right",
        "--count",
        "HEAD...@{u}",
    )

    left, right = result.stdout.split()
    return int(right), int(left)  # behind, ahead


# ============================================================
# Filesystem helpers
# ============================================================


def exists(path: Path) -> bool:
    return path.exists() or path.is_symlink()


def ignored(path: Path) -> bool:
    try:
        output_file = (
            CONFIG / "niri" / "parts" / "output.kdl"
        ).resolve(strict=False)
        if path.resolve(strict=False) == output_file:
            return True
    except OSError:
        pass

    normalized = path.as_posix().rstrip("/")

    return (
        normalized == "niri/parts/output.kdl"
        or normalized.endswith("/niri/parts/output.kdl")
        or path.name in IGNORE_NAMES
        or path.suffix in IGNORE_SUFFIXES
        or ".git" in path.parts
        or "__pycache__" in path.parts
    )


def file_map(root: Path) -> dict[Path, Path]:
    if not exists(root):
        return {}

    if root.is_file() or root.is_symlink():
        return {} if ignored(root) else {Path("."): root}

    result: dict[Path, Path] = {}

    try:
        for path in root.rglob("*"):
            if ignored(path):
                continue
            if path.is_file() or path.is_symlink():
                result[path.relative_to(root)] = path
    except OSError as exc:
        warn(f"could not scan {root}: {exc}")

    return result


def normalized(path: Path) -> bytes | None:
    try:
        if path.is_symlink():
            return (
                str(path.readlink())
                .replace(str(HOME), "@HOME@")
                .encode("utf-8")
            )

        if path.is_file():
            return path.read_bytes().replace(
                str(HOME).encode("utf-8"),
                b"@HOME@",
            )
    except (OSError, UnicodeError):
        return None

    return None


def same(a: Path, b: Path) -> bool:
    if not exists(a) or not exists(b):
        return False

    if a.is_symlink() or b.is_symlink():
        try:
            return (
                a.is_symlink()
                and b.is_symlink()
                and a.readlink() == b.readlink()
            )
        except OSError:
            return False

    aa = normalized(a)
    bb = normalized(b)

    if aa is not None and bb is not None:
        return aa == bb

    try:
        return filecmp.cmp(
            a,
            b,
            shallow=False,
        )
    except OSError:
        return False


def head_bytes(relative: str) -> bytes | None:
    result = subprocess.run(
        [
            "git",
            "-C",
            str(ROOT),
            "show",
            f"HEAD:{relative}",
        ],
        capture_output=True,
        check=False,
    )

    return result.stdout if result.returncode == 0 else None


def live_equals_head(live: Path, relative: str) -> bool:
    data = normalized(live)
    head = head_bytes(relative)
    return data is not None and head is not None and data == head


def repo_dirty(relative: str) -> bool:
    result = git(
        "diff",
        "--quiet",
        "HEAD",
        "--",
        relative,
        check=False,
    )

    if result.returncode == 0:
        return False

    if result.returncode == 1:
        return True

    raise RuntimeError(f"could not inspect {relative}")


def repo_relative(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


# ============================================================
# Manifest
# ============================================================


def load_manifest() -> dict[str, set[str]]:
    if not MANIFEST.exists():
        return {
            "managed": set(),
            "deleted": set(),
        }

    try:
        data = json.loads(
            MANIFEST.read_text(encoding="utf-8")
        )
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeError(
            f"invalid {MANIFEST.relative_to(ROOT)}: {exc}"
        ) from exc

    if not isinstance(data, dict):
        raise RuntimeError(
            f"invalid {MANIFEST.relative_to(ROOT)}: root must be an object"
        )

    managed = {
        str(value)
        for value in data.get("managed", [])
    }
    deleted = {
        str(value)
        for value in data.get("deleted", [])
    }

    return {
        "managed": managed,
        "deleted": deleted,
    }


def save_manifest(
    managed: set[str],
    deleted: set[str],
) -> None:
    MANIFEST.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    MANIFEST.write_text(
        json.dumps(
            {
                "version": 1,
                "managed": sorted(managed),
                "deleted": sorted(deleted & managed),
            },
            indent=2,
        ) + "\n",
        encoding="utf-8",
    )


def update_manifest(
    selected: list[Candidate],
) -> None:
    data = load_manifest()
    managed = data["managed"]
    deleted = data["deleted"]

    for candidate in selected:
        managed.add(candidate.path)

        if candidate.action == "delete":
            deleted.add(candidate.path)
        else:
            deleted.discard(candidate.path)

    save_manifest(
        managed,
        deleted,
    )


def show_manifest() -> None:
    data = load_manifest()

    print()
    say("future installer updates will manage these files")

    if not data["managed"]:
        warn("manifest is empty")
        return

    for path in sorted(data["managed"]):
        if path in data["deleted"]:
            label, color = "[DEL]", RED
        else:
            label, color = "[UPD]", GREEN

        print(
            f"    {paint(color, label)} {path}"
        )


# ============================================================
# Candidate discovery
# ============================================================


def candidate_conflict(
    path: str,
    live: Path | None,
    repo: Path,
    action: str,
) -> bool:
    """Return True when the repo has an independent pre-existing edit."""
    tracked = path in TRACKED

    # Brand-new repository paths are protected. The user may still select a
    # NEW live file and create it in the repo, but an unrelated existing repo
    # file must never be overwritten automatically.
    if not tracked and exists(repo):
        return True

    if not tracked:
        return False

    if not repo_dirty(path):
        return False

    # UPDATE: if the live version is still exactly what HEAD contains, then
    # only the repository changed -> protect the repository edit.
    if action == "update" and live is not None:
        return live_equals_head(live, path)

    # DELETE: the live file disappeared. If the repo also differs from HEAD,
    # that is an independent repository edit; do not remove it.
    if action == "delete":
        return not live_equals_head(repo, path)

    # ADD is a special case for an untracked live file replacing a missing repo
    # file. There is no repo-side dirty state to conflict with here.
    if action == "add":
        return False

    return False


def candidates_for(mapping: Mapping) -> list[Candidate]:
    live_map = file_map(mapping.live)
    repo_map = file_map(mapping.repo)
    candidates: list[Candidate] = []

    for relative in sorted(set(live_map) | set(repo_map)):
        live = live_map.get(relative)
        fallback_repo = mapping.repo / relative
        repo = repo_map.get(relative, fallback_repo)

        path = repo_relative(repo)
        live_exists = live is not None and exists(live)
        repo_exists = exists(repo)
        tracked = path in TRACKED

        if not live_exists and not repo_exists:
            continue

        if live_exists and not repo_exists:
            action = "add"
        elif repo_exists and not live_exists:
            action = "delete"
        elif same(live, repo):
            # If the repo is dirty and already equals live, the live change is
            # already present in the repo. It still needs to be listed so the
            # manifest can record it.
            if tracked and repo_dirty(path):
                action = "keep"
            else:
                continue
        else:
            action = "update"

        conflict = candidate_conflict(
            path,
            live,
            repo,
            action,
        )

        candidates.append(
            Candidate(
                path=path,
                live=live,
                repo=repo,
                action=action,
                conflict=conflict,
            )
        )

    return candidates


def selected_candidates(
    groups: list[str],
) -> list[Candidate]:
    unique: dict[str, Candidate] = {}

    for group in groups:
        for mapping in GROUPS[group][1]:
            for candidate in candidates_for(mapping):
                existing = unique.get(candidate.path)

                if existing is None:
                    unique[candidate.path] = candidate
                elif existing.conflict and not candidate.conflict:
                    unique[candidate.path] = candidate

    return sorted(
        unique.values(),
        key=lambda candidate: candidate.path,
    )


# ============================================================
# Copy / commit
# ============================================================


def copy_candidate(candidate: Candidate) -> None:
    if candidate.action == "keep":
        return

    if candidate.action == "delete":
        if exists(candidate.repo):
            if (
                candidate.repo.is_dir()
                and not candidate.repo.is_symlink()
            ):
                shutil.rmtree(candidate.repo)
            else:
                candidate.repo.unlink()
        return

    live = candidate.live
    repo = candidate.repo

    if live is None or not exists(live):
        raise RuntimeError(
            f"missing live file: {candidate.path}"
        )

    repo.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    if exists(repo):
        if repo.is_dir() and not repo.is_symlink():
            shutil.rmtree(repo)
        else:
            repo.unlink()

    if live.is_symlink():
        repo.symlink_to(live.readlink())
        return

    if live.is_file():
        shutil.copy2(
            live,
            repo,
            follow_symlinks=False,
        )
    else:
        raise RuntimeError(
            f"unsupported live path: {live}"
        )

    # Make live $HOME portable in the repository.
    try:
        text = repo.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return

    home = str(HOME)

    if home in text:
        repo.write_text(
            text.replace(home, "@HOME@"),
            encoding="utf-8",
        )


def show_candidate_diff(candidate: Candidate) -> None:
    if candidate.action == "add":
        print()
        print(
            paint(
                GREEN,
                f"--- new: {candidate.path}",
            )
        )
        return

    if candidate.action == "delete":
        print()
        print(
            paint(
                RED,
                f"--- deleted from live system: {candidate.path}",
            )
        )
        return

    if candidate.action == "keep":
        return

    # The live file and repo file differ. Git's no-index diff is useful here,
    # but not required; failures merely mean that no inline diff is shown.
    if candidate.live is None or not exists(candidate.live):
        return
    if not exists(candidate.repo):
        return

    result = subprocess.run(
        [
            "diff",
            "-u",
            str(candidate.repo),
            str(candidate.live),
        ],
        text=True,
        capture_output=True,
        check=False,
    )

    if result.returncode not in (0, 1):
        return

    lines = result.stdout.splitlines()

    if not lines:
        return

    print()
    print(
        paint(
            GRAY,
            "    diff:"
        )
    )

    for line in lines[:80]:
        if line.startswith("+") and not line.startswith("+++"):
            prefix = GREEN
        elif line.startswith("-") and not line.startswith("---"):
            prefix = RED
        elif line.startswith("@@"):
            prefix = CYAN
        else:
            prefix = GRAY

        print("      " + paint(prefix, line))

    if len(lines) > 80:
        print(
            "      "
            + paint(
                GRAY,
                f"... {len(lines) - 80} more diff lines",
            )
        )


def choose_candidates(
    candidates: list[Candidate],
) -> list[Candidate]:
    print()
    say("detected changes")

    for candidate in candidates:
        labels = {
            "add": ("NEW", GREEN),
            "delete": ("DEL", RED),
            "keep": ("KEEP", CYAN),
            "update": ("UPD", YELLOW),
        }
        label, color = labels[candidate.action]

        print(
            f"    {paint(color, '[' + label + ']')} "
            f"{candidate.path}"
        )

        if candidate.conflict:
            print(
                "         "
                + paint(
                    GRAY,
                    "protected: repository-side change is independent",
                )
            )

    usable = [
        candidate
        for candidate in candidates
        if not candidate.conflict
    ]

    if not usable:
        warn(
            "nothing can be safely saved from this selection"
        )
        return []

    print()
    answer = ask(
        "save all detected files from this part? [Y/n] "
    ).strip().lower()

    if answer in {"", "y", "yes"}:
        return usable

    if answer in {"n", "no"}:
        selected: list[Candidate] = []

        print()
        say("choose individual files")

        for index, candidate in enumerate(usable, 1):
            answer = ask(
                f"  {paint(PINK, str(index).rjust(2))} "
                f"{candidate.path} [y/N/diff] "
            ).strip().lower()

            if answer in {"y", "yes"}:
                selected.append(candidate)
            elif answer == "diff":
                show_candidate_diff(candidate)
                repeat = ask(
                    f"    save {candidate.path}? [y/N] "
                ).strip().lower()
                if repeat in {"y", "yes"}:
                    selected.append(candidate)

        return selected

    # Allow a simple comma/space-separated list of numbers as a convenience.
    numbers = answer.replace(",", " ").split()
    if all(item.isdigit() for item in numbers):
        selected = []
        for item in numbers:
            index = int(item) - 1
            if 0 <= index < len(usable):
                selected.append(usable[index])
        return list(dict.fromkeys(selected))

    return []


def commit_selected(
    selected: list[Candidate],
    groups: list[str],
) -> bool:
    if not selected:
        return False

    for candidate in selected:
        copy_candidate(candidate)

    update_manifest(selected)

    paths = sorted({
        candidate.path
        for candidate in selected
    } | {
        MANIFEST.relative_to(ROOT).as_posix()
    })

    git(
        "add",
        "-A",
        "--",
        *paths,
    )

    staged = {
        item
        for item in git(
            "diff",
            "--cached",
            "--name-only",
            "-z",
            "--",
            *paths,
        ).stdout.split("\0")
        if item
    }

    if not staged:
        info("nothing changed after staging")
        return False

    default = (
        "sync: update "
        + " + ".join(groups)
    )

    message = ask(
        f"commit message [{default}]: "
    ).strip()

    if not message:
        message = default

    # --only protects any unrelated staged files from joining our commit.
    git(
        "commit",
        "--only",
        "-m",
        message,
        "--",
        *paths,
        live=True,
    )

    ok("sync commit created")
    return True


# ============================================================
# Push
# ============================================================


def stash_for_rebase() -> str | None:
    if not status_paths():
        return None

    git(
        "stash",
        "push",
        "--include-untracked",
        "-m",
        "alice-sync temporary protection",
        live=True,
    )

    value = git(
        "stash",
        "list",
        "-1",
        "--format=%H",
    ).stdout.strip()

    if not value:
        raise RuntimeError(
            "temporary stash could not be verified"
        )

    return value


def restore_stash(value: str | None) -> None:
    if not value:
        return

    result = git(
        "stash",
        "apply",
        value,
        check=False,
    )

    if result.returncode == 0:
        git(
            "stash",
            "drop",
            value,
            check=False,
        )
        ok("unrelated repository changes restored")
        return

    git(
        "reset",
        "--hard",
        "HEAD",
        check=False,
    )
    git(
        "clean",
        "-fd",
        check=False,
    )
    warn(
        "could not restore temporary changes; "
        f"stash remains at {value}"
    )


def push() -> None:
    if unmerged():
        raise RuntimeError(
            "resolve existing git conflicts before pushing"
        )

    if upstream() is None:
        branch = git(
            "branch",
            "--show-current",
        ).stdout.strip()
        remotes = [
            item
            for item in git("remote").stdout.splitlines()
            if item.strip()
        ]

        if not branch or not remotes:
            raise RuntimeError(
                "repository needs a branch and remote before pushing"
            )

        git(
            "push",
            "-u",
            remotes[0],
            branch,
            live=True,
        )
        ok("repository pushed")
        return

    stash: str | None = None

    try:
        git(
            "fetch",
            "--prune",
            live=True,
        )

        behind, _ahead = remote_counts()

        if behind:
            stash = stash_for_rebase()
            result = git(
                "rebase",
                "@{u}",
                live=True,
                check=False,
            )

            if result.returncode:
                git(
                    "rebase",
                    "--abort",
                    live=True,
                    check=False,
                )
                raise RuntimeError(
                    "remote rebase failed; it was aborted"
                )

        result = git(
            "push",
            live=True,
            check=False,
        )

        if result.returncode:
            info(
                "remote changed during push; retrying once"
            )

            git(
                "fetch",
                "--prune",
                live=True,
            )

            result = git(
                "rebase",
                "@{u}",
                live=True,
                check=False,
            )

            if result.returncode:
                git(
                    "rebase",
                    "--abort",
                    live=True,
                    check=False,
                )
                raise RuntimeError(
                    "remote rebase failed during retry"
                )

            git(
                "push",
                live=True,
            )
        else:
            ok("repository pushed")

    finally:
        restore_stash(stash)


# ============================================================
# UI
# ============================================================


def choose_groups() -> list[str]:
    names = list(GROUPS)

    clear()
    print()
    print(
        paint(PINK + BOLD, "alice's rice sync")
        + " "
        + paint(DIM, ":3")
    )
    print(
        paint(
            GRAY,
            "save only the parts you intentionally changed",
        )
    )
    print()

    for index, name in enumerate(names, 1):
        print(
            f"  {paint(PINK, str(index).rjust(2))}  "
            f"{GROUPS[name][0]}  "
            f"{paint(GRAY, '(' + name + ')')}"
        )

    print(
        f"  {paint(PINK, ' m')}  multiple"
    )
    print(
        f"  {paint(PINK, ' q')}  quit"
    )
    print()

    answer = ask(
        "choice: "
    ).strip().lower()

    if answer in {"q", "quit", "exit"}:
        return []

    if answer in {"m", "multiple"}:
        answer = ask(
            "parts (example: quickshell,niri): "
        ).strip().lower()

    if answer.isdigit():
        index = int(answer) - 1

        if 0 <= index < len(names):
            return [names[index]]

    parts = [
        value.strip().lower()
        for value in answer.split(",")
        if value.strip()
    ]

    unknown = [
        value
        for value in parts
        if value not in GROUPS
    ]

    if unknown:
        raise RuntimeError(
            "unknown rice part: " + ", ".join(unknown)
        )

    return list(dict.fromkeys(parts))


def run(
    groups: list[str],
    *,
    dry: bool,
    do_push: bool,
) -> None:
    global TRACKED

    conflicts = unmerged()
    if conflicts:
        raise RuntimeError(
            "resolve existing git conflicts before running sync.py: "
            + ", ".join(conflicts)
        )

    TRACKED = tracked_files()

    candidates = selected_candidates(groups)

    if not candidates:
        ok("nothing changed in the selected part")
        return

    chosen = choose_candidates(candidates)

    if not chosen:
        info("no files selected")
        return

    print()
    say("files selected for the shared rice")

    for candidate in chosen:
        print(
            f"    {candidate.path}"
        )

    if dry:
        print()
        ok("dry-run complete")
        return

    commit = commit_selected(
        chosen,
        groups,
    )

    if commit and do_push:
        push()

    print()
    ok("rice sync finished :3")


# ============================================================
# Main
# ============================================================


def usage() -> None:
    print(__doc__.strip())
    print()
    print("parts:")
    for key, (label, _mappings) in GROUPS.items():
        print(f"  {key:<12} {label}")


def main(argv: list[str]) -> int:
    if os.geteuid() == 0:
        raise RuntimeError(
            "do not run sync.py as root"
        )

    if shutil.which("git") is None:
        raise RuntimeError("git is required")

    if not (ROOT / ".git").is_dir():
        raise RuntimeError(
            "sync.py must be inside the dotfiles git repository"
        )

    if "--manifest" in argv:
        if len(argv) != 1:
            raise RuntimeError(
                "--manifest cannot be combined with other options"
            )
        show_manifest()
        return 0

    if argv in (["--help"], ["-h"]):
        usage()
        return 0

    dry = False
    do_push = False
    value: str | None = None

    index = 0

    while index < len(argv):
        arg = argv[index]

        if arg == "--dry-run":
            dry = True

        elif arg == "--push":
            do_push = True

        elif arg == "--part":
            if index + 1 >= len(argv):
                raise RuntimeError("--part needs a value")
            value = argv[index + 1]
            index += 1

        elif arg.startswith("--part="):
            value = arg.split("=", 1)[1]

        else:
            raise RuntimeError(
                f"unknown option: {arg}"
            )

        index += 1

    if value:
        groups = [
            item.strip().lower()
            for item in value.split(",")
            if item.strip()
        ]
    else:
        groups = choose_groups()

    unknown = [
        group
        for group in groups
        if group not in GROUPS
    ]

    if unknown:
        raise RuntimeError(
            "unknown rice part: " + ", ".join(unknown)
        )

    if not groups:
        info("bye :3")
        return 0

    run(
        list(dict.fromkeys(groups)),
        dry=dry,
        do_push=do_push,
    )

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        print()
        info("cancelled :3")
        raise SystemExit(130)
    except Exception as exc:
        fail(str(exc))
        raise SystemExit(1)
