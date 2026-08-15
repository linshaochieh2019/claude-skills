#!/usr/bin/env bash
# Auto-commit snapshots of Claude auto-memory corpora.
#
# Wired as a PostToolUse hook on Write|Edit.  Reads the hook payload on stdin,
# and if the written file lives under  ~/.claude/projects/<project>/memory/ ,
# commits that memory directory into a LOCAL git repo.
#
# Why per-write and not SessionEnd: the failure this guards against is one
# session whole-file overwriting MEMORY.md using a read it took 20 minutes
# earlier, silently dropping the index line another session appended in between.
# Committing at session end would snapshot the *result* of that overwrite;
# committing on every write captures the losing session's line before it is
# clobbered, so the overwrite shows up as a reviewable deletion in `git log -p`
# instead of vanishing without a trace.
#
# Invariants:
#   - LOCAL ONLY.  Never adds a remote, never pushes.  A memory corpus holds
#     operational context and customer names.
#   - Byte-exact.  core.autocrlf=false + `* -text` so a restore returns the
#     file the harness actually wrote, not a line-ending-rewritten copy.
#   - Never fails the tool call.  Every path exits 0.

set -uo pipefail

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

file=$(printf '%s' "$payload" \
  | jq -r '.tool_response.filePath // .tool_input.file_path // empty' 2>/dev/null)
[ -n "$file" ] || exit 0

# Normalise Windows separators and drive letters so the match below works
# whether the harness reports C:\Users\... or /c/Users/...
norm=$(printf '%s' "$file" | tr '\\' '/')
case "$norm" in
  [A-Za-z]:/*) norm="/$(printf '%s' "${norm%%:*}" | tr 'A-Z' 'a-z')/${norm#*:/}" ;;
esac

# Only act on files inside a  .claude/projects/<project>/memory/  tree.
case "$norm" in
  */.claude/projects/*/memory/*) : ;;
  *) exit 0 ;;
esac
mem="${norm%%/memory/*}/memory"
[ -d "$mem" ] || exit 0

if [ ! -d "$mem/.git" ]; then
  git -C "$mem" init -q -b main               2>/dev/null || exit 0
  git -C "$mem" config core.autocrlf false    2>/dev/null
  git -C "$mem" config core.safecrlf false    2>/dev/null
  git -C "$mem" config core.quotepath false   2>/dev/null
  [ -f "$mem/.gitattributes" ] || printf '* -text\n' > "$mem/.gitattributes"
fi

# Several claude.exe processes write here concurrently; index.lock contention is
# expected, not an error.  Retry briefly, then give up — the next write commits
# whatever this run missed, because `git add -A` always stages the full tree.
for _ in 1 2 3 4 5; do
  if git -C "$mem" add -A 2>/dev/null; then
    git -C "$mem" diff --cached --quiet 2>/dev/null && exit 0   # nothing new
    git -C "$mem" -c commit.gpgsign=false commit -q \
      -m "snapshot: $(date '+%Y-%m-%dT%H:%M:%S%z')" 2>/dev/null && exit 0
  fi
  sleep 0.4
done

exit 0
