#!/usr/bin/env bash
# full install test in a throwaway HOME. nothing touches your real home.
cd "$(dirname "${BASH_SOURCE[0]}")"
FAKE="$(mktemp -d)"
pass=0; fail=0
ok()  { echo "  PASS  $*"; pass=$((pass+1)); }
bad() { echo "  FAIL  $*"; fail=$((fail+1)); }

echo "== 1. install into $FAKE"
if env -u XDG_CONFIG_HOME -u XDG_DATA_HOME HOME="$FAKE" ./install.sh --no-deps >/dev/null 2>"$FAKE/install.err"; then
  ok "install.sh exits 0"
else bad "install.sh failed"; fi
[ -s "$FAKE/install.err" ] && { echo "  installer warnings:"; sed 's/^/    /' "$FAKE/install.err"; }
[ -d "$FAKE/.config/niri" ] || bad "nothing was installed (niri config missing)"

echo "== 2. placeholders and stale paths"
left=$(grep -rIl '@HOME@' "$FAKE" --exclude=install.err 2>/dev/null)
[ -z "$left" ] && ok "no @HOME@ left" || { bad "@HOME@ left in:"; echo "$left"; }
stale=$(grep -rIn '/home/' "$FAKE" --exclude=install.err 2>/dev/null | grep -v '/home/user' | head)
[ -z "$stale" ] && ok "no hardcoded /home paths" || { bad "hardcoded /home paths:"; echo "$stale"; }

echo "== 3. every path the configs point at exists"
missing=0
while read -r p; do
  [ -e "$p" ] || { bad "missing: $p"; missing=1; }
done < <(grep -rIhoE "$FAKE/[A-Za-z0-9_./+-]+" "$FAKE/.config" "$FAKE/.local" 2>/dev/null | sed 's/[.,;:]*$//' | sort -u)
[ $missing = 0 ] && ok "all referenced paths exist"

echo "== 4. niri config"
niri validate -c "$FAKE/.config/niri/config.kdl" && ok "niri validate" || bad "niri validate"

echo "== 5. programs niri launches"
export PATH="$FAKE/.local/bin:$PATH"
while read -r c; do
  command -v "$c" >/dev/null && ok "found $c" || bad "not found: $c"
done < <(grep -rh 'spawn' "$FAKE/.config/niri" | grep -v '^\s*//' | grep -oE 'spawn[a-z-]* +"[^"]+"' \
         | sed -E 's/^spawn[a-z-]* +"//; s/"$//' | awk '{print $1}' | grep -vE '^(sh|bash)$' | sort -u)

echo "== 6. scripts parse"
for f in "$FAKE"/.local/bin/*; do
  [ -f "$f" ] || continue
  case "$(head -1 "$f")" in
    *python*) python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$f" 2>/dev/null && ok "$(basename "$f")" || bad "$(basename "$f")";;
    *sh*)     bash -n "$f" 2>/dev/null && ok "$(basename "$f")" || bad "$(basename "$f")";;
    *)        ok "$(basename "$f") (not checked)";;
  esac
done

echo "== 7. wallfliper python imports"
python3 - "$FAKE/.local/share/wallfliper" <<'PY'
import ast, sys, pathlib, importlib.util
root = pathlib.Path(sys.argv[1])
local = {p.name for p in root.iterdir()} | {p.stem for p in root.iterdir()}
mods = set()
for f in root.rglob("*.py"):
    try: t = ast.parse(f.read_text())
    except Exception as e: print("  FAIL  syntax:", f, e); continue
    for n in ast.walk(t):
        if isinstance(n, ast.Import): mods |= {a.name.split(".")[0] for a in n.names}
        elif isinstance(n, ast.ImportFrom) and n.level == 0 and n.module: mods.add(n.module.split(".")[0])
miss = sorted(m for m in mods if m not in local and m not in sys.stdlib_module_names and importlib.util.find_spec(m) is None)
print("  PASS  all python imports resolve" if not miss else f"  FAIL  missing python modules: {miss}")
PY

echo "== 8. package names exist"
eval "$(sed -n '/^PKGS=(/,/^AUR_PKGS=/p' install.sh)"
for p in "${PKGS[@]}"; do pacman -Si "$p" &>/dev/null && ok "repo: $p" || bad "not in repos: $p"; done
for p in "${AUR_PKGS[@]}"; do
  if pacman -Si "$p" &>/dev/null; then ok "repo: $p"
  elif command -v yay >/dev/null && yay -Si "$p" &>/dev/null; then ok "aur: $p"
  else bad "not found: $p"; fi
done

echo "== 9. tools the rice mentions (compare against PKGS)"
for t in dunst swaync swaylock rofi wofi starship grim slurp wl-copy wl-paste playerctl brightnessctl awww swww kvantum nmcli bluetoothctl pactl wpctl notify-send jq cliphist neowall; do
  grep -rIlw --exclude-dir=.git --exclude=install.sh --exclude=test-install.sh --exclude=sync.sh -- "$t" . >/dev/null 2>&1 && echo "  used: $t"
done

echo "== 10. themes, swaync, kvantum, bash"
for p in .bashrc .bash_profile .config/swaync/config.json .config/swaync/style.css .config/Kvantum/kvantum.kvconfig \
         .local/share/color-schemes/AliceNight.colors .local/share/themes/AliceNight .icons/Bibata-Material-Cloud; do
  [ -e "$FAKE/$p" ] && ok "installed ~/$p" || bad "missing ~/$p"
done
bash -n "$FAKE/.bashrc" && ok ".bashrc parses" || bad ".bashrc has syntax errors"

echo; echo "$pass passed, $fail failed   (fake home kept at $FAKE)"
exit $((fail > 0))
