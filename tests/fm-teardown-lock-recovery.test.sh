#!/usr/bin/env bash
# tests/fm-teardown-lock-recovery.test.sh - transient / stale git index.lock
# recovery in bin/fm-teardown.sh.
#
# A crew process killed mid-git-operation leaves .git/worktrees/<wt>/index.lock
# behind, and `treehouse return --force` then fails with "Unable to create
# '...index.lock': File exists". The recovery is patience first (bounded retries)
# and force-removal only as a last resort - and that force-remove is the entire
# risk surface: deleting a lock believed stale corrupts the index of a LIVE
# worktree if the belief is wrong. So every direction is proven by attempting
# what it forbids:
#
#   A. live-held lock (lsof reports a holder) + old mtime -> NEVER removed
#   B. provably stale (no holder AND old mtime)           -> removed, return retried
#   C. lsof cannot answer (errors/unavailable)            -> NEVER removed, loud failure
#   D. transient lock, retry succeeds                     -> force-remove branch never entered
#
# The four cases run end to end through the real script (which also proves the
# wiring at both call sites); the two predicates the whole proof rests on -
# "is anything holding this?" and "is it provably stale?" - are additionally
# exercised directly, by sourcing the marked recovery block out of the script.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-lock)
# fm_test_tmproot registers its EXIT cleanup inside the command substitution, so
# the dir is already gone by the time we get the name; every suite recreates it.
mkdir -p "$TMP_ROOT"

# --- direct access to the recovery block ------------------------------------
#
# The block is delimited in fm-teardown.sh by FM-LOCK-RECOVERY-BEGIN/END so the
# safety predicates can be unit-tested without a real killed git process (and
# without a test-only seam in the production script). removal_target_abs_path is
# the one same-file helper the block leans on, so it comes along verbatim rather
# than being re-implemented here.
LOCK_LIB="$TMP_ROOT/lock-recovery-lib.sh"
{
  sed -n '/^removal_target_abs_path() {/,/^}/p' "$TEARDOWN"
  sed -n '/^# FM-LOCK-RECOVERY-BEGIN/,/^# FM-LOCK-RECOVERY-END/p' "$TEARDOWN"
} > "$LOCK_LIB"
grep -q '^removal_target_abs_path() {' "$LOCK_LIB" \
  || fail "could not extract removal_target_abs_path from fm-teardown.sh"
grep -q '^worktree_lock_is_provably_stale() {' "$LOCK_LIB" \
  || fail "could not extract the FM-LOCK-RECOVERY block from fm-teardown.sh"

export FM_STATE_OVERRIDE="$TMP_ROOT/lib-state"
# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"   # fm_path_mtime, the block's only cross-file dependency
# shellcheck source=/dev/null
. "$LOCK_LIB"
unset FM_STATE_OVERRIDE

# lsof stub whose answer is chosen by $FM_LSOF_MODE, recording every call so a
# test can prove lsof was never consulted at all.
#   holder - a live process holds the path (exit 0 with output)
#   none   - nothing holds it (exit 1, no output: lsof's real "no match")
#   error  - lsof cannot answer (exit 1 WITH output)
make_lsof_stub() {
  local fakebin=$1
  cat > "$fakebin/lsof" <<'SH'
#!/usr/bin/env bash
[ -n "${FM_LSOF_CALLS:-}" ] && printf '%s\n' "$*" >> "$FM_LSOF_CALLS"
case "${FM_LSOF_MODE:-none}" in
  holder) printf '%s\n' "COMMAND PID USER FD TYPE" "git 4242 crew 5w REG" ; exit 0 ;;
  none)   exit 1 ;;
  error)  echo "lsof: WARNING: can't stat() the filesystem" >&2 ; exit 1 ;;
esac
exit 1
SH
  chmod +x "$fakebin/lsof"
}

# --- unit: the "is anything holding this?" probe ----------------------------

# Run one predicate call with a chosen lsof behavior. Args: mode code...
with_lsof() {
  local mode=$1; shift
  local fakebin="$TMP_ROOT/unit-fakebin"
  mkdir -p "$fakebin"
  make_lsof_stub "$fakebin"
  (
    export PATH="$fakebin:$PATH" FM_LSOF_MODE="$mode"
    unset FM_LSOF_CALLS
    "$@"
  )
}

