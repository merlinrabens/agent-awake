#!/bin/bash
# Install or remove agent-awake.
#
#   ./install.sh              link the command and add the hooks
#   ./install.sh --dry-run    show what would change, change nothing
#   ./install.sh --uninstall  remove the hooks and the command
#
# Safe to run again. It only touches its own hook entries, keeps everything
# else in your config as it is, and writes a backup next to a file before it
# changes it.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
LINK="$BIN_DIR/agent-awake"
SOURCE="$REPO/bin/agent-awake"
MODE="install"
DRY=0

for arg in "$@"; do
  case "$arg" in
    --uninstall) MODE="uninstall" ;;
    --dry-run)   DRY=1 ;;
    -h|--help)   sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 64 ;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }
say() { echo "$*"; }

[ "$(uname -s)" = "Darwin" ] || die "macOS only. It needs caffeinate and lockf."
command -v caffeinate >/dev/null || die "caffeinate not found."
[ -x /usr/bin/lockf ] || die "/usr/bin/lockf not found."
[ -x /usr/bin/perl ] || die "/usr/bin/perl not found."
command -v python3 >/dev/null || die "python3 not found. Install the Xcode command line tools: xcode-select --install"
[ -x "$SOURCE" ] || die "$SOURCE is missing or not executable."

STAMP="$(date +%Y%m%d-%H%M%S)"

# 1. The hooks first. If a config file is in a shape we do not understand, we
#    stop here and have changed nothing.
set +e
python3 - "$MODE" "$DRY" "$STAMP" <<'PY'
import json, os, re, shutil, sys

mode, dry, stamp = sys.argv[1], sys.argv[2] == "1", sys.argv[3]
home = os.path.expanduser("~")
CMD = '"$HOME/.local/bin/agent-awake" {verb} {agent}'
EVENTS = [("UserPromptSubmit", "beat"), ("PostToolUse", "beat"), ("Stop", "end"), ("SessionEnd", "end")]
AGENTS = [
    # name, label, config dir, hook file, put an empty matcher on each group
    ("claude", "Claude Code", os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(home, ".claude"), "settings.json", True),
    ("codex", "Codex", os.environ.get("CODEX_HOME") or os.path.join(home, ".codex"), "hooks.json", False),
]


class Shape(Exception):
    pass


def groups_of(hooks, event):
    groups = hooks.get(event, [])
    if not isinstance(groups, list):
        raise Shape(f'"hooks.{event}" is not a list')
    return groups


def commands_in(group):
    """The commands in one group, or [] if the group has a shape we leave alone."""
    if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
        return []
    return [h.get("command") for h in group["hooks"] if isinstance(h, dict)]


def add(hooks, agent, matcher):
    for event, verb in EVENTS:
        cmd = CMD.format(verb=verb, agent=agent)
        groups = groups_of(hooks, event)
        if any(cmd in commands_in(g) for g in groups):
            continue
        # 3 seconds: Codex allows no more than that on SessionEnd.
        group = {"hooks": [{"type": "command", "command": cmd, "timeout": 3}]}
        if matcher:
            group = {"matcher": "", **group}
        hooks[event] = groups + [group]


def remove(hooks, agent):
    """Take out exactly the commands add() writes. Leave every other entry as it is."""
    ours = {CMD.format(verb=verb, agent=agent) for _, verb in EVENTS}
    for event in list(hooks):
        groups = groups_of(hooks, event)
        kept, touched = [], False
        for g in groups:
            if not any(c in ours for c in commands_in(g)):
                kept.append(g)
                continue
            touched = True
            rest = [h for h in g["hooks"] if not (isinstance(h, dict) and h.get("command") in ours)]
            if rest:
                kept.append({**g, "hooks": rest})
        if not touched:
            continue
        if kept:
            hooks[event] = kept
        else:
            del hooks[event]


def write(path, text, like):
    """Write next to the target, never readable by others before it has its final mode."""
    tmp = path + ".agent-awake.tmp"
    mode = (os.stat(like).st_mode & 0o777) if like else 0o600
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


