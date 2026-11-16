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
run_test "wt new refuses branch already attached to a worktree" '
  "$WT" new feat/dup >/dev/null
  if "$WT" new feat/dup >/dev/null 2>&1; then
    fail "duplicate branch name was accepted while worktree exists"
  fi
'

# ------------------------------------------------------------------------------
run_test "wt new attaches to existing branch when no worktree uses it" '
  git branch feat/orphan
  "$WT" new feat/orphan >/dev/null
  assert_file_exists "$MAIN_REPO/../feat-orphan/.git"
  assert_eq "$(git -C "$MAIN_REPO/../feat-orphan" rev-parse --abbrev-ref HEAD)" "feat/orphan" "branch"
'

# ------------------------------------------------------------------------------
run_test "wt new recovers when worktree folder was deleted manually" '
  "$WT" new feat/lost >/dev/null
  rm -rf "$MAIN_REPO/../feat-lost"   # nuke folder, leaving stale worktree metadata
  "$WT" new feat/lost >/dev/null
  assert_file_exists "$MAIN_REPO/../feat-lost/.git"
  assert_eq "$(git -C "$MAIN_REPO/../feat-lost" rev-parse --abbrev-ref HEAD)" "feat/lost" "branch"
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

# ------------------------------------------------------------------------------
# Global-install scenario: symlink wt into a separate ~/bin-style dir, with
# no scripts/ inside the user repo at all. Mirrors the README install path.
run_test "wt works when invoked through a symlink (global install)" '
  bin_dir="$TEST_DIR/bin"
  mkdir -p "$bin_dir"
  ln -sf "$SCRIPTS_DIR/wt" "$bin_dir/wt"
  # Remove the in-repo copy of scripts to make sure the global wt does not
  # secretly depend on it.
  rm -rf "$MAIN_REPO/scripts"
  git add -A && git commit -q -m "drop scripts dir"

  "$bin_dir/wt" new feat/global >/dev/null
  assert_file_exists "$MAIN_REPO/../feat-global/.git"
  out=$("$bin_dir/wt" list 2>&1)
  echo "$out" | grep -q "feat/global" || fail "feat/global not in list"
'

# ------------------------------------------------------------------------------
run_test "kill yes preserves dirty and untracked data without force" '
  "$WT" new feat/safe >/dev/null
  target="$TEST_DIR/feat-safe"
  echo dirty > "$target/shared.txt"
  echo local > "$target/untracked"
  if "$WT" kill feat/safe --yes </dev/null >/dev/null 2>&1; then fail "dirty removal succeeded"; fi
  assert_eq "$(cat "$target/shared.txt")" dirty
  git -C "$target" restore shared.txt
  if "$WT" kill feat/safe -y </dev/null >/dev/null 2>&1; then fail "untracked removal succeeded"; fi
  assert_eq "$(cat "$target/untracked")" local
  "$WT" kill feat/safe -y -f >/dev/null
  [ ! -d "$target" ] || fail "explicit force did not remove worktree"
'

run_test "kill interactive confirmation does not authorize force" '
  "$WT" new feat/dirty >/dev/null
  echo dirty > "$TEST_DIR/feat-dirty/shared.txt"
  if printf "y\ny\n" | "$WT" kill feat/dirty >/dev/null 2>&1; then fail "confirmation authorized force"; fi
  assert_eq "$(cat "$TEST_DIR/feat-dirty/shared.txt")" dirty
  printf "y\n" | "$WT" kill feat/dirty --force >/dev/null
'

run_test "kill reports removal and branch deletion errors" '
  "$WT" new feat/locked >/dev/null
  git worktree lock "$TEST_DIR/feat-locked"
  if "$WT" kill feat/locked -y --force >/dev/null 2>&1; then fail "locked removal succeeded"; fi
  git worktree unlock "$TEST_DIR/feat-locked"
  mkdir "$TEST_DIR/bin"
  real_git=$(command -v git)
  printf "#!/bin/bash\nif [ \"\$1\" = branch ] && [ \"\$2\" = -D ]; then exit 42; fi\nexec \"%s\" \"\$@\"\n" "$real_git" > "$TEST_DIR/bin/git"
  chmod +x "$TEST_DIR/bin/git"
  if PATH="$TEST_DIR/bin:$PATH" "$WT" kill feat/locked -y -D >/dev/null 2>&1; then fail "branch deletion failure hidden"; fi
  git show-ref --verify --quiet refs/heads/feat/locked