# Same, but with lsof genuinely absent from PATH. Only the externals the
# predicates themselves need are linked in, so `command -v lsof` really fails.
without_lsof() {
  local bindir="$TMP_ROOT/no-lsof-bin" tool
  mkdir -p "$bindir"
  for tool in uname stat date; do
    ln -sf "$(command -v "$tool")" "$bindir/$tool" 2>/dev/null || true
  done
  ( PATH="$bindir"; "$@" )
}

test_holder_probe_reports_live_holder() {
  local rc=0
  with_lsof holder worktree_lock_holder_state "$TMP_ROOT/some.lock" "$TMP_ROOT" || rc=$?
  [ "$rc" -eq 0 ] || fail "holder probe: a reported holder must be LIVE (0), got $rc"
  pass "lsof reporting a holder is read as a live holder"
}

test_holder_probe_reports_no_holder() {
  local rc=0
  with_lsof none worktree_lock_holder_state "$TMP_ROOT/some.lock" "$TMP_ROOT" || rc=$?
  [ "$rc" -eq 1 ] || fail "holder probe: lsof's no-match must be NONE (1), got $rc"
  pass "lsof reporting no match is read as no live holder"
}

test_holder_probe_errors_are_unknown_not_none() {
  local rc=0
  with_lsof error worktree_lock_holder_state "$TMP_ROOT/some.lock" "$TMP_ROOT" 2>/dev/null || rc=$?
  [ "$rc" -eq 2 ] || fail "holder probe: an lsof error must be UNKNOWN (2), never NONE; got $rc"
  pass "an lsof error is UNKNOWN, never mistaken for 'no holder'"
}

test_holder_probe_missing_lsof_is_unknown() {
  local rc=0
  without_lsof worktree_lock_holder_state "$TMP_ROOT/some.lock" "$TMP_ROOT" || rc=$?
  [ "$rc" -eq 2 ] || fail "holder probe: a missing lsof must be UNKNOWN (2), got $rc"
  pass "a missing lsof is UNKNOWN, never mistaken for 'no holder'"
}

# --- unit: the "provably stale?" predicate ANDs both proofs -----------------

make_lock() {  # <name> <old|fresh> -> echoes path
  local name=$1 age=$2 lock
  lock="$TMP_ROOT/$name.lock"
  : > "$lock"
  [ "$age" = old ] && touch -t 202001010000 "$lock"
  printf '%s\n' "$lock"
}

test_provably_stale_only_when_both_proofs_hold() {
  local old fresh rc
  old=$(make_lock stale-old old)
  fresh=$(make_lock stale-fresh fresh)

  rc=0; with_lsof none worktree_lock_is_provably_stale "$old" "$TMP_ROOT" || rc=$?
  [ "$rc" -eq 0 ] || fail "no holder + old mtime must be provably stale, got $rc"

  rc=0; with_lsof holder worktree_lock_is_provably_stale "$old" "$TMP_ROOT" || rc=$?
  [ "$rc" -ne 0 ] || fail "a live holder must defeat staleness even with an old mtime"

  rc=0; with_lsof none worktree_lock_is_provably_stale "$fresh" "$TMP_ROOT" || rc=$?
  [ "$rc" -ne 0 ] || fail "a fresh mtime must defeat staleness even with no holder"

  rc=0; without_lsof worktree_lock_is_provably_stale "$old" "$TMP_ROOT" || rc=$?
  [ "$rc" -ne 0 ] || fail "an unavailable lsof must defeat staleness (UNKNOWN is not stale)"

  rc=0; with_lsof none worktree_lock_is_provably_stale "$TMP_ROOT/absent.lock" "$TMP_ROOT" || rc=$?
  [ "$rc" -ne 0 ] || fail "a lock that does not exist is not 'provably stale'"

  pass "provably-stale requires BOTH no-holder AND old mtime; any doubt is a refusal"
}

test_index_lock_signature_matches_git_only() {
  treehouse_return_is_index_lock_error \
    "fatal: Unable to create '/p/.git/worktrees/wt/index.lock': File exists." \
    || fail "the git index.lock signature must be recognized"
  ! treehouse_return_is_index_lock_error "treehouse: reset failed" \
    || fail "an unrelated return failure must NOT be treated as a lock error"
  ! treehouse_return_is_index_lock_error "fatal: Unable to create '/p/.git/HEAD.lock': File exists." \
    || fail "a non-index lock must NOT be treated as the index.lock race"
  pass "only the git index.lock 'File exists' signature enters the retry path"
}

