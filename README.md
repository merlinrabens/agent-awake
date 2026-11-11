# agent-awake

Your Mac stays unlocked while Claude Code or Codex is working, and locks again as soon as they are done.

No more coming back to a job that died halfway because the screen locked and the agent could no longer click, type or drive the browser.

## Why you want this

Both apps already stop the Mac from sleeping. Neither stops the display from sleeping. So after a few idle minutes the display turns off, the lock kicks in, and everything that needs mouse and keyboard stops working: computer use, browser control, the iOS simulator.

The usual fixes are worse than the problem. Turning the lock off for good is a bad idea on a laptop. Running `caffeinate` by hand means you forget to start it, or forget to stop it.

agent-awake holds the display on only while an agent is actually working. When the work stops, your normal lock settings apply again.

## Install

macOS only. Needs `python3` for the installer (comes with the Xcode command line tools).

Tested on an Intel Mac with macOS 26, Claude Code 2.1 and Codex CLI 0.154. Nothing in it depends on the chip, but Apple Silicon has not been tested yet.

```bash
git clone https://github.com/merlinrabens/agent-awake.git ~/.agent-awake
```

```bash
~/.agent-awake/install.sh
```

That links the command into `~/.local/bin` and adds four hooks each to Claude Code and Codex, whichever of the two you have. It keeps everything else in your config as it is and writes a backup next to each file before it changes it.

Claude Code picks the hooks up by itself. Codex asks you to approve the four new hooks once, the next time you start it.

Want to look first? `~/.agent-awake/install.sh --dry-run` shows what would change and changes nothing.

## Use

There is nothing to do. Start working with your agent.

```bash
agent-awake status
```

```
working sessions:
  claude-3f2a9c1e-5b7d-4e60-9a12-0c4d8e6f1b23
  codex-0198c7aa-2e41-7b03-8d5f-6a9e3c1d4f70
display held awake: yes (holder pid 4242)
```

| Command | What it does |
|---|---|
| `agent-awake status` | Shows working sessions and whether the display is held |
| `agent-awake check` | Verifies the hooks and the command are still in place. Exit 0 in sync, 1 drift, 2 could not check |
| `agent-awake off` | Lets go right now |

## How it works

- Every prompt and every tool call touches a small file for that session. That costs a few hundredths of a second, also when a tool returns megabytes of output.
- One background process runs `caffeinate -d -i` for as long as any of those files is fresh.
- When the agent finishes, its file is removed and the hold drops within 15 seconds.
- If an agent crashes or you interrupt it, its file goes stale after 20 minutes and the hold drops by itself.

There is only ever one `caffeinate`, no matter how many sessions run or how many hooks fire at once. A kernel file lock (`lockf`) guarantees it, and the kernel releases that lock when the process dies, so there is never a stale lock to clean up. The tests fire 80 hooks at the same moment and kill the holder with `kill -9` to prove it.

If your config file is a symlink into a dotfiles folder, the installer edits the real file and keeps the link.

After a reboot nothing runs until the first prompt. There is no login item and no background service.

## What it does not do

- It changes no system setting.
- It does not stop the lock when you close the lid or press Ctrl+Cmd+Q.
- It does not keep the display on while an agent waits for you. No tool calls means no hold after 20 minutes.
- For the same reason, one single step that runs longer than 20 minutes without any tool call drops the hold. Raise `AGENT_AWAKE_MAX_AGE` if your jobs do that.
- It cannot beat a lock that your company's device management enforces.

On battery the display also stays on while an agent works. That costs runtime.

## Settings

Environment variables, if you want different timing:

| Variable | Default | Meaning |
|---|---|---|
| `AGENT_AWAKE_MAX_AGE` | `1200` | Seconds without a tool call before a session counts as dead |
| `AGENT_AWAKE_POLL` | `15` | Seconds between checks |

## Uninstall

```bash
~/.agent-awake/install.sh --uninstall
```

Removes its own hook entries, the command and its small state folder in `~/.cache`. Your other hooks stay exactly as they were.

Two things it leaves behind on purpose: the `.bak-agent-awake-*` backups next to your config files (delete them when you are sure), and the formatting of the config file, which is rewritten as plain indented JSON.

## Develop

```bash
tests/run.sh
```

The tests run against a throwaway home folder and never touch your real config. To run them before every push:

```bash
git config core.hooksPath .githooks
```

## License

MIT