'

run_test "setup refuses main before touching files symlinks or RUN" '
  echo source > source
  ln -s source local-link
  printf "LINK shared.txt\nCOPY local-link\nRUN touch marker\n" > .worktree-config
  if "$WT" setup >/dev/null 2>&1; then fail "main setup succeeded"; fi
  if (cd scripts && "$WT" setup) >/dev/null 2>&1; then fail "main subdirectory setup succeeded"; fi
  [ ! -L shared.txt ] || fail "main regular file replaced"
  assert_eq "$(cat shared.txt)" "shared content"
  assert_eq "$(readlink local-link)" source
  [ ! -e marker ] || fail "RUN executed in main"
'

run_test "setup normalizes subdirectory and isolates RUN cd and exit" '
  git worktree add -b feat/root "$TEST_DIR/feat-root" >/dev/null
  printf "RUN cd /\nRUN exit 0\nRUN pwd > root-marker\nLINK shared.txt\n" > .worktree-config
  mkdir "$TEST_DIR/feat-root/subdir"
  (cd "$TEST_DIR/feat-root/subdir" && "$WT" setup) >/dev/null
  assert_eq "$(cat "$TEST_DIR/feat-root/root-marker")" "$(cd "$TEST_DIR/feat-root" && pwd -P)"
  assert_symlink_to "$TEST_DIR/feat-root/shared.txt" "$MAIN_REPO/shared.txt"
  [ ! -e "$TEST_DIR/feat-root/subdir/shared.txt" ] || fail "setup used subdirectory"
'

run_test "setup preserves ignored contents inside tracked directories" '
  mkdir tracked
  echo tracked > tracked/file
  echo ignored > .gitignore
  git add tracked .gitignore && git commit -q -m tracked
  git worktree add -b feat/ignored "$TEST_DIR/feat-ignored" >/dev/null
  echo precious > "$TEST_DIR/feat-ignored/tracked/ignored"
  printf "LINK tracked\n" > .worktree-config
  (cd "$TEST_DIR/feat-ignored" && "$WT" setup) >/dev/null
  assert_eq "$(cat "$TEST_DIR/feat-ignored/tracked/ignored")" precious
  [ ! -L "$TEST_DIR/feat-ignored/tracked" ] || fail "directory replaced"
'

run_test "setup preserves local symlinks and refuses symlink parents" '
  git worktree add -b feat/symlinks "$TEST_DIR/feat-symlinks" >/dev/null
  target="$TEST_DIR/feat-symlinks"
  mkdir "$TEST_DIR/outside" nested
  echo original > "$TEST_DIR/outside/file"
  echo incoming > nested/file
  ln -s "$TEST_DIR/outside" "$target/nested"
  ln -s missing "$target/local-link"
  echo source > local-link
  printf "COPY local-link\nCOPY nested/file\nRUN touch later\n" > .worktree-config
  if (cd "$target" && "$WT" setup) >/dev/null 2>&1; then fail "symlink parent accepted"; fi
  assert_eq "$(readlink "$target/local-link")" missing
  assert_eq "$(cat "$TEST_DIR/outside/file")" original
  [ ! -e "$target/later" ] || fail "continued after failure"
'

run_test "COPY preserves source directory symlinks without dereferencing" '
  git worktree add -b feat/copy-link "$TEST_DIR/feat-copy-link" >/dev/null
  mkdir "$TEST_DIR/source-dir"
  echo precious > "$TEST_DIR/source-dir/file"
  ln -s "$TEST_DIR/source-dir" source-link
  printf "COPY source-link\n" > .worktree-config
  (cd "$TEST_DIR/feat-copy-link" && "$WT" setup) >/dev/null
  assert_symlink_to "$TEST_DIR/feat-copy-link/source-link" "$TEST_DIR/source-dir"
  assert_eq "$(cat "$TEST_DIR/source-dir/file")" precious
'

run_test "setup refuses escaping and metadata paths" '
  git worktree add -b feat/paths "$TEST_DIR/feat-paths" >/dev/null
  for path in ../escape "$MAIN_REPO/shared.txt" .git/config; do
    printf "COPY %s\nRUN touch later\n" "$path" > .worktree-config
    if (cd "$TEST_DIR/feat-paths" && "$WT" setup) >/dev/null 2>&1; then fail "unsafe path accepted: $path"; fi
    [ ! -e "$TEST_DIR/feat-paths/later" ] || fail "continued after invalid path"
  done
