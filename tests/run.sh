#!/bin/bash
# Tests for agent-awake. Runs against a throwaway home folder, so it never
# touches your real config or your real holder. The folder has a space in its
# name on purpose.
#
#   tests/run.sh

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_HOME="$HOME"
TMP="$(mktemp -d)"
export HOME="$TMP/my home"
unset CLAUDE_CONFIG_DIR CODEX_HOME AGENT_AWAKE_DIR
export AGENT_AWAKE_POLL=1
export AGENT_AWAKE_MAX_AGE=60
A="$HOME/.local/bin/agent-awake"
CACHE="$HOME/.cache/agent-awake"
fails=0

cleanup() {
  [ -x "$A" ] && "$A" off >/dev/null 2>&1
  pkill -f "^/bin/bash $A _hold" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

ok()   { echo "  ok    $1"; }
bad()  { echo "  FAIL  $1"; fails=$((fails + 1)); }
is()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
holder_pids() { ps -axo pid=,command= | grep -F "/bin/bash $A _hold" | grep -v -e grep -e lockf | awk '{print $1}'; }
holders()     { holder_pids | wc -l | tr -d ' '; }
caffeinates() {
  local n=0 p
  for p in $(holder_pids); do
    n=$((n + $(pgrep -f "caffeinate -d -i -w $p\$" | wc -l)))
  done
  echo "$n"
}
# Test helper only: the expression is a fixed string from this file, never input.
jq_py() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))" "$1" "$2"; }
same() { python3 -c "import json,sys; print('same' if json.load(open(sys.argv[1]))==json.load(open(sys.argv[2])) else 'differs')" "$1" "$2"; }
install() { "$REPO/install.sh" "$@" >"$TMP/install.out" 2>&1; }

fresh_home() {
  [ -x "$A" ] && "$A" off >/dev/null 2>&1
  rm -rf "$HOME"; mkdir -p "$HOME/.claude" "$HOME/.codex"
  # Existing config that must survive: other hooks in odd shapes, other keys, non-ASCII text.
  cat > "$HOME/.claude/settings.json" <<'J'
{
  "model": "opus",
  "permissions": {"allow": ["Bash(echo café)"]},
  "hooks": {
    "Stop": [
      {"matcher": "", "hooks": [{"type": "command", "command": "echo mine"}]},
      {"matcher": "Bash"},
      {"matcher": "Edit", "hooks": []}
    ],
    "Notification": [],
    "PreToolUse": [
      {"hooks": [{"type": "command", "command": "echo hi; \"$HOME/.local/bin/agent-awake\" end claude"}]},
      {"hooks": [{"type": "command", "command": "\"/opt/other/my-agent-awake\" beat x"}]}
    ]
  }
}
J
  cat > "$HOME/.codex/hooks.json" <<'J'
{
    "description": "mine",
    "hooks": {
        "Stop": [
            {"hooks": [{"type": "command", "command": "echo mine", "async": true}]}
        ]
    }
}
J
}

echo "install"
fresh_home
cp "$HOME/.claude/settings.json" "$TMP/claude.orig"; cp "$HOME/.codex/hooks.json" "$TMP/codex.orig"
install --dry-run
is "dry run changes nothing" "$(cmp -s "$HOME/.claude/settings.json" "$TMP/claude.orig" && [ ! -e "$A" ] && echo same)" "same"
install; is "install exits 0" "$?" "0"
"$A" check >/dev/null 2>&1; is "check says in sync" "$?" "0"
is "claude keeps its own Stop hook" "$(jq_py "$HOME/.claude/settings.json" "d['hooks']['Stop'][0]['hooks'][0]['command']")" "echo mine"
is "claude keeps other keys and text" "$(jq_py "$HOME/.claude/settings.json" "d['model']+d['permissions']['allow'][0]")" "opusBash(echo café)"
is "codex keeps its own Stop hook first" "$(jq_py "$HOME/.codex/hooks.json" "d['hooks']['Stop'][0]['hooks'][0]['command']")" "echo mine"
is "codex keeps 4-space indent" "$(sed -n 2p "$HOME/.codex/hooks.json" | grep -c '^    "')" "1"
is "codex is told about the approval" "$(grep -c 'Codex asks you to approve' "$TMP/install.out")" "1"
is "backups written" "$(ls "$HOME/.claude" "$HOME/.codex" | grep -c 'bak-agent-awake')" "2"

cp "$HOME/.claude/settings.json" "$TMP/c1"; cp "$HOME/.codex/hooks.json" "$TMP/x1"
sleep 1; install
is "second install is a no-op" "$(cmp -s "$HOME/.claude/settings.json" "$TMP/c1" && cmp -s "$HOME/.codex/hooks.json" "$TMP/x1" && echo same)" "same"
is "second install writes no new backup" "$(ls "$HOME/.claude" "$HOME/.codex" | grep -c 'bak-agent-awake')" "2"

