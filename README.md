# claude-skills

Personal collection of Claude Code slash commands and skills.

Layout mirrors `~/.claude/` so installing is just copy/symlink:

```
commands/
  <name>.md            # the slash command body
  <name>/              # bundled artifacts (scripts, templates, config)
```

## Install

Copy (or symlink) `commands/` contents into `~/.claude/commands/`.

PowerShell:
```powershell
Copy-Item -Recurse -Force commands/* $HOME/.claude/commands/
```

Bash:
```bash
cp -r commands/* ~/.claude/commands/
```

## Commands

- **`/iterate-issues`** — Drain `ready-for-agent` GitHub issues into a single batch branch end-to-end, open one batch PR. Built for stacked queues. See `commands/iterate-issues.md`.
