#!/usr/bin/env python3
"""Alice's rice sync :3

The repository is a reusable BASELINE.  Sync only the changes you explicitly
choose to become part of that baseline.

Workflow:
    choose a rice part -> review live-vs-repo diffs -> select changes ->
    copy them to the repo -> update .alice-sync/update-manifest.json -> commit

The installer uses the manifest for UPDATE mode. Fresh installs still copy the
whole baseline, while existing systems only replace manifest-listed files.

Waybar and Fastfetch are intentionally not managed here.

Usage:
    ./sync.py                          review every rice part
    ./sync.py --part quickshell        just one part (or: niri,quickshell,hyprlock)
    ./sync.py --part niri --push       ...and push after committing
    ./sync.py --dry-run                show what would be shared, write nothing
    ./sync.py --yes                    approve everything without prompting

Managing what gets shared:
    ./sync.py --add ~/.config/foo/foo.conf   start syncing any file or folder in your home
    ./sync.py --list-custom                  files you added this way
    ./sync.py --remove-custom PATH           stop syncing one of them

    ./sync.py --manifest                     show the update manifest
    ./sync.py --manifest-edit                edit it by hand ($EDITOR), validated on save
    ./sync.py --manifest-add PATH...         mark repo files (or live paths) as shared
    ./sync.py --manifest-remove PATH...      un-share files (a folder path removes its files)
    ./sync.py --manifest-clear               empty the manifest
    ./sync.py --tools                        menu with all of the above
"""

from __future__ import annotations

import difflib
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

HOME = Path.home()
CONFIG = Path(os.environ.get("XDG_CONFIG_HOME", HOME / ".config"))
SHARE = Path(os.environ.get("XDG_DATA_HOME", HOME / ".local" / "share"))
BIN = HOME / ".local" / "bin"
ROOT = Path(__file__).resolve().parent
MANIFEST = ROOT / ".alice-sync" / "update-manifest.json"

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

IGNORE_NAMES = {".qmlls.ini", "anonymous.katesession", "__pycache__", "sync.py", ".bashrc", ".sync.py.kate-swp"}
IGNORE_SUFFIXES = {".bak", ".pyc", ".log", ".swp", ".kate-swp"}


@dataclass(frozen=True)
class Mapping:
    live: Path
    repo: Path


@dataclass(frozen=True)
class Candidate:
    path: str
    live: Path | None
    repo: Path
    action: str  # update, add, delete
    repo_dirty: bool
    shared: bool


GROUPS: dict[str, tuple[str, tuple[Mapping, ...]]] = {
    "niri": ("Niri", (Mapping(CONFIG / "niri", ROOT / "niri"),)),
    "quickshell": (
        "Quickshell",
        (Mapping(CONFIG / "quickshell" / "my-shell", ROOT / "quickshell" / "my-shell"),),
    ),
    "desktop": (
        "Desktop configs",
        tuple(Mapping(CONFIG / x, ROOT / x) for x in (
            "alice-rice", "btop", "cava", "environment.d", "fontconfig",
            "gamearch", "gtk-3.0", "gtk-4.0", "Kvantum", "qt6ct", "swaync",
        )),
    ),
    "home": (
        "Home / KDE / Kate / themes",
        tuple(Mapping(HOME / x, ROOT / "home" / x) for x in (
            ".bash_profile", ".config/kdeglobals", ".config/katerc",
            ".config/katevirc", ".config/katemetainfos",
            ".local/share/color-schemes/AliceNight.colors",
            ".local/share/themes/AliceNight", ".config/kate",
        )),
    ),
    "hyprlock": (
        "Hyprlock",
        (Mapping(CONFIG / "hypr" / "hyprlock.conf", ROOT / "home" / ".config" / "hypr" / "hyprlock.conf"),),
    ),
    "wallfliper": (
        "Wallfliper",
        (
            Mapping(CONFIG / "wallfliper" / "config.json", ROOT / "wallfliper" / "config.json"),
            Mapping(SHARE / "wallfliper", ROOT / "wallfliper"),
        ),
    ),
    "scripts": ("Local scripts", (Mapping(BIN, ROOT / "local" / "bin"),)),
    "wallpapers": ("Wallpapers", (Mapping(HOME / "Wallpapers", ROOT / "Wallpapers"),)),
}

TRACKED: set[str] = set()


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


@contextmanager
def input_terminal() -> Iterator[TextIO]:
    if sys.stdin.isatty():
        yield sys.stdin
        return
    try:
        tty = open("/dev/tty", "r", encoding="utf-8", errors="replace")
    except OSError as exc:
        raise RuntimeError("interactive input is unavailable; run sync.py from a terminal") from exc
    try:
        yield tty
    finally:
        tty.close()


ASSUME_YES = False


