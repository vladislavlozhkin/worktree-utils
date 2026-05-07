#!/bin/bash

# ==============================================================================
# wt-lib.sh: Shared helpers for worktree-utils.
# Sourced from each wt-* script. Each caller computes SCRIPT_DIR by resolving
# its own BASH_SOURCE[0] through symlinks (so `ln -s .../scripts/wt ~/bin/wt`
# still finds its sibling scripts), then sources this file from there.
# ==============================================================================

# wt_main_worktree
# Prints absolute path to the main worktree (first record of porcelain list).
wt_main_worktree() {
  git worktree list --porcelain | awk '/^worktree /{print substr($0,10); exit}'
}

# wt_list_worktrees
# Prints TAB-separated records: <path>\t<branch>\t<head>
# Branch is the short name (refs/heads/foo -> foo) or "(detached)".
# Paths can contain spaces — splitting on TAB is required by callers.
wt_list_worktrees() {
  git worktree list --porcelain | awk '
    /^worktree /  { path = substr($0, 10) }
    /^HEAD /      { head = substr($0, 6) }
    /^branch /    { branch = substr($0, 8); sub(/^refs\/heads\//, "", branch) }
    /^detached$/  { branch = "(detached)" }
    /^$/          { if (path != "") { printf "%s\t%s\t%s\n", path, branch, head; path=""; branch=""; head="" } }
    END           { if (path != "") printf "%s\t%s\t%s\n", path, branch, head }
  '
}

# wt_load_env_vars [main_worktree_path]
# Exports WT_* variables found in .env.local then .env in the given directory.
# Already-set environment variables win (highest precedence).
# Only lines matching ^WT_[A-Z0-9_]+= are honoured; values are expanded with
# eval to support ${HOME} and similar — files are user-owned config, same trust
# level as .worktree-config.
wt_load_env_vars() {
  local dir="${1:-$(wt_main_worktree)}"
  local file
  # Order matters: .env.local has higher precedence, so it must be processed
  # first under our "first wins" rule below.
  for file in "$dir/.env.local" "$dir/.env"; do
    [ -r "$file" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      # Strip leading whitespace and optional `export `.
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line#export }"
      # Skip comments / blanks / non-WT_ lines.
      [[ "$line" =~ ^WT_[A-Z0-9_]+= ]] || continue
      local name="${line%%=*}"
      local value="${line#*=}"
      # Strip matching surrounding quotes.
      if [[ "$value" =~ ^\"(.*)\"$ ]] || [[ "$value" =~ ^\'(.*)\'$ ]]; then
        value="${BASH_REMATCH[1]}"
      fi
      # Honour env precedence: do not overwrite an already-exported value.
      if [ -z "${!name+x}" ]; then
        # shellcheck disable=SC2086
        eval "export $name=\"\$value\""
      fi
    done < "$file"
  done
}