echo "uninstall"
install --uninstall
is "claude config is back to the original, other hooks untouched" "$(same "$HOME/.claude/settings.json" "$TMP/claude.orig")" "same"
is "codex config is back to the original" "$(same "$HOME/.codex/hooks.json" "$TMP/codex.orig")" "same"
is "command and cache are gone" "$([ -e "$A" ] || [ -e "$CACHE" ] && echo there || echo gone)" "gone"
is "uninstall says the backups are kept" "$(grep -c 'backups' "$TMP/install.out")" "1"
rm -rf "$HOME/.codex"; mkdir "$HOME/.codex"; install; install --uninstall
is "a file we created is left without our hooks" "$(jq_py "$HOME/.codex/hooks.json" "d")" "{'hooks': {}}"

echo "careful with your files"
fresh_home
mkdir "$HOME/dotfiles"; mv "$HOME/.claude/settings.json" "$HOME/dotfiles/s.json"; ln -s "$HOME/dotfiles/s.json" "$HOME/.claude/settings.json"
chmod 600 "$HOME/dotfiles/s.json"
install
is "a symlinked config stays a symlink" "$([ -L "$HOME/.claude/settings.json" ] && echo link)" "link"
is "the real file behind the link got the 4 hooks (plus the 2 foreign lines)" "$(grep -c 'agent-awake' "$HOME/dotfiles/s.json")" "6"
is "a private config stays private (600)" "$(stat -f %Lp "$HOME/dotfiles/s.json")" "600"
for shape in '{"hooks": null}' '{"hooks": []}' '[]' '{"hooks":{"Stop":null}}' '{ not json'; do
  fresh_home; printf '%s' "$shape" > "$HOME/.claude/settings.json"
  install; rc=$?
  is "odd config $shape: exit 2, no traceback, file untouched, nothing linked" \
     "$rc/$(grep -c Traceback "$TMP/install.out")/$(cat "$HOME/.claude/settings.json")/$([ -e "$A" ] && echo linked || echo none)" "2/0/$shape/none"
done
fresh_home; printf '{"hooks":{"Stop":["x"],"Other":[{"hooks":[{"command":null}]}]}}' > "$HOME/.claude/settings.json"
install; is "strange entries inside a list are kept and do not stop the install" "$?/$(jq_py "$HOME/.claude/settings.json" "d['hooks']['Stop'][0]")" "0/x"

echo "check"
fresh_home; install
python3 - "$HOME/.claude/settings.json" <<'P'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); del d["hooks"]["PostToolUse"]; d["hooks"]["UserPromptSubmit"]=[]; json.dump(d,open(p,"w"),indent=2)
P
"$A" check >/dev/null 2>&1; is "missing hook is drift (exit 1)" "$?" "1"
install; "$A" check >/dev/null 2>&1; is "install repairs drift" "$?" "0"
mv "$HOME/.codex" "$TMP/codex.away"
"$A" check >"$TMP/check.out" 2>&1; is "an agent you do not have is skipped, not an error (exit 0)" "$?/$(grep -c '^skipped: Codex' "$TMP/check.out")" "0/1"
install; is "install skips an agent that is not there and does not mention approval" "$(grep -q '^skipped: Codex' "$TMP/install.out" && echo skipped)/$(grep -c 'approve' "$TMP/install.out")" "skipped/0"
mv "$TMP/codex.away" "$HOME/.codex"
chmod 000 "$HOME/.codex/hooks.json"
"$A" check >/dev/null 2>&1; is "unreadable file is could-not-check (exit 2), not drift" "$?" "2"
chmod 644 "$HOME/.codex/hooks.json"

echo "hook input"
fresh_home; install
beat() { "$A" beat claude; }
echo '{"session_id":"real-1","tool_input":{"session_id":"other-9"}}' | beat
is "the first session_id wins, not one nested in tool input" "$(ls "$CACHE/sessions")" "claude-real-1"
"$A" off >/dev/null
python3 -c "import sys; sys.stdout.write('{\"session_id\":\"big-1\",\"tool_response\":\"' + 'x'*3000000 + '\"}')" > "$TMP/big.json"
start=$(python3 -c "import time; print(time.time())")
beat < "$TMP/big.json"
took=$(python3 -c "import time,sys; print(1 if time.time()-float(sys.argv[1]) < 1.0 else 0)" "$start")
is "a 3 MB hook payload is handled in under a second" "$took/$(ls "$CACHE/sessions")" "1/claude-big-1"
"$A" off >/dev/null
printf '{"session_id":"../../etc/x y","a":"\xff\xfe"}' | beat
is "odd characters in an id cannot leave the sessions folder" "$(ls "$CACHE/sessions")" "claude-....etcxy"
"$A" off >/dev/null
printf 'not json at all' | beat; is "input that is not JSON falls back to one shared session" "$(ls "$CACHE/sessions")" "claude-default"
is "hook prints nothing (stdout goes into the agent's context)" "$(echo '{"session_id":"q"}' | "$A" beat claude 2>&1 | wc -c | tr -d ' ')" "0"
"$A" off >/dev/null