def ask(prompt: str, default: str = "") -> str:
    """Prompt for a line. With --yes nothing is asked: the default answer is used."""
    if ASSUME_YES:
        print(f"{prompt}{default or '(default)'}", flush=True)
        return default
    with input_terminal() as stream:
        print(prompt, end="", flush=True)
        value = stream.readline()
    if not value:
        raise RuntimeError("input ended unexpectedly; sync.py needs an interactive terminal")
    return value.rstrip("\r\n")


def git(*args: str, live: bool = False, check: bool = True) -> subprocess.CompletedProcess[str]:
    command = ["git", "-C", str(ROOT), *args]
    if live:
        info("git " + " ".join(shlex.quote(x) for x in args))
        result = subprocess.run(command, text=True, check=False)
    else:
        result = subprocess.run(command, text=True, capture_output=True, check=False)
    if check and result.returncode:
        message = (result.stderr or result.stdout or "").strip()
        raise RuntimeError(message or f"git {' '.join(args)} failed")
    return result


def tracked_files() -> set[str]:
    return {x for x in git("ls-files", "-z").stdout.split("\0") if x}


def unmerged() -> list[str]:
    result = git("ls-files", "--unmerged", "-z", check=False)
    return sorted({x.partition("\t")[2] for x in result.stdout.split("\0") if "\t" in x})


def upstream() -> str | None:
    result = git("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}", check=False)
    return result.stdout.strip() if result.returncode == 0 and result.stdout.strip() else None


def remote_counts() -> tuple[int, int]:
    left, right = git("rev-list", "--left-right", "--count", "HEAD...@{u}").stdout.split()
    return int(right), int(left)


def repo_dirty(path: str) -> bool:
    result = git("diff", "--quiet", "HEAD", "--", path, check=False)
    if result.returncode == 0:
        return False
    if result.returncode == 1:
        return True
    raise RuntimeError(f"could not inspect git state for {path}")


def exists(path: Path) -> bool:
    return path.exists() or path.is_symlink()