'

run_test "new propagates RUN failure and preserves worktree" '
  printf "RUN exit 23\nRUN touch later\n" > .worktree-config
  status=0
  "$WT" new feat/failure >/dev/null 2>&1 || status=$?
  assert_eq "$status" 23
  assert_file_exists "$TEST_DIR/feat-failure/.git"
  [ ! -e "$TEST_DIR/feat-failure/later" ] || fail "continued after RUN failure"
  git show-ref --verify --quiet refs/heads/feat/failure
'

run_test "setup reports COPY LINK mkdir and rm failures and stops" '
  git worktree add -b feat/io "$TEST_DIR/feat-io" >/dev/null
  mkdir "$TEST_DIR/bin"
  for op in cp ln mkdir rm; do
    printf "#!/bin/bash\nexit 31\n" > "$TEST_DIR/bin/$op"
    chmod +x "$TEST_DIR/bin/$op"
    case "$op" in
      cp) echo data > fresh; printf "COPY fresh\n" > .worktree-config ;;
      ln) printf "LINK fresh\n" > .worktree-config ;;
      mkdir) mkdir -p deep; echo data > deep/file; printf "COPY deep/file\n" > .worktree-config ;;
      rm) printf "LINK shared.txt\n" > .worktree-config ;;
    esac
    echo "RUN touch later" >> .worktree-config
    if (cd "$TEST_DIR/feat-io" && PATH="$TEST_DIR/bin:$PATH" "$WT" setup) >/dev/null 2>&1; then fail "$op failure hidden"; fi
    [ ! -e "$TEST_DIR/feat-io/later" ] || fail "continued after $op failure"
    /bin/rm "$TEST_DIR/bin/$op"
  done
'

# Follow-up safety regressions: Git status is not a complete data-loss check.
run_test "setup normalizes directory suffixes and exclude anchors" '
  mkdir config-dir exclude-dir anchored
  echo config > config-dir/file
  echo exclude > exclude-dir/file
  echo anchor > anchored/file
  printf "LINK config-dir/\n" > .worktree-config
  printf "exclude-dir/\n/anchored\ndist/\n" > .git/info/exclude
  "$WT" new feat/normalized >/dev/null
  target="$TEST_DIR/feat-normalized"
  assert_symlink_to "$target/config-dir" "$MAIN_REPO/config-dir"
  assert_symlink_to "$target/exclude-dir" "$MAIN_REPO/exclude-dir"
  assert_symlink_to "$target/anchored" "$MAIN_REPO/anchored"
  [ ! -e "$target/dist" ] || fail "missing source unexpectedly created"
'

run_test "setup skips unsafe exclude entries and overlapping children" '
  mkdir .idea
  echo original > .idea/ws.xml
  printf ".idea\n.idea/ws.xml\n../unsafe\n//absolute\n!negation\n.git/config\nRUN touch-not-a-command\n" > .git/info/exclude
  git worktree add -b feat/excludes "$TEST_DIR/feat-excludes" >/dev/null
  (cd "$TEST_DIR/feat-excludes" && "$WT" setup) >/dev/null
  assert_symlink_to "$TEST_DIR/feat-excludes/.idea" "$MAIN_REPO/.idea"
  assert_eq "$(cat .idea/ws.xml)" original
'

run_test "setup preserves ignored data inside submodules" '
  make_main_repo "$TEST_DIR/sub-source"
  git -c protocol.file.allow=always submodule add "$TEST_DIR/sub-source" modules/sub >/dev/null 2>&1
  git commit -q -am submodule
  git worktree add -b feat/submodule "$TEST_DIR/feat-submodule" >/dev/null
  target="$TEST_DIR/feat-submodule"
  git -C "$target" -c protocol.file.allow=always submodule update --init >/dev/null 2>&1
  (cd "$target/modules/sub" && echo secret >> "$(git rev-parse --git-path info/exclude)")
  echo precious > "$target/modules/sub/secret"
  assert_eq "$(git -C "$target" status --porcelain --ignored -- modules)" ""
  for path in modules modules/sub; do
    printf "LINK %s\n" "$path" > .worktree-config
    (cd "$target" && "$WT" setup) >/dev/null
    assert_eq "$(cat "$target/modules/sub/secret")" precious
    [ ! -L "$target/$path" ] || fail "gitlink target replaced"
  done
