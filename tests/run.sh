#!/bin/bash
# Test bodies are intentionally single-quoted so $TEST_DIR / $MAIN_REPO are
# expanded later by `eval` inside run_test, after each test's sandbox is set up.
# shellcheck disable=SC2016,SC2034,SC2181

# ==============================================================================
# tests/run.sh — Smoke tests for worktree-utils.
#
# Spins up a throw-away git repository in a temp dir, copies the scripts in,
# and exercises each command end-to-end. Asserts visible behaviour: file
# contents, symlink targets, exit codes.
#
# Usage:
#   tests/run.sh           # run all tests
#   tests/run.sh -v        # verbose (print every command)
# ==============================================================================

set -uo pipefail

VERBOSE=0
[[ "${1:-}" == "-v" ]] && VERBOSE=1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/scripts"
WT="$SCRIPTS_DIR/wt"

PASS=0
FAIL=0
FAILED_TESTS=()

# Each test runs in its own sandbox dir, cleaned up at the end of run_test.
# `TEST_DIR` and `MAIN_REPO` are exported for use inside test bodies.
TMP_ROOT=$(mktemp -d -t wt-utils-tests.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT

log()  { echo "  $*"; }
fail() { echo "  ❌ $*"; return 1; }

assert_eq() {
  local actual="$1" expected="$2" label="${3:-}"
  if [ "$actual" = "$expected" ]; then return 0; fi
  fail "${label:+$label: }expected [$expected], got [$actual]"
}

assert_file_exists() {
  if [ ! -e "$1" ]; then fail "expected $1 to exist"; fi
}

_resolve_parent() {
  # Normalise via the parent directory; works with BSD and GNU userland.
  local p="$1"
  printf '%s/%s' "$(cd "$(dirname "$p")" && pwd -P)" "$(basename "$p")"
}

assert_symlink_to() {
  local link="$1" target="$2"
  [ -L "$link" ] || { fail "$link is not a symlink"; return 1; }
  local actual expected
  actual=$(_resolve_parent "$(readlink "$link")")
  expected=$(_resolve_parent "$target")
  [ "$actual" = "$expected" ] || fail "$link → $actual (expected $expected)"
}

# Prepare a fresh main repo with the scripts wired in.
make_main_repo() {
  local dir="$1"
  mkdir -p "$dir"
  (
    cd "$dir"
    git init -q -b main
    git config user.email tests@example.com
    git config user.name "Test"
    cp -R "$SCRIPTS_DIR" "$dir/scripts"
    chmod +x "$dir/scripts/"*
    echo "shared content" > shared.txt
    git add -A
    git commit -q -m "initial"
  )
}

run_test() {
  local name="$1" body="$2"
  local slug="${name// /_}"
  slug="${slug//./}"
  local sandbox="$TMP_ROOT/$slug"
  mkdir -p "$sandbox"
  echo "▶ $name"
  (
    set -e
    [ "$VERBOSE" = 1 ] && set -x
    export TEST_DIR="$sandbox"
    export MAIN_REPO="$sandbox/main"
    make_main_repo "$MAIN_REPO"
    cd "$MAIN_REPO"
    eval "$body"
  )
  if [ $? -eq 0 ]; then
    PASS=$((PASS + 1))
    echo "  ✅ pass"
  else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("$name")
    echo "  ❌ fail"
  fi
}

# ------------------------------------------------------------------------------
run_test "wt new creates branch and dir" '
  "$WT" new feat/foo >/dev/null
  assert_file_exists "$TEST_DIR/main/../feat-foo/.git"
  assert_eq "$(git -C "$MAIN_REPO/../feat-foo" rev-parse --abbrev-ref HEAD)" "feat/foo" "branch"
'

# ------------------------------------------------------------------------------
run_test "wt new respects WT_BASE_DIR via .env" '
  printf "WT_BASE_DIR=%q\n" "$TEST_DIR/wts" > .env
  git add .env && git commit -q -m env
  "$WT" new feat/bar >/dev/null
  assert_file_exists "$TEST_DIR/wts/feat-bar/.git"
'

# ------------------------------------------------------------------------------
run_test ".env.local overrides .env" '
  printf "WT_BASE_DIR=%q\n" "$TEST_DIR/from-env" > .env
  printf "WT_BASE_DIR=%q\n" "$TEST_DIR/from-local" > .env.local
  git add .env && git commit -q -m env
  "$WT" new feat/baz >/dev/null
  assert_file_exists "$TEST_DIR/from-local/feat-baz/.git"
  if [ -e "$TEST_DIR/from-env/feat-baz/.git" ]; then
    fail ".env should have been overridden by .env.local"
  fi
'

# ------------------------------------------------------------------------------
run_test "wt new rejects invalid branch names" '
  if "$WT" new "..bad" >/dev/null 2>&1; then
    fail "invalid branch name was accepted"
  fi
  if "$WT" new "with space" >/dev/null 2>&1; then
    fail "branch name with space was accepted"
  fi
'

# ------------------------------------------------------------------------------
run_test "wt new refuses existing branch" '
  "$WT" new feat/dup >/dev/null
  if "$WT" new feat/dup >/dev/null 2>&1; then
    fail "duplicate branch name was accepted"
  fi
'

# ------------------------------------------------------------------------------
run_test "wt setup links files from .worktree-config" '
  cat > .worktree-config <<EOF
LINK shared.txt
EOF
  echo shared.txt > .git/info/exclude
  git add .worktree-config && git commit -q -m cfg
  "$WT" new feat/link >/dev/null
  assert_symlink_to "$MAIN_REPO/../feat-link/shared.txt" "$MAIN_REPO/shared.txt"
'

# ------------------------------------------------------------------------------
run_test "wt setup COPY produces independent file" '
  echo template > .env.template
  cat > .worktree-config <<EOF
COPY .env.template
EOF
  git add .env.template .worktree-config && git commit -q -m cfg
  "$WT" new feat/copy >/dev/null
  cp_target="$MAIN_REPO/../feat-copy/.env.template"
  assert_file_exists "$cp_target"
  if [ -L "$cp_target" ]; then fail "expected real file, got symlink"; fi
  echo modified > "$cp_target"
  if [ "$(cat .env.template)" != "template" ]; then
    fail "modifying copy affected source"
  fi
'

# ------------------------------------------------------------------------------
run_test "wt setup handles paths with spaces" '
  mkdir -p "shared dir"
  echo content > "shared dir/file.txt"
  cat > .worktree-config <<EOF
LINK shared dir
EOF
  git add . && git commit -q -m space
  "$WT" new feat/spaces >/dev/null
  assert_symlink_to "$MAIN_REPO/../feat-spaces/shared dir" "$MAIN_REPO/shared dir"
'

# ------------------------------------------------------------------------------
run_test "wt setup RUN executes command" '
  cat > .worktree-config <<EOF
RUN touch run-marker
EOF
  git add .worktree-config && git commit -q -m cfg
  "$WT" new feat/run >/dev/null
  assert_file_exists "$MAIN_REPO/../feat-run/run-marker"
'

# ------------------------------------------------------------------------------
run_test "wt setup skips existing local files" '
  cat > .worktree-config <<EOF
COPY shared.txt
EOF
  git add .worktree-config && git commit -q -m cfg
  target="$MAIN_REPO/../feat-existing"
  git worktree add -b feat/existing "$target" >/dev/null
  echo "local content" > "$target/shared.txt"
  (cd "$target" && "$SCRIPTS_DIR/wt-setup") >/dev/null 2>&1
  assert_eq "$(cat "$target/shared.txt")" "local content" "preserved local"
'

# ------------------------------------------------------------------------------
run_test "wt list shows all worktrees" '
  "$WT" new feat/aaa >/dev/null
  "$WT" new feat/bbb >/dev/null
  out=$("$WT" list 2>&1)
  echo "$out" | grep -q "feat/aaa" || fail "feat/aaa not in list"
  echo "$out" | grep -q "feat/bbb" || fail "feat/bbb not in list"
  echo "$out" | grep -q "main" || fail "main not in list"
'

# ------------------------------------------------------------------------------
run_test "wt kill removes worktree but keeps branch" '
  "$WT" new feat/kill-me >/dev/null
  echo y | "$WT" kill feat/kill-me >/dev/null
  if [ -d "$MAIN_REPO/../feat-kill-me" ]; then
    fail "directory should be removed"
  fi
  if ! git show-ref --verify --quiet refs/heads/feat/kill-me; then
    fail "branch should still exist"
  fi
'

# ------------------------------------------------------------------------------
run_test "wt kill -D also removes branch" '
  "$WT" new feat/kill-all >/dev/null
  echo y | "$WT" kill feat/kill-all -D >/dev/null
  if git show-ref --verify --quiet refs/heads/feat/kill-all; then
    fail "branch should be removed with -D"
  fi
'

# ------------------------------------------------------------------------------
run_test "wt kill refuses without confirmation" '
  "$WT" new feat/keep >/dev/null
  echo n | "$WT" kill feat/keep >/dev/null
  assert_file_exists "$MAIN_REPO/../feat-keep/.git"
'

# ------------------------------------------------------------------------------
run_test "wt kill refuses to touch main worktree" '
  if "$WT" kill main -y >/dev/null 2>&1; then
    fail "main worktree should not be killable"
  fi
'

# ------------------------------------------------------------------------------
run_test "wt kill prompts on multiple matches" '
  "$WT" new feat/multi-a >/dev/null
  "$WT" new feat/multi-b >/dev/null
  # Send "" (just newline) to cancel; should leave both intact.
  echo "" | "$WT" kill multi >/dev/null 2>&1 || true
  assert_file_exists "$MAIN_REPO/../feat-multi-a/.git"
  assert_file_exists "$MAIN_REPO/../feat-multi-b/.git"
'

# ------------------------------------------------------------------------------
run_test ".worktree-config: bare path defaults to LINK" '
  cat > .worktree-config <<EOF
shared.txt
EOF
  git add .worktree-config && git commit -q -m cfg
  "$WT" new feat/bare >/dev/null
  assert_symlink_to "$MAIN_REPO/../feat-bare/shared.txt" "$MAIN_REPO/shared.txt"
'

# ------------------------------------------------------------------------------
run_test ".worktree-config: glob patterns are skipped, not crashed" '
  cat > .worktree-config <<EOF
LINK *.log
LINK shared.txt
EOF
  git add .worktree-config && git commit -q -m cfg
  out=$("$WT" new feat/glob 2>&1)
  echo "$out" | grep -q "glob" || fail "expected glob warning"
  assert_symlink_to "$MAIN_REPO/../feat-glob/shared.txt" "$MAIN_REPO/shared.txt"
'

# ------------------------------------------------------------------------------
run_test "WT_BASE_DIR from real env beats .env values" '
  printf "WT_BASE_DIR=%q\n" "$TEST_DIR/from-file" > .env
  git add .env && git commit -q -m env
  WT_BASE_DIR="$TEST_DIR/from-shell" "$WT" new feat/envwins >/dev/null
  assert_file_exists "$TEST_DIR/from-shell/feat-envwins/.git"
  if [ -e "$TEST_DIR/from-file/feat-envwins/.git" ]; then
    fail ".env should not override real env"
  fi
'

echo
echo "================================================="
echo "Passed: $PASS  Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed tests:"
  for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
  exit 1
fi