def ignored(path: Path) -> bool:
    try:
        if path.resolve(strict=False) == (CONFIG / "niri" / "parts" / "output.kdl").resolve(strict=False):
            return True
    except OSError:
        pass
    p = path.as_posix().rstrip("/")
    return (
        p == "niri/parts/output.kdl"
        or p.endswith("/niri/parts/output.kdl")
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
            if not ignored(path) and (path.is_file() or path.is_symlink()):
                result[path.relative_to(root)] = path
    except OSError as exc:
        warn(f"could not scan {root}: {exc}")
    return result


def normalized(path: Path) -> bytes | None:
    try:
        if path.is_symlink():
            return str(path.readlink()).replace(str(HOME), "@HOME@").encode()
        if path.is_file():
            return path.read_bytes().replace(str(HOME).encode(), b"@HOME@")
    except (OSError, UnicodeError):
        return None
    return None


def same(a: Path, b: Path) -> bool:
    if not exists(a) or not exists(b):
        return False
    if a.is_symlink() or b.is_symlink():
        try:
            return a.is_symlink() and b.is_symlink() and a.readlink() == b.readlink()
        except OSError:
            return False
    aa, bb = normalized(a), normalized(b)
    if aa is not None and bb is not None:
        return aa == bb
    try:
        return filecmp.cmp(a, b, shallow=False)
    except OSError:
        return False


def repo_relative(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def text_for_diff(path: Path) -> str | None:
    try:
        if path.is_symlink():
            return str(path.readlink()).replace(str(HOME), "@HOME@") + "\n"
        data = path.read_bytes()
        if b"\x00" in data[:65536]:
            return None
        return data.decode("utf-8").replace(str(HOME), "@HOME@")
    except (OSError, UnicodeDecodeError):
        return None


def show_diff(candidate: Candidate, limit: int = 140) -> None:
    print()
    print(paint(CYAN, f"--- repository → live: {candidate.path}"))

    if candidate.action == "add":
        text = text_for_diff(candidate.live) if candidate.live else None
        if text is None:
            print("    [new binary or unreadable file]")
            return
        lines = text.splitlines()
        for line in lines[:limit]:
            print("    " + paint(GREEN, "+ " + line))
        if len(lines) > limit:
            print("    " + paint(GRAY, f"... {len(lines) - limit} more lines"))
        return

    if candidate.action == "delete":
        print("    " + paint(RED, "[file exists in repo but is gone from the live system]"))
        return

    repo_text = text_for_diff(candidate.repo)
    live_text = text_for_diff(candidate.live) if candidate.live else None
    if repo_text is None or live_text is None:
        print("    [binary or unreadable diff]")
        return

    lines = list(difflib.unified_diff(
        repo_text.splitlines(),
        live_text.splitlines(),
        fromfile=f"repo/{candidate.path}",
        tofile=f"live/{candidate.path}",
        lineterm="",
        n=3,
    ))
    for line in lines[:limit]:
        color = (
            CYAN if line.startswith("@@")
            else GREEN if line.startswith("+") and not line.startswith("+++")
            else RED if line.startswith("-") and not line.startswith("---")
            else GRAY
        )
        print("    " + paint(color, line))
    if len(lines) > limit:
        print("    " + paint(GRAY, f"... {len(lines) - limit} more diff lines"))


# ============================================================
# Manifest
# ============================================================


def load_manifest() -> dict[str, set[str]]:
    if not MANIFEST.exists():
        return {"managed": set(), "deleted": set()}
    try:
        data = json.loads(MANIFEST.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"invalid {MANIFEST.relative_to(ROOT)}: {exc}") from exc
    if not isinstance(data, dict):
        raise RuntimeError("update manifest must contain a JSON object")
    return {
        "managed": {str(x) for x in data.get("managed", [])},
        "deleted": {str(x) for x in data.get("deleted", [])},
    }


def save_manifest(data: dict[str, set[str]]) -> None:
    MANIFEST.parent.mkdir(parents=True, exist_ok=True)
    MANIFEST.write_text(
        json.dumps({
            "version": 1,
            "managed": sorted(data["managed"]),
            "deleted": sorted(data["deleted"] & data["managed"]),
        }, indent=2) + "\n",
        encoding="utf-8",
    )


def record_selected(selected: list[Candidate]) -> None:
    data = load_manifest()
    for candidate in selected:
        data["managed"].add(candidate.path)
        if candidate.action == "delete":
            data["deleted"].add(candidate.path)
        else:
            data["deleted"].discard(candidate.path)
    save_manifest(data)


def show_manifest() -> None:
    data = load_manifest()
    print()
    print(paint(PINK + BOLD, "alice's update manifest") + " " + paint(DIM, ":3"))
    print()
    if not data["managed"]:
        warn("manifest is empty")
        return
    for path in sorted(data["managed"]):
        label, color = ("DELETE", RED) if path in data["deleted"] else ("UPDATE", GREEN)
        print(f"    {paint(color, '[' + label + ']')} {path}")
    print()
    info("existing-system updates are limited to these paths")


# ============================================================
# Custom files (anything in your home you want shared)
# ============================================================

CUSTOM_FILE = ROOT / ".alice-sync" / "custom.json"


def load_custom() -> list[dict[str, str]]:
    try:
        data = json.loads(CUSTOM_FILE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []
    entries = []
    for item in data.get("paths", []) if isinstance(data, dict) else []:
        if isinstance(item, dict) and isinstance(item.get("live"), str) and isinstance(item.get("repo"), str):
            entries.append({"live": item["live"], "repo": item["repo"]})
    return entries


def save_custom(entries: list[dict[str, str]]) -> None:
    CUSTOM_FILE.parent.mkdir(parents=True, exist_ok=True)
    CUSTOM_FILE.write_text(json.dumps({"version": 1, "paths": entries}, indent=2) + "\n", encoding="utf-8")


def register_custom_group() -> None:
    """Expose the user's own files as the extra rice part `custom`."""
    entries = load_custom()
    if entries:
        GROUPS["custom"] = ("Custom files", tuple(
            Mapping(Path(e["live"]).expanduser(), ROOT / e["repo"]) for e in entries))
    else:
        GROUPS.pop("custom", None)


def builtin_cover(live: Path) -> str | None:
    """Which built-in rice part already syncs this path (if any)."""
    for key, (_label, mappings) in GROUPS.items():
        if key == "custom":
            continue
        for m in mappings:
            if live == m.live or m.live in live.parents:
                return key
    return None


def confirm(prompt: str, default_yes: bool = False) -> bool:
    if ASSUME_YES:
        return True
    answer = ask(prompt + (" [Y/n] " if default_yes else " [y/N] ")).strip().lower()
    return default_yes if not answer else answer in {"y", "yes"}


def add_custom(arg: str, repo_path: str | None = None) -> bool:
    live = Path(os.path.abspath(Path(arg).expanduser()))
    if not exists(live):
        raise RuntimeError(f"no such file or folder: {live}")
    if ignored(live):
        raise RuntimeError(f"{live.name} is on sync.py's ignore list")
    covered = builtin_cover(live)
    if covered and repo_path is None:
        info(f"{live} is already part of the built-in '{covered}' part — run: ./sync.py --part {covered}")
        return False
    if repo_path is None:
        try:
            repo_path = "home/" + live.relative_to(HOME).as_posix()
        except ValueError:
            raise RuntimeError("only paths inside your home folder can be added automatically; "
                               "pass --repo-path home/<where it should live> for others")
    rp = Path(repo_path)
    if rp.is_absolute() or ".." in rp.parts or rp.parts[:1] == (".git",) or not rp.parts:
        raise RuntimeError(f"bad repository path: {repo_path}")
    if rp.parts[0] != "home":
        warn("repository paths outside home/ are only installed by the installer if it already knows that folder")
    entries = [e for e in load_custom() if Path(e["live"]).expanduser() != live]
    entries.append({"live": "~/" + live.relative_to(HOME).as_posix() if live.is_relative_to(HOME) else str(live),
                    "repo": rp.as_posix()})
    save_custom(entries)
    register_custom_group()
    ok(f"{live} will now be synced to {rp.as_posix()}")
    return True


def remove_custom(arg: str) -> bool:
    live = Path(os.path.abspath(Path(arg).expanduser()))
    entries = load_custom()
    keep = [e for e in entries if Path(e["live"]).expanduser() != live]
    if len(keep) == len(entries):
        warn(f"{arg} isn't one of your custom files (see ./sync.py --list-custom)")
        return False
    save_custom(keep)
    register_custom_group()
    ok(f"no longer syncing {live}")
    info("its copy in the repo and its manifest entry stay until you remove them "
         "(./sync.py --manifest-remove PATH, then git rm)")
    return True


def list_custom() -> None:
    entries = load_custom()
    print()
    if not entries:
        info("no custom files yet — add one with: ./sync.py --add ~/.config/foo/foo.conf")
        return
    print(paint(PINK + BOLD, "custom files") + paint(DIM, "  (live → repo)"))
    for e in entries:
        print(f"    {e['live']}  {paint(GRAY, '→')}  {e['repo']}")


# ============================================================
# Manifest tools
# ============================================================


def to_repo_files(arg: str, must_exist_in_repo: bool = True) -> list[str]:
    """Turn a repo-relative path, a live path, or a folder of either into repo file paths."""
    raw = Path(arg).expanduser()
    candidates: list[Path] = []
    if not raw.is_absolute() and exists(ROOT / raw):
        candidates.append(ROOT / raw)
    live = Path(os.path.abspath(raw))
    for _key, (_label, mappings) in GROUPS.items():
        for m in mappings:
            if live == m.live:
                candidates.append(m.repo)
            elif m.live in live.parents:
                candidates.append(m.repo / live.relative_to(m.live))
    if live.is_relative_to(HOME):
        candidates.append(ROOT / "home" / live.relative_to(HOME))
    found: list[str] = []
    for c in candidates:
        if exists(c):
            if c.is_dir() and not c.is_symlink():
                found += [repo_relative(f) for f in sorted(c.rglob("*"))
                          if (f.is_file() or f.is_symlink()) and not ignored(f)]
            elif not ignored(c):
                found.append(repo_relative(c))
            break
    if not found and not must_exist_in_repo:
        found.append(arg.strip("/"))
    return list(dict.fromkeys(found))


def manifest_add(args: list[str]) -> None:
    data = load_manifest()
    added = 0
    for arg in args:
        files = to_repo_files(arg)
        if not files:
            warn(f"{arg}: not in the repository yet — share it first with ./sync.py --add {arg}")
            continue
        for f in files:
            data["managed"].add(f)
            data["deleted"].discard(f)
            added += 1
    save_manifest(data)
    ok(f"{added} file(s) marked as shared")


def manifest_remove(args: list[str]) -> None:
    data = load_manifest()
    removed = 0
    for arg in args:
        wanted = set(to_repo_files(arg, must_exist_in_repo=False))
        prefix = arg.strip("/") + "/"
        wanted |= {x for x in data["managed"] if x.startswith(prefix)}
        for f in wanted & data["managed"]:
            data["managed"].discard(f)
            data["deleted"].discard(f)
            removed += 1
    save_manifest(data)
    ok(f"{removed} file(s) un-shared") if removed else warn("nothing matched")


def manifest_clear() -> None:
    data = load_manifest()
    if not data["managed"]:
        info("the manifest is already empty")
        return
    if not confirm(f"remove all {len(data['managed'])} entries? existing systems get no updates until you re-add files"):
        info("left as it was")
        return
    save_manifest({"managed": set(), "deleted": set()})
    ok("manifest cleared — commit it when you're ready (git add .alice-sync && git commit)")


def manifest_edit() -> None:
    save_manifest(load_manifest())   # make sure it exists, sorted and tidy
    original = MANIFEST.read_text(encoding="utf-8")
    editor = (os.environ.get("VISUAL") or os.environ.get("EDITOR")
              or next((e for e in ("nano", "vim", "vi") if shutil.which(e)), ""))
    if not editor:
        raise RuntimeError("no editor found — set $EDITOR (or edit .alice-sync/update-manifest.json yourself)")
    while True:
        subprocess.run([*shlex.split(editor), str(MANIFEST)], check=False)
        try:
            data = load_manifest()
            break
        except Exception as exc:   # noqa: BLE001
            fail(f"that isn't a valid manifest: {exc}")
            # without a person at the keyboard (--yes) there is nobody to fix it: put it back
            if ASSUME_YES or not confirm("open it again to fix it?", default_yes=True):
                MANIFEST.write_text(original, encoding="utf-8")
                warn("restored the previous manifest")
                return
    save_manifest(data)   # normalise: sorted, deleted ⊆ managed
    ok(f"manifest saved ({len(data['managed'])} entries)")
    missing = sorted(x for x in data["managed"] - data["deleted"] if not exists(ROOT / x))
    for path in missing:
        warn(f"{path} is listed but isn't in the repo — the installer would complain")


def tools_menu() -> None:
    while True:
        clear()
        print()
        print(paint(PINK + BOLD, "alice's rice sync") + " " + paint(DIM, "· tools"))
        print()
        items = [
            ("1", "review and sync changes"), ("2", "add a file or folder to sync"),
            ("3", "list my custom files"), ("4", "stop syncing a custom file"),
            ("5", "show the update manifest"), ("6", "edit the manifest by hand"),
            ("7", "clear the manifest"), ("q", "quit"),
        ]
        for key, label in items:
            print(f"  {paint(PINK, key.rjust(2))}  {label}")
        print()
        choice = ask("choice: ").strip().lower()
        try:
            if choice in {"q", "quit", ""}:
                return
            if choice == "1":
                groups = choose_groups()
                if groups:
                    run_sync(groups, dry=False, do_push=False)
            elif choice == "2":
                path = ask("path to add (file or folder in your home): ").strip()
                if path and add_custom(path) and confirm("sync it now?", default_yes=True):
                    run_sync(["custom"], dry=False, do_push=False)
            elif choice == "3":
                list_custom()
            elif choice == "4":
                list_custom()
                path = ask("path to stop syncing: ").strip()
                if path:
                    remove_custom(path)
            elif choice == "5":
                show_manifest()
            elif choice == "6":
                manifest_edit()
            elif choice == "7":
                manifest_clear()
        except RuntimeError as exc:
            fail(str(exc))
        ask("press enter to continue… ")


# ============================================================
# Candidate scanning
# ============================================================


def scan_mapping(mapping: Mapping, manifest: dict[str, set[str]]) -> list[Candidate]:
    live_map = file_map(mapping.live)
    repo_map = file_map(mapping.repo)
    candidates: list[Candidate] = []

    for relative in sorted(set(live_map) | set(repo_map)):
        live = live_map.get(relative)
        repo = mapping.repo if relative == Path(".") else mapping.repo / relative
        if live is None and relative in repo_map:
            repo = repo_map[relative]
        if ignored(repo):
            continue

        live_exists = live is not None and exists(live)
        repo_exists = exists(repo)
        if not live_exists and not repo_exists:
            continue
        if live_exists and not repo_exists:
            action = "add"
        elif repo_exists and not live_exists:
            action = "delete"
        elif same(live, repo):
            continue
        else:
            action = "update"

        path = repo_relative(repo)
        candidates.append(Candidate(
            path=path,
            live=live,
            repo=repo,
            action=action,
            repo_dirty=path in TRACKED and repo_dirty(path),
            shared=path in manifest["managed"],
        ))

    return candidates


def find_candidates_by_group(groups: list[str]) -> dict[str, list[Candidate]]:
    manifest = load_manifest()
    result: dict[str, dict[str, Candidate]] = {}

    for group in groups:
        bucket: dict[str, Candidate] = {}
        for mapping in GROUPS[group][1]:
            for candidate in scan_mapping(mapping, manifest):
                bucket[candidate.path] = candidate
        result[group] = dict(sorted(bucket.items()))

    return {
        group: list(bucket.values())
        for group, bucket in result.items()
    }


def find_candidates(groups: list[str]) -> list[Candidate]:
    grouped = find_candidates_by_group(groups)
    result: list[Candidate] = []
    for group in groups:
        result.extend(grouped.get(group, []))
    return result


# ============================================================
# Selection / commit
# ============================================================


def print_candidate(candidate: Candidate) -> None:
    label, color = {
        "add": ("NEW", GREEN),
        "delete": ("DEL", RED),
        "update": ("UPD", YELLOW),
    }[candidate.action]
    flags = []
    if candidate.shared:
        flags.append("already shared")
    if candidate.repo_dirty:
        flags.append("repo copy already modified")
    suffix = f"  [{', '.join(flags)}]" if flags else ""
    print(f"    {paint(color, '[' + label + ']')} {candidate.path}{paint(GRAY, suffix)}")


def show_overview(groups: list[str], candidates_by_group: dict[str, list[Candidate]]) -> list[Candidate]:
    """Show every detected live-vs-repo change before asking for approval."""
    print()
    say("live configuration changes detected")
    print(paint(GRAY, "the list below is everything that differs in the selected rice parts"))

    all_candidates: list[Candidate] = []
    number = 1

    for group in groups:
        candidates = candidates_by_group.get(group, [])
        label = GROUPS[group][0]
        print()
        print(paint(PURPLE + BOLD, label))

        if not candidates:
            print(f"    {paint(GRAY, 'no changes')}")
            continue

        for candidate in candidates:
            action_label, color = {
                "add": ("NEW", GREEN),
                "delete": ("DEL", RED),
                "update": ("UPD", YELLOW),
            }[candidate.action]

            flags = []
            if candidate.shared:
                flags.append("already shared")
            if candidate.repo_dirty:
                flags.append("repo already modified")

            suffix = f"  {paint(GRAY, '[' + ', '.join(flags) + ']')}" if flags else ""
            print(
                f"  {paint(CYAN, str(number).rjust(2))} "
                f"{paint(color, '[' + action_label + ']')} "
                f"{candidate.path}{suffix}"
            )

            all_candidates.append(candidate)
            number += 1

    return all_candidates


def parse_selection(value: str, candidates: list[Candidate]) -> list[Candidate] | None:
    """Parse `all`, `none`, numbers, or numeric ranges."""
    answer = value.strip().lower()

    if answer in {"", "all", "a", "yes", "y"}:
        return list(candidates)

    if answer in {"none", "n", "no", "q", "quit"}:
        return []

    selected_indexes: set[int] = set()
    tokens = answer.replace(",", " ").split()

    try:
        for token in tokens:
            if "-" in token:
                left, right = token.split("-", 1)
                start = int(left)
                end = int(right)
                if start > end:
                    start, end = end, start
                for value in range(start, end + 1):
                    if 1 <= value <= len(candidates):
                        selected_indexes.add(value - 1)
            else:
                value = int(token)
                if 1 <= value <= len(candidates):
                    selected_indexes.add(value - 1)
    except ValueError:
        return None

    return [candidates[i] for i in sorted(selected_indexes)]


def approve_changes(candidates: list[Candidate]) -> list[Candidate]:
    """Let the user approve the already-displayed changes."""
    if not candidates:
        print()
        ok("the selected rice parts match the repository")
        return []

    print()
    warn("approved files become part of the shared rice and can update other computers")

    answer = ask("approve ALL of these changes? [Y/n] ", "y").strip().lower()

    if answer in {"", "y", "yes", "a", "all"}:
        return candidates

    if answer in {"n", "no"}:
        print()
        info("choose specific files by number")
        info("examples: 1 3 5    or    1-4 8")
        chosen = ask("files to approve: ")
        selected = parse_selection(chosen, candidates)
        if selected is None:
            warn("invalid selection")
            return []
        return selected

    # Also allow directly entering the file numbers at the first prompt.
    selected = parse_selection(answer, candidates)
    if selected is None:
        warn("invalid selection")
        return []
    return selected


def review_diffs(selected: list[Candidate]) -> list[Candidate]:
    """Optional final diff review before anything is written."""
    if not selected:
        return []

    print()
    say("final review")
    for candidate in selected:
        print_candidate(candidate)
        show_diff(candidate)

    print()
    answer = ask("send these approved changes to the repository? [Y/n] ", "y").strip().lower()
    if answer in {"", "y", "yes"}:
        return selected

    info("cancelled; repository was not changed")
    return []


def copy_candidate(candidate: Candidate) -> None:
    if candidate.action == "delete":
        if exists(candidate.repo):
            if candidate.repo.is_dir() and not candidate.repo.is_symlink():
                shutil.rmtree(candidate.repo)
            else:
                candidate.repo.unlink()
        return

    if candidate.live is None or not exists(candidate.live):
        raise RuntimeError(f"live file disappeared: {candidate.path}")

    candidate.repo.parent.mkdir(parents=True, exist_ok=True)
    if exists(candidate.repo):
        if candidate.repo.is_dir() and not candidate.repo.is_symlink():
            shutil.rmtree(candidate.repo)
        else:
            candidate.repo.unlink()

    if candidate.live.is_symlink():
        candidate.repo.symlink_to(candidate.live.readlink())
    elif candidate.live.is_file():
        shutil.copy2(candidate.live, candidate.repo, follow_symlinks=False)
        try:
            text = candidate.repo.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            return
        home = str(HOME)
        if home in text:
            candidate.repo.write_text(text.replace(home, "@HOME@"), encoding="utf-8")
    else:
        raise RuntimeError(f"unsupported live path: {candidate.live}")


def commit_selected(selected: list[Candidate], groups: list[str], dry: bool) -> bool:
    if not selected:
        return False
    if dry:
        show_selected(selected)
        ok("dry-run: nothing was written")
        return False

    for candidate in selected:
        copy_candidate(candidate)

    record_selected(selected)
    paths = sorted({x.path for x in selected})
    paths.append(repo_relative(MANIFEST))
    if exists(CUSTOM_FILE):   # the registry travels with the files so fresh installs know about them
        paths.append(repo_relative(CUSTOM_FILE))

    git("add", "-A", "--", *paths)
    staged = {
        x for x in git("diff", "--cached", "--name-only", "-z", "--", *paths).stdout.split("\0") if x
    }
    if not staged:
        info("nothing changed after staging")
        return False

    show_selected(selected)
    default = "sync: update " + " + ".join(groups)
    message = ask(f"commit message [{default}]: ").strip() or default
    git("commit", "--only", "-m", message, "--", *paths, live=True)
    ok("sync commit created")
    return True


def show_selected(selected: list[Candidate]) -> None:
    print()
    say("changes going into the shared rice")
    for candidate in selected:
        label, color = {
            "add": ("NEW", GREEN),
            "delete": ("DEL", RED),
            "update": ("UPD", YELLOW),
        }[candidate.action]
        print(f"    {paint(color, '[' + label + ']')} {candidate.path}")


# ============================================================
# Push
# ============================================================


def push() -> None:
    if unmerged():
        raise RuntimeError("resolve existing git conflicts before pushing")

    remote = upstream()
    if remote is None:
        branch = git("branch", "--show-current").stdout.strip()
        remotes = [x.strip() for x in git("remote").stdout.splitlines() if x.strip()]
        if not branch or not remotes:
            raise RuntimeError("repository needs a branch and remote before pushing")
        git("push", "-u", remotes[0], branch, live=True)
        ok("repository pushed")
        return

    git("fetch", "--prune", live=True)
    behind, _ = remote_counts()
    stash_ref: str | None = None

    try:
        if behind:
            if git("status", "--porcelain").stdout.strip():
                git("stash", "push", "--include-untracked", "-m", "alice-sync temporary protection", live=True)
                stash_ref = git("stash", "list", "-1", "--format=%H").stdout.strip()
                if not stash_ref:
                    raise RuntimeError("temporary stash could not be verified")
            result = git("rebase", "@{u}", live=True, check=False)
            if result.returncode:
                git("rebase", "--abort", live=True, check=False)
                raise RuntimeError("remote rebase failed; it was safely aborted")

        result = git("push", live=True, check=False)
        if result.returncode:
            warn("push was rejected because the remote changed; retrying once")
            git("fetch", "--prune", live=True)
            result = git("rebase", "@{u}", live=True, check=False)
            if result.returncode:
                git("rebase", "--abort", live=True, check=False)
                raise RuntimeError("remote rebase failed during retry")
            git("push", live=True)
        ok("repository pushed")
    finally:
        if stash_ref:
            result = git("stash", "apply", stash_ref, check=False)
            if result.returncode == 0:
                git("stash", "drop", stash_ref, check=False)
                ok("pre-existing repository changes restored")
            else:
                warn(f"could not restore pre-existing changes; stash remains at {stash_ref}")


# ============================================================
# Group selection / CLI
# ============================================================


def choose_groups() -> list[str]:
    clear()
    print()
    print(paint(PINK + BOLD, "alice's rice sync") + " " + paint(DIM, ":3"))
    print(paint(GRAY, "compare live configuration against the repository"))
    print()
    names = list(GROUPS)
    for index, name in enumerate(names, 1):
        print(f"  {paint(PINK, str(index).rjust(2))}  {GROUPS[name][0]}  {paint(GRAY, '(' + name + ')')}")
    print(f"  {paint(PINK, ' m')}  multiple")
    print(f"  {paint(PINK, ' t')}  tools (manifest, add files)")
    print(f"  {paint(PINK, ' q')}  quit")
    print()

    answer = ask("choice: ").strip().lower()
    if answer in {"q", "quit", "exit"}:
        return []
    if answer in {"t", "tools"}:
        tools_menu()
        return []
    if answer in {"m", "multiple"}:
        answer = ask("parts (example: quickshell,niri): ").strip().lower()
    if answer.isdigit() and 0 < int(answer) <= len(names):
        return [names[int(answer) - 1]]

    parts = [x.strip().lower() for x in answer.replace(" ", ",").split(",") if x.strip()]
    unknown = [x for x in parts if x not in GROUPS]
    if unknown:
        raise RuntimeError("unknown rice part: " + ", ".join(unknown))
    return list(dict.fromkeys(parts))


def usage() -> None:
    print(__doc__.strip())
    print("\nparts:")
    for key, (label, _) in GROUPS.items():
        print(f"  {key:<12} {label}")


def run_sync(groups: list[str], dry: bool, do_push: bool) -> int:
    global TRACKED
    TRACKED = tracked_files()
    conflicts = unmerged()
    if conflicts:
        raise RuntimeError("resolve existing git conflicts first: " + ", ".join(conflicts))

    grouped_candidates = find_candidates_by_group(groups)
    candidates = show_overview(groups, grouped_candidates)
    selected = approve_changes(candidates)

    if not selected:
        info("nothing selected; repository was not changed")
        return 0

    # Optional diff review happens after the user has chosen which files
    # should be shared. This keeps the initial screen concise while still
    # making the exact live-vs-repo content easy to inspect.
    review = ask("review the exact diffs before saving? [y/N] ", "n").strip().lower()
    if review in {"y", "yes", "d", "diff"}:
        selected = review_diffs(selected)
        if not selected:
            return 0

    show_selected(selected)
    if dry:
        ok("dry-run: nothing was written or committed")
        return 0

    committed = commit_selected(selected, groups, dry=False)
    if committed and do_push:
        push()
    print()
    ok("rice sync finished :3")
    return 0


VALUE_OPTS = {"--part", "--repo-path"}
LIST_OPTS = {"--add", "--remove-custom", "--manifest-add", "--manifest-remove"}
FLAG_OPTS = {"--dry-run", "--push", "--yes", "-y", "--manifest", "--manifest-edit", "--manifest-clear",
             "--list-custom", "--tools"}


def parse_args(argv: list[str]) -> tuple[set[str], dict[str, str], dict[str, list[str]]]:
    flags: set[str] = set()
    values: dict[str, str] = {}
    lists: dict[str, list[str]] = {}
    i = 0
    while i < len(argv):
        arg = argv[i]
        name, eq, inline = arg.partition("=")
        if name in VALUE_OPTS:
            if eq:
                values[name] = inline
            elif i + 1 < len(argv):
                values[name] = argv[i + 1]
                i += 1
            else:
                raise RuntimeError(f"{name} needs a value")
        elif arg in LIST_OPTS:
            items: list[str] = []
            while i + 1 < len(argv) and not argv[i + 1].startswith("--"):
                items.append(argv[i + 1])
                i += 1
            if not items:
                raise RuntimeError(f"{arg} needs at least one path")
            lists[arg] = items
        elif arg in FLAG_OPTS:
            flags.add("--yes" if arg == "-y" else arg)
        else:
            raise RuntimeError(f"unknown option: {arg}")
        i += 1
    return flags, values, lists


def main(argv: list[str]) -> int:
    global ASSUME_YES
    if os.geteuid() == 0:
        raise RuntimeError("do not run sync.py as root")
    if shutil.which("git") is None:
        raise RuntimeError("git is required")
    if not (ROOT / ".git").is_dir():
        raise RuntimeError("sync.py must be inside the dotfiles git repository")

    if argv == ["--help"] or argv == ["-h"]:
        usage()
        return 0

    flags, values, lists = parse_args(argv)
    ASSUME_YES = "--yes" in flags
    register_custom_group()

    # ---- tools that don't sync anything ----
    if "--manifest" in flags:
        show_manifest()
        return 0
    if "--list-custom" in flags:
        list_custom()
        return 0
    if "--manifest-edit" in flags:
        manifest_edit()
        return 0
    if "--manifest-clear" in flags:
        manifest_clear()
        return 0
    if "--manifest-add" in lists:
        manifest_add(lists["--manifest-add"])
        return 0
    if "--manifest-remove" in lists:
        manifest_remove(lists["--manifest-remove"])
        return 0
    if "--remove-custom" in lists:
        for path in lists["--remove-custom"]:
            remove_custom(path)
        return 0
    if "--tools" in flags:
        tools_menu()
        return 0
    if "--add" in lists:
        added = [p for p in lists["--add"] if add_custom(p, values.get("--repo-path"))]
        if added and confirm("sync it now?", default_yes=True):
            return run_sync(["custom"], "--dry-run" in flags, "--push" in flags)
        if added:
            info("run ./sync.py --part custom whenever you want to review and share it")
        return 0

    # ---- the normal sync flow ----
    part = values.get("--part")
    groups = [x.strip().lower() for x in part.split(",") if x.strip()] if part else list(GROUPS)
    unknown = [x for x in groups if x not in GROUPS]
    if unknown:
        raise RuntimeError("unknown rice part: " + ", ".join(unknown)
                           + ("  (add files first: ./sync.py --add PATH)" if "custom" in unknown else ""))
    if not groups:
        info("bye :3")
        return 0
    return run_sync(groups, "--dry-run" in flags, "--push" in flags)


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