# --- end-to-end sandbox ------------------------------------------------------

# Build a case dir: a project clone, a task worktree, state/, and stubs for
# treehouse/tmux/lsof. Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"

  # Scriptable treehouse: every `return --force` consults $FM_TH_MODE and fails
  # with the real git lock signature when it should.
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
n=$(cat "$FM_TH_COUNT" 2>/dev/null || echo 0)
n=$((n + 1))
printf '%s\n' "$n" > "$FM_TH_COUNT"
fail=0
case "$FM_TH_MODE" in
  always-lock)       fail=1 ;;
  ok-when-lock-gone) [ -e "$FM_TH_LOCK" ] && fail=1 ;;
  fail-then-ok:*)    [ "$n" -le "${FM_TH_MODE#fail-then-ok:}" ] && fail=1 ;;
esac
if [ "$fail" -eq 1 ]; then
  echo "fatal: Unable to create '$FM_TH_LOCK': File exists." >&2
  echo "treehouse: worktree return failed" >&2
  exit 1
fi
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  make_lsof_stub "$fakebin"
  chmod +x "$fakebin/treehouse" "$fakebin/tmux"

  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main

  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=local-only"
  touch "$case_dir/state/.last-watcher-beat"

  printf '%s\n' "$case_dir"
}

# The worktree's real git index.lock path, resolved exactly as the script does.
case_lock_path() {
  worktree_git_lock_path "$1/wt"
}

# Plant an index.lock in the task worktree. Args: case_dir <old|fresh>
plant_lock() {
  local case_dir=$1 age=$2 lock
  lock=$(case_lock_path "$case_dir") || fail "could not resolve the worktree index.lock path"
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  [ "$age" = old ] && touch -t 202001010000 "$lock"
  printf '%s\n' "$lock"
}

# Run teardown against a case. Args: case_dir th_mode lsof_mode [teardown args...]
run_teardown_case() {
  local case_dir=$1 th_mode=$2 lsof_mode=$3; shift 3
  local lock
  lock=$(case_lock_path "$case_dir")
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
  FM_TH_MODE="$th_mode" \
  FM_TH_LOCK="$lock" \
  FM_TH_COUNT="$case_dir/th-count" \
  FM_LSOF_MODE="$lsof_mode" \
  FM_LSOF_CALLS="$case_dir/lsof-calls" \
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=2 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0 \
    "$TEARDOWN" task-x1 "$@"
}

# --- A. a live-held lock is never removed -----------------------------------

test_live_held_lock_is_never_removed() {
  local case_dir lock rc stderr
  case_dir=$(make_case live-held)
  lock=$(plant_lock "$case_dir" old)

  set +e
  run_teardown_case "$case_dir" always-lock holder --force \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  stderr=$(cat "$case_dir/stderr")

  assert_present "$lock" "live-held: the lock of a LIVE worktree was deleted - index corruption"
  assert_contains "$stderr" "ERROR:" "live-held: the refusal must be a loud error, not a soft warning"
  assert_contains "$stderr" "a live process still holds" \
    "live-held: the error must name the live holder as the reason"
  assert_contains "$stderr" "$lock" "live-held: the error must name the lock it left in place"
  assert_not_contains "$stderr" "removed provably-stale" \
    "live-held: the force-remove branch must never be reported"
  # F11 husk cleanup still runs so no ghost window/meta is stranded.
  assert_absent "$case_dir/state/task-x1.meta" "live-held: stale meta left behind"
  expect_code 0 "$rc" "live-held: teardown still completes its window/meta cleanup"
  pass "A: a lock with a live holder is never removed; recovery fails loudly"
}

# --- B. a provably stale lock is removed and the return retried -------------

test_provably_stale_lock_is_removed_and_return_retried() {
  local case_dir lock rc stderr
  case_dir=$(make_case provably-stale)
  lock=$(plant_lock "$case_dir" old)

  set +e
  run_teardown_case "$case_dir" ok-when-lock-gone none --force \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  stderr=$(cat "$case_dir/stderr")

  expect_code 0 "$rc" "provably-stale: teardown should complete"
  assert_absent "$lock" "provably-stale: the abandoned lock should have been removed"
  assert_contains "$stderr" "removed provably-stale" \
    "provably-stale: the removal must be reported"
  assert_contains "$stderr" "succeeded after stale-lock cleanup" \
    "provably-stale: the return must be retried after the removal"
  assert_not_contains "$stderr" "ERROR:" "provably-stale: a recovered return must not report an error"
  grep -q "teardown task-x1 complete" "$case_dir/stdout" \
    || fail "provably-stale: completion line missing"
  pass "B: a lock with no holder and an old mtime is removed and the return succeeds"
}