failed = False
for agent, label, d, fname, matcher in AGENTS:
    if not os.path.isdir(d):
        print(f"skipped: {label} (not on this machine)")
        continue
    # Follow a symlink (dotfiles setups) so we edit the real file and keep the link.
    path = os.path.realpath(os.path.join(d, fname))
    try:
        raw = open(path).read() if os.path.exists(path) else ""
        if not raw.strip() and mode == "uninstall":
            print(f"in sync: {label} hooks (nothing to remove)")
            continue
        data = json.loads(raw) if raw.strip() else {}
        if not isinstance(data, dict):
            raise Shape("the top level is not an object")
        had_hooks = "hooks" in data
        hooks = data.get("hooks", {})
        if not isinstance(hooks, dict):
            raise Shape('"hooks" is not an object')
        before = json.dumps(data, sort_keys=True)
        hooks = dict(hooks)
        if mode == "install":
            add(hooks, agent, matcher)
        else:
            remove(hooks, agent)
        if hooks or had_hooks:
            data["hooks"] = hooks
    except (Shape, json.JSONDecodeError, OSError) as e:
        print(f"could not change: {label} hooks ({path}: {e}). Nothing was changed in it.")
        failed = True
        continue
    if json.dumps(data, sort_keys=True) == before:
        print(f"in sync: {label} hooks")
        continue
    if dry:
        print(f"would change: {path}")
        continue
    m = re.search(r'\n([ \t]+)"', raw)
    indent = m.group(1) if m else "  "
    out = json.dumps(data, indent=indent, ensure_ascii=False) + "\n"
    backup = ""
    if raw:
        backup = f"{path}.bak-agent-awake-{stamp}"
        shutil.copy2(path, backup)
    write(path, out, path if raw else None)
    print(f"changed: {path}" + (f" (backup: {backup})" if backup else ""))
    if agent == "codex" and mode == "install":
        print("Codex asks you to approve the new hooks once, the next time you start it.")
sys.exit(2 if failed else 0)
PY
hooks_rc=$?
set -e

# 2. The command itself: a symlink into this checkout, so "git pull" updates it.
if [ "$MODE" = "install" ]; then
  if [ "$hooks_rc" -ne 0 ]; then
    say "Stopped. Fix the file named above and run this again."
    exit "$hooks_rc"
  fi
  if [ -L "$LINK" ] && [ "$(readlink "$LINK")" = "$SOURCE" ]; then
    say "in sync: $LINK"
  elif [ "$DRY" -eq 1 ]; then
    say "would link: $LINK -> $SOURCE"
  else
    mkdir -p "$BIN_DIR"
    if [ -e "$LINK" ] || [ -L "$LINK" ]; then
      mv "$LINK" "$LINK.bak-$STAMP"
      say "backup: $LINK.bak-$STAMP"
    fi
    ln -s "$SOURCE" "$LINK"
    say "linked: $LINK -> $SOURCE"
  fi
else
  if [ "$DRY" -eq 1 ]; then
    if [ -L "$LINK" ]; then say "would remove: $LINK"; fi
  else
    if [ -x "$LINK" ]; then "$LINK" off >/dev/null 2>&1 || true; fi
    if [ -L "$LINK" ] && [ "$(readlink "$LINK")" = "$SOURCE" ]; then
      rm -f "$LINK"; say "removed: $LINK"
    fi
    rm -rf "${AGENT_AWAKE_DIR:-$HOME/.cache/agent-awake}"
    say "Kept: the .bak-agent-awake-* backups next to your config files. Delete them when you are sure."
  fi
  exit "$hooks_rc"
fi

# 3. Prove it.
if [ "$DRY" -eq 0 ]; then
  echo
  "$LINK" check || true
  echo
  say "Claude Code picks the hooks up by itself."
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) say "Note: $BIN_DIR is not on your PATH. The hooks work anyway. Add it to run 'agent-awake status' by name." ;;
  esac
fi