echo "running"
is "nothing held at start" "$(holders)/$(caffeinates)" "0/0"
for i in $(seq 80); do (echo "{\"session_id\":\"s$((i % 7))\"}" | "$A" beat claude) & done; wait; sleep 1.5
is "80 hooks at once: one holder, one caffeinate" "$(holders)/$(caffeinates)" "1/1"
is "7 sessions tracked" "$(ls "$CACHE/sessions" | wc -l | tr -d ' ')" "7"
sleep 5.5   # let the holders that queued up during the burst give up
old=$(cat "$CACHE/holder.pid"); kill -9 "$old"; sleep 0.5
is "after kill -9 the stale pid file is not believed and the lock is free at once" "$("$A" status | grep -c 'held awake: no')/$(/usr/bin/lockf -k -s -t 0 "$CACHE/holder.lock" /usr/bin/true && echo free)" "1/free"
for i in $(seq 80); do (echo "{\"session_id\":\"s$((i % 7))\"}" | "$A" beat codex) & done; wait; sleep 2
is "after kill -9, 80 at once: one holder, one caffeinate" "$(holders)/$(caffeinates)" "1/1"
pkill -f "caffeinate -d -i -w $(cat "$CACHE/holder.pid")\$"; echo '{"session_id":"s1"}' | "$A" beat claude; sleep 2.5
is "a killed caffeinate is started again" "$(holders)/$(caffeinates)" "1/1"
"$A" off >/dev/null
is "off releases at once" "$(holders)/$(caffeinates)" "0/0"

echo '{"session_id":"a"}' | "$A" beat claude; echo '{"session_id":"b"}' | "$A" beat codex; sleep 1
echo '{"session_id":"a"}' | "$A" end claude; sleep 1.5
is "one session ends, the other keeps the hold" "$(holders)/$(caffeinates)" "1/1"
echo '{"session_id":"b"}' | "$A" end codex; sleep 1.5
is "the last session ends and the hold drops" "$(holders)/$(caffeinates)" "0/0"

export AGENT_AWAKE_MAX_AGE=3
echo '{"session_id":"never-ends"}' | "$A" beat claude; sleep 1
is "holder up for a session that will never end" "$(holders)/$(caffeinates)" "1/1"
sleep 5
is "a session that never ends goes stale and releases" "$(holders)/$(caffeinates)" "0/0"
export AGENT_AWAKE_MAX_AGE=60

AGENT_AWAKE_POLL=15 AGENT_AWAKE_MAX_AGE=1200 "$A" beat claude </dev/null; sleep 1
is "holder up with the real 15 s poll" "$(holders)" "1"
AGENT_AWAKE_POLL=15 AGENT_AWAKE_MAX_AGE=1200 "$A" off >/dev/null
is "off releases at once with the real 15 s poll too" "$(holders)/$(caffeinates)" "0/0"

tail -f "$TMP/agent-awake _hold" 2>/dev/null & stranger=$!
: > "$TMP/agent-awake _hold"; echo "$stranger" > "$CACHE/holder.pid"
is "a foreign process in the pid file is not taken for the holder" "$("$A" status | grep -c 'held awake: no')" "1"
"$A" off >/dev/null; is "off does not kill a foreign process" "$(kill -0 "$stranger" 2>/dev/null && echo alive)" "alive"
echo '{"session_id":"z"}' | "$A" beat claude; sleep 1.5
is "a stale pid file does not block a new holder" "$(holders)/$(caffeinates)" "1/1"
kill "$stranger" 2>/dev/null; "$A" off >/dev/null

export AGENT_AWAKE_MAX_AGE=3
miss=0
for r in $(seq 8); do
  "$A" off >/dev/null; echo '{"session_id":"a"}' | "$A" beat claude; sleep 2.9
  echo '{"session_id":"b"}' | "$A" beat claude; sleep 1.3
  "$A" status | grep -q "yes" || miss=$((miss + 1))
done
is "a beat that lands while the holder exits is still covered (8 rounds)" "$miss" "0"
"$A" off >/dev/null

echo "house style"
is "no em dashes in anything a person reads" "$(cd "$REPO" && grep -rl $'\xe2\x80\x94' --exclude-dir=.git . | wc -l | tr -d ' ')" "0"
is "bash syntax" "$(bash -n "$REPO/bin/agent-awake" && bash -n "$REPO/install.sh" && echo ok)" "ok"

echo
if [ "$fails" -eq 0 ]; then echo "all passed"; else echo "$fails failed"; fi
export HOME="$REAL_HOME"
exit "$fails"