# --- C. lsof cannot answer: no removal, loud failure ------------------------

test_unanswerable_lsof_never_removes_and_fails_loudly() {
  local case_dir lock rc stderr
  case_dir=$(make_case lsof-unknown)
  # Old mtime on purpose: age alone must not be enough to justify removal.
  lock=$(plant_lock "$case_dir" old)

  set +e
  run_teardown_case "$case_dir" ok-when-lock-gone error --force \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  stderr=$(cat "$case_dir/stderr")

  assert_present "$lock" "lsof-unknown: the lock was removed without proof it was stale"
  assert_contains "$stderr" "ERROR:" "lsof-unknown: the failure must be loud"
  assert_contains "$stderr" "lsof cannot answer" \
    "lsof-unknown: the error must name lsof as the reason staleness is unprovable"
  assert_contains "$stderr" "NOT returned" \
    "lsof-unknown: teardown must not imply the worktree was returned"
  assert_not_contains "$stderr" "removed provably-stale" \
    "lsof-unknown: the force-remove branch must never be entered"
  expect_code 0 "$rc" "lsof-unknown: teardown still completes its window/meta cleanup"
  pass "C: an lsof that cannot answer blocks removal and fails loudly"
}

# --- D. the transient case is handled by patience alone ---------------------

test_transient_lock_recovers_on_retry_without_removal() {
  local case_dir lock rc stderr
  case_dir=$(make_case transient)
  lock=$(plant_lock "$case_dir" fresh)

  set +e
  run_teardown_case "$case_dir" fail-then-ok:1 none --force \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  stderr=$(cat "$case_dir/stderr")

  expect_code 0 "$rc" "transient: teardown should complete"
  assert_contains "$stderr" "succeeded on retry" "transient: the retry must be reported"
  # The whole point: the dangerous path was never taken.
  assert_present "$lock" "transient: the lock was deleted even though a retry fixed it"
  assert_absent "$case_dir/lsof-calls" \
    "transient: lsof was consulted, so the force-remove branch was entered on a transient lock"
  assert_not_contains "$stderr" "removed provably-stale" \
    "transient: the force-remove branch must never be entered when a retry succeeds"
  assert_not_contains "$stderr" "ERROR:" "transient: a recovered return must not report an error"
  pass "D: a transient lock is recovered by patience alone; force-remove is never reached"
}

# --- non-lock failures keep their old, unchanged path -----------------------

test_non_lock_failure_does_not_enter_lock_recovery() {
  local case_dir rc stderr
  case_dir=$(make_case non-lock-failure)
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
echo "treehouse: reset failed" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/treehouse"

  set +e
  run_teardown_case "$case_dir" always-lock none --force \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  stderr=$(cat "$case_dir/stderr")

  expect_code 0 "$rc" "non-lock-failure: teardown must still complete (F11)"
  assert_contains "$stderr" "warning: treehouse return" \
    "non-lock-failure: the pre-existing warn-and-continue must be unchanged"
  assert_not_contains "$stderr" "retrying" \
    "non-lock-failure: a non-lock error must not enter the retry path"
  assert_absent "$case_dir/lsof-calls" \
    "non-lock-failure: a non-lock error must never reach the lsof check"
  pass "a non-lock return failure keeps its original warn-and-continue path"
}

test_holder_probe_reports_live_holder
test_holder_probe_reports_no_holder
test_holder_probe_errors_are_unknown_not_none
test_holder_probe_missing_lsof_is_unknown
test_provably_stale_only_when_both_proofs_hold
test_index_lock_signature_matches_git_only
test_live_held_lock_is_never_removed
test_provably_stale_lock_is_removed_and_return_retried
test_unanswerable_lsof_never_removes_and_fails_loudly
test_transient_lock_recovers_on_retry_without_removal
test_non_lock_failure_does_not_enter_lock_recovery