'

run_test "setup preserves ignored nested repository metadata" '
  mkdir tracked
  echo committed > tracked/file
  echo nested > .gitignore
  git add tracked .gitignore && git commit -q -m tracked
  git worktree add -b feat/nested "$TEST_DIR/feat-nested" >/dev/null
  target="$TEST_DIR/feat-nested"
  make_main_repo "$target/tracked/nested"
  echo precious > "$target/tracked/nested/secret"
  printf "LINK tracked\n" > .worktree-config
  (cd "$target" && "$WT" setup) >/dev/null
  assert_eq "$(cat "$target/tracked/nested/secret")" precious
  assert_file_exists "$target/tracked/nested/.git"
'

run_test "setup preserves nested bare repository data" '
  mkdir tracked
  echo committed > tracked/file
  git add tracked && git commit -q -m tracked
  git worktree add -b feat/bare-data "$TEST_DIR/feat-bare-data" >/dev/null
  target="$TEST_DIR/feat-bare-data"
  git init -q --bare "$target/tracked/bare.git"
  echo precious > "$target/tracked/bare.git/secret"
  printf "LINK tracked\n" > .worktree-config
  (cd "$target" && "$WT" setup) >/dev/null
  assert_eq "$(cat "$target/tracked/bare.git/secret")" precious
  assert_file_exists "$target/tracked/bare.git/HEAD"
'

run_test "new reports missing or non executable setup and preserves worktree" '
  for mode in missing non-executable; do
    cp "$SCRIPTS_DIR/wt-setup" scripts/wt-setup
    case "$mode" in
      missing) rm scripts/wt-setup ;;
      non-executable) chmod -x scripts/wt-setup ;;
    esac
    if "$MAIN_REPO/scripts/wt-new" "feat/$mode" >/dev/null 2>&1; then fail "$mode setup accepted"; fi
    assert_file_exists "$TEST_DIR/feat-$mode/.git"
    git show-ref --verify --quiet "refs/heads/feat/$mode"
  done
'

run_test "setup preserves assume unchanged and skip worktree files and directories" '
  mkdir tracked
  echo committed > tracked/file
  git add tracked && git commit -q -m tracked
  git worktree add -b feat/flags "$TEST_DIR/feat-flags" >/dev/null
  target="$TEST_DIR/feat-flags"
  for flag in assume-unchanged skip-worktree; do
    git -C "$target" update-index "--$flag" shared.txt tracked/file
    echo precious > "$target/shared.txt"
    echo precious > "$target/tracked/file"
    assert_eq "$(git -C "$target" status --porcelain -- shared.txt tracked)" ""
    printf "LINK shared.txt\nLINK tracked\n" > .worktree-config
    (cd "$target" && "$WT" setup) >/dev/null
    assert_eq "$(cat "$target/shared.txt")" precious
    assert_eq "$(cat "$target/tracked/file")" precious
    git -C "$target" update-index "--no-$flag" shared.txt tracked/file
    git -C "$target" restore shared.txt tracked/file
  done
'

run_test "setup treats pathspec magic filenames literally" '
  magic=":(literal)shared.txt"
  echo committed > "$magic"
  git --literal-pathspecs add -- "$magic" && git commit -q -m literal
  git worktree add -b feat/literal "$TEST_DIR/feat-literal" >/dev/null
  target="$TEST_DIR/feat-literal"
  echo precious > "$target/$magic"
  printf "LINK %s\n" "$magic" > .worktree-config
  (cd "$target" && "$WT" setup) >/dev/null
  assert_eq "$(cat "$target/$magic")" precious
  [ ! -L "$target/$magic" ] || fail "dirty literal path replaced"
'

run_test "kill detached worktree with delete branch exits successfully" '
  target="$TEST_DIR/detached"
  git worktree add --detach "$target" >/dev/null
  "$WT" kill detached -y -D >/dev/null
  [ ! -d "$target" ] || fail "detached worktree remains"
'

echo
echo "================================================="
echo "Passed: $PASS  Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed tests:"
  for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
  exit 1
fi
