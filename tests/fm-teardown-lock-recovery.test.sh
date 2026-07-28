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
#   E. lock too young to judge                            -> waited out, then RE-PROVED
#   F. the secondmate-home call site                      -> same recovery, refusal aborts
#
# The cases run end to end through the real script, A-E at the main worktree
# return and F at the secondmate-home return, so both changed call sites are
# covered; the two predicates the whole proof rests on - "is anything holding
# this?" and "is it provably stale?" - are additionally exercised directly, by
# sourcing the marked recovery block out of the script.
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
# test can prove lsof was never consulted at all. The script probes with `lsof
# -t`, so stdout is PIDs only and every diagnostic goes to stderr.
#   holder    - a live process holds the path (exit 0, a PID on stdout)
#   none      - nothing holds it (exit 1, no output: lsof's real "no match")
#   warn-none - no match, but the routine unrelated-mount WARNING this very host
#               emits is on stderr (exit 1, empty stdout). Still a real no-match.
#   warn-target - same warning shape, but the mount it names CONTAINS the target,
#               so lsof could not walk the target's own filesystem
#   error     - lsof ran but could not answer FOR THIS TARGET (exit 1, a status
#               error naming the path)
#   crash     - lsof did not run to completion at all (non-1 exit)
#   none-then-holder - no holder for the first $FM_LSOF_NONE_CALLS probes, a live
#               holder after that: a process that surfaces only on a re-check
make_lsof_stub() {
  local fakebin=$1
  cat > "$fakebin/lsof" <<'SH'
#!/usr/bin/env bash
[ -n "${FM_LSOF_CALLS:-}" ] && printf '%s\n' "$*" >> "$FM_LSOF_CALLS"
target=${!#}
case "${FM_LSOF_MODE:-none}" in
  holder) printf '%s\n' "4242" ; exit 0 ;;
  none)   exit 1 ;;
  warn-none)
    # Verbatim shape from this host: any box with docker/NFS/autofs mounts emits
    # it on every run, and it says nothing about the target.
    printf '%s\n' "lsof: WARNING: can't stat() nsfs file system /run/docker/netns/default" \
      "      Output information may be incomplete." >&2
    exit 1
    ;;
  warn-target)
    # Same shape, but the unwalkable filesystem is the one the target lives on.
    printf '%s\n' "lsof: WARNING: can't stat() nfs file system $(dirname "$target")" \
      "      Output information may be incomplete." >&2
    exit 1
    ;;
  error)  echo "lsof: status error on $target: No such file or directory" >&2 ; exit 1 ;;
  crash)  echo "lsof: illegal option character: -" >&2 ; exit 8 ;;
  none-then-holder)
    seq=$(cat "$FM_LSOF_SEQ" 2>/dev/null || echo 0)
    seq=$((seq + 1))
    printf '%s\n' "$seq" > "$FM_LSOF_SEQ"
    [ "$seq" -le "${FM_LSOF_NONE_CALLS:-2}" ] && exit 1
    printf '%s\n' "4242"
    exit 0
    ;;
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

  rc=0
  with_lsof crash worktree_lock_holder_state "$TMP_ROOT/some.lock" "$TMP_ROOT" 2>/dev/null || rc=$?
  [ "$rc" -eq 2 ] || fail "holder probe: an lsof that never ran must be UNKNOWN (2), got $rc"
  pass "an lsof error is UNKNOWN, never mistaken for 'no holder'"
}

# The regression this suite exists to hold: an lsof that ran fine and simply
# found nothing must stay NONE even though it wrote an unrelated mount WARNING to
# stderr. Judging on merged output instead of stdout makes that UNKNOWN, which
# renders the whole stale-removal path unreachable on any ordinary host.
test_holder_probe_unrelated_warning_is_still_no_holder() {
  local rc=0
  with_lsof warn-none worktree_lock_holder_state "$TMP_ROOT/some.lock" "$TMP_ROOT" 2>/dev/null || rc=$?
  [ "$rc" -eq 1 ] || fail "holder probe: a no-match with only an unrelated mount WARNING must be NONE (1), got $rc"
  pass "an unrelated lsof mount WARNING is a diagnostic, not evidence: still no holder"
}

# The other direction of the same rule: that leniency is scoped to OTHER
# filesystems. When the mount a warning names contains the target, lsof could not
# enumerate the target's own filesystem, so empty stdout says nothing - and NONE
# plus an old mtime is the branch that deletes the file.
test_holder_probe_target_filesystem_warning_is_unknown() {
  local rc=0
  with_lsof warn-target worktree_lock_holder_state "$TMP_ROOT/some.lock" "$TMP_ROOT" 2>/dev/null || rc=$?
  [ "$rc" -eq 2 ] || fail "holder probe: a warning about the TARGET's own filesystem must be UNKNOWN (2), got $rc"
  pass "an lsof warning covering the target's own filesystem is UNKNOWN, never 'no holder'"
}

# A hung NFS/autofs mount is exactly the host this recovery runs on, so the probe
# is capped where a timeout binary exists - and a probe cut short is UNKNOWN.
test_holder_probe_timeout_is_unknown() {
  local fakebin="$TMP_ROOT/timeout-fakebin" rc=0 err
  mkdir -p "$fakebin"
  make_lsof_stub "$fakebin"
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
exit 124
SH
  chmod +x "$fakebin/timeout"

  err=$(
    (
      export PATH="$fakebin:$PATH" FM_LSOF_MODE=none
      worktree_lock_holder_state "$TMP_ROOT/some.lock" "$TMP_ROOT"
    ) 2>&1
  ) || rc=$?
  [ "$rc" -eq 2 ] || fail "holder probe: a timed-out lsof must be UNKNOWN (2), never NONE; got $rc"
  case "$err" in
    *"timed out after"*) ;;
    *) fail "holder probe: a timed-out lsof must say so; got: $err" ;;
  esac
  pass "a timed-out lsof probe is UNKNOWN and says why"
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

# The age proof is half the invariant, so no threshold value may skip it. A junk or
# negative one makes `[ "$age" -lt abc ]` exit 2, which the `if` reads as "old
# enough"; a 0 is below every age there is, which disables the proof outright and
# leaves removal resting on the lsof probe alone. Both must still refuse a fresh lock.
test_junk_staleness_threshold_cannot_skip_the_age_proof() {
  local fresh rc bad fakebin
  fresh=$(make_lock threshold-fresh fresh)
  fakebin="$TMP_ROOT/unit-fakebin"
  mkdir -p "$fakebin"
  make_lsof_stub "$fakebin"
  for bad in abc -1 30s ' ' 0; do
    rc=0
    (
      export PATH="$fakebin:$PATH" FM_LSOF_MODE=none \
        FM_STATE_OVERRIDE="$TMP_ROOT/lib-state" \
        FM_STALE_WORKTREE_LOCK_AGE_SECS="$bad"
      # shellcheck source=bin/fm-wake-lib.sh
      . "$ROOT/bin/fm-wake-lib.sh"
      # shellcheck source=/dev/null
      . "$LOCK_LIB"
      worktree_lock_is_provably_stale "$fresh" "$TMP_ROOT"
    ) >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ] \
      || fail "staleness threshold '$bad' let a fresh lock pass the age proof"
  done
  pass "no staleness threshold value - junk, negative, or zero - can skip the age proof"
}

# Teardown blocks in the foreground for this wait, so its ceiling must belong to
# the code: a large threshold must not be able to stretch it into a long stall.
test_judgeable_wait_cap_is_clamped_by_code_not_env() {
  local lock out
  lock=$(make_lock wait-cap old)
  out=$(
    (
      export FM_STATE_OVERRIDE="$TMP_ROOT/lib-state" FM_STALE_WORKTREE_LOCK_AGE_SECS=3600
      # shellcheck source=bin/fm-wake-lib.sh
      . "$ROOT/bin/fm-wake-lib.sh"
      # shellcheck source=/dev/null
      . "$LOCK_LIB"
      worktree_lock_wait_until_judgeable "$lock" worktree
    ) 2>&1
  ) || fail "wait cap: an already-judgeable lock should return at once"
  assert_contains "$out" "waiting up to 60s" \
    "wait cap: the announced wait must be the code's absolute cap, not threshold + margin"
  assert_not_contains "$out" "waiting up to 3605s" \
    "wait cap: a large staleness threshold must not stretch the foreground wait"
  pass "the judge-able wait is capped by the code, not by whoever sets the threshold"
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

# The resolved path is the ONLY thing the recovery probes and removes, so an
# ambient GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE - which `git -C` does not override -
# must not be able to point it at some other repository's index.lock.
test_lock_path_ignores_ambient_git_env() {
  local base wt_lock poisoned
  base="$TMP_ROOT/git-env"
  rm -rf "$base"
  mkdir -p "$base"
  git init -q "$base/main"
  git -C "$base/main" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$base/main" worktree add -q "$base/wt"
  git init -q "$base/other"

  wt_lock=$(worktree_git_lock_path "$base/wt") \
    || fail "git env: the worktree's own index.lock path must resolve"
  poisoned=$(
    GIT_DIR="$base/other/.git" GIT_WORK_TREE="$base/other" \
    GIT_INDEX_FILE="$base/other/.git/index" \
      worktree_git_lock_path "$base/wt"
  ) || fail "git env: resolution must still succeed with a foreign git env set"

  [ "$poisoned" = "$wt_lock" ] \
    || fail "git env: an inherited GIT_DIR must not redirect the lock path to another repo"
  assert_not_contains "$poisoned" "/other/" \
    "git env: the resolved lock must belong to the worktree, never the ambient repo"
  pass "the lock path is resolved with the ambient git env scrubbed"
}

# Defense in depth behind that scrub: whatever git names is validated before it can
# become a probe or rm target, and a path that fails is unresolvable, not removable.
test_lock_path_refuses_a_path_it_cannot_vouch_for() {
  local base out
  base="$TMP_ROOT/git-path-validation"
  rm -rf "$base"
  mkdir -p "$base/fakebin" "$base/elsewhere"
  git init -q "$base/repo"

  git_stub() {  # <path rev-parse should name for --git-path>
    cat > "$base/fakebin/git" <<SH
#!/usr/bin/env bash
case "\$*" in
  *--git-path*) printf '%s\n' '$1' ;;
  *--git-dir*|*--git-common-dir*) printf '%s\n' '$base/repo/.git' ;;
esac
SH
    chmod +x "$base/fakebin/git"
  }

  git_stub "$base/elsewhere/index.lock"
  out=$(PATH="$base/fakebin:$PATH" worktree_git_lock_path "$base/repo") \
    && fail "validation: a lock outside the worktree and its git dir must be refused"
  [ -z "$out" ] || fail "validation: a refused resolution must print nothing"

  git_stub "$base/repo/.git/config"
  out=$(PATH="$base/fakebin:$PATH" worktree_git_lock_path "$base/repo") \
    && fail "validation: a path that is not an index.lock must be refused"
  [ -z "$out" ] || fail "validation: a refused resolution must print nothing"

  git_stub "$base/repo/.git/index.lock"
  out=$(PATH="$base/fakebin:$PATH" worktree_git_lock_path "$base/repo") \
    || fail "validation: the repo's own index.lock must still resolve"
  [ "$out" = "$base/repo/.git/index.lock" ] \
    || fail "validation: a vouched-for lock must be returned unchanged"
  pass "a lock path git cannot be vouched for is unresolvable, never a removal target"
}

# On a host with neither timeout nor gtimeout the probe helper must still succeed -
# under set -eu a non-zero return would abort teardown instead of just skipping the
# cap. Pins that contract so it cannot be lost to a later rewrite of the lookup.
test_timeout_probe_is_not_a_failure_without_a_timeout_binary() {
  local empty out rc=0
  empty="$TMP_ROOT/no-timeout-bin"
  rm -rf "$empty"
  mkdir -p "$empty"
  out=$(PATH="$empty" lsof_probe_timeout_bin) || rc=$?
  expect_code 0 "$rc" "timeout probe: a host without timeout/gtimeout must not be a failure"
  [ -z "$out" ] || fail "timeout probe: no binary means no timeout wrapper"
  pass "the timeout probe succeeds quietly when the host has no timeout binary"
}

# --- end-to-end sandbox ------------------------------------------------------

# Stubs every end-to-end case needs: a scriptable treehouse, an inert tmux, and
# the lsof stub. Shared by the worktree and secondmate-home case builders.
make_case_fakebin() {
  local fakebin=$1
  mkdir -p "$fakebin"

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
# A real return resets the worktree back to the pool's detached default branch,
# which is what frees the task branch ref for teardown to drop afterwards.
wt=${!#}
[ -d "$wt" ] && git -C "$wt" checkout --detach -q 2>/dev/null
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  make_lsof_stub "$fakebin"
  chmod +x "$fakebin/treehouse" "$fakebin/tmux"
}

# Build a case dir: a project clone, a task worktree, state/, and the stubs.
# Echoes the case dir.
make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state"
  make_case_fakebin "$case_dir/fakebin"

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

# The task branch is dropped from the PROJECT repo, and only after a successful
# return - so a lock-refused teardown must leave it, and a recovered one must not.
assert_task_branch() {  # <case_dir> <present|gone> <message>
  local case_dir=$1 want=$2 msg=$3 rc=0
  git -C "$case_dir/project" rev-parse --verify -q refs/heads/fm/task-x1 >/dev/null || rc=$?
  case "$want" in
    present) [ "$rc" -eq 0 ] || fail "$msg" ;;
    gone)    [ "$rc" -ne 0 ] || fail "$msg" ;;
  esac
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
  FM_LSOF_SEQ="$case_dir/lsof-seq" \
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
  assert_task_branch "$case_dir" present \
    "live-held: the task branch must survive a refused return - the work is still checked out there"
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
  # The ref accounting the recovery must not cost: a teardown the lock recovery
  # rescued still drops the task branch, instead of leaking it into the pool repo.
  assert_task_branch "$case_dir" gone \
    "provably-stale: a recovered teardown must still drop the task branch"
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

# --- E. a lock born during teardown is waited out, then re-proved ------------

# The retry window (seconds) is far shorter than the staleness threshold, so a
# lock created as teardown killed its owner is too young to judge when the
# retries run out. It must be waited out rather than refused - but the wait is
# only patience: the age and the holder check are re-read afterwards, and a live
# holder discovered on that fresh read still blocks removal (the next case).
test_too_young_lock_is_waited_out_then_removed() {
  local case_dir lock rc stderr
  case_dir=$(make_case too-young)
  lock=$(plant_lock "$case_dir" fresh)

  set +e
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3 \
    run_teardown_case "$case_dir" ok-when-lock-gone none --force \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  stderr=$(cat "$case_dir/stderr")

  expect_code 0 "$rc" "too-young: teardown should complete"
  assert_contains "$stderr" "too young to judge" \
    "too-young: the wait must be reported, not a refusal"
  assert_contains "$stderr" "waiting up to" \
    "too-young: the wait must state its cap"
  assert_absent "$lock" "too-young: the lock should have been removed once it aged past the threshold"
  assert_contains "$stderr" "removed provably-stale" \
    "too-young: removal must still be reported as a proved removal"
  assert_not_contains "$stderr" "ERROR:" "too-young: a recovered return must not report an error"
  pass "E: a lock too young to judge is waited out, then re-proved before removal"
}

# The wait must never become the proof. lsof answers "no holder" while the lock
# is still too young, then reports a holder on the post-wait re-check - exactly
# the process that had not surfaced yet. Removing on the strength of the earlier
# answer plus an expired timer is the corruption this invariant forbids.
test_waited_out_lock_is_reproved_not_assumed() {
  local case_dir lock rc stderr
  case_dir=$(make_case too-young-held)
  lock=$(plant_lock "$case_dir" fresh)

  set +e
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3 FM_LSOF_NONE_CALLS=2 \
    run_teardown_case "$case_dir" always-lock none-then-holder --force \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  stderr=$(cat "$case_dir/stderr")

  expect_code 0 "$rc" "too-young-held: teardown still completes its window/meta cleanup"
  assert_present "$lock" "too-young-held: an expired timer must not license removing a held lock"
  assert_contains "$stderr" "too young to judge" "too-young-held: the wait must have been entered"
  assert_contains "$stderr" "a live process still holds" \
    "too-young-held: the post-wait re-check must catch the holder that surfaced during the wait"
  assert_not_contains "$stderr" "removed provably-stale" \
    "too-young-held: the force-remove branch must never be entered for a held lock"
  pass "E2: the bounded wait is patience, not proof - staleness is re-proved on a fresh read"
}

# A removal that did not happen must never be logged as one: this stderr trail is
# the audit record for the one branch that deletes another process's file.
test_failed_removal_is_not_reported_as_a_removal() {
  local case_dir lock lockdir rc stderr
  case_dir=$(make_case unremovable)
  lock=$(plant_lock "$case_dir" old)
  lockdir=$(dirname "$lock")
  chmod 555 "$lockdir"

  set +e
  run_teardown_case "$case_dir" ok-when-lock-gone none --force \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  chmod 755 "$lockdir"
  stderr=$(cat "$case_dir/stderr")

  assert_present "$lock" "unremovable: the lock should still be there - the directory is read-only"
  assert_not_contains "$stderr" "removed provably-stale" \
    "unremovable: a removal that failed must not be logged as a removal"
  assert_contains "$stderr" "could not be removed" \
    "unremovable: the failed removal must be reported for what it was"
  assert_contains "$stderr" "NOT returned" \
    "unremovable: teardown must not imply the worktree was returned"
  expect_code 0 "$rc" "unremovable: teardown still completes its window/meta cleanup"
  pass "a stale-lock removal that fails is reported as a failure, never as a removal"
}

# --- F. the secondmate home call site ---------------------------------------
#
# remove_firstmate_home routes its home return through the same helper, but
# DELIBERATELY collapses the distinct lock-refused code into a plain failure:
# a secondmate home is a leased treehouse slot, and a still-held lease must abort
# teardown rather than be papered over the way the main worktree's husk cleanup
# does. These two cases pin both halves of that at the real call site.

# Build a secondmate case: a fake firstmate root hosting the home as a real
# worktree, a seeded home marker, meta with kind=secondmate, and a registry
# route. Echoes the case dir.
make_secondmate_case() {
  local name=$1 case_dir fmroot subhome
  # The home and the firstmate root sit OUTSIDE the FM_HOME case dir: teardown
  # refuses to remove anything nested inside the active firstmate home.
  case_dir="$TMP_ROOT/$name"
  fmroot="$TMP_ROOT/$name-fmroot"
  subhome="$TMP_ROOT/$name-subhome"
  mkdir -p "$case_dir/state" "$case_dir/data"
  make_case_fakebin "$case_dir/fakebin"

  mkdir -p "$fmroot/bin"
  printf '# Firstmate\n' > "$fmroot/AGENTS.md"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fmroot/bin/fm-guard.sh"
  chmod +x "$fmroot/bin/fm-guard.sh"
  git -C "$fmroot" init -q
  git -C "$fmroot" add AGENTS.md bin/fm-guard.sh
  git -C "$fmroot" -c user.name=t -c user.email=t@t commit -qm initial
  git -C "$fmroot" worktree add --quiet --detach "$subhome" HEAD
  mkdir -p "$subhome/state"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"

  fm_write_meta "$case_dir/state/domain.meta" \
    "window=firstmate:fm-domain" \
    "worktree=$subhome" \
    "project=$subhome" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$subhome"
  printf '%s\n' "- domain - design domain (home: $subhome; scope: design domain; projects: alpha; added 2026-06-22)" \
    > "$case_dir/data/secondmates.md"
  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

# Run teardown against a secondmate case. Args: case_dir th_mode lsof_mode
run_secondmate_case() {
  local case_dir=$1 th_mode=$2 lsof_mode=$3; shift 3
  local lock
  lock=$(worktree_git_lock_path "$case_dir-subhome")
  FM_ROOT_OVERRIDE="$case_dir-fmroot" \
  FM_HOME="$case_dir" \
  PATH="$case_dir/fakebin:$PATH" \
  FM_TH_MODE="$th_mode" \
  FM_TH_LOCK="$lock" \
  FM_TH_COUNT="$case_dir/th-count" \
  FM_LSOF_MODE="$lsof_mode" \
  FM_LSOF_CALLS="$case_dir/lsof-calls" \
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=2 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0 \
    "$TEARDOWN" domain "$@"
}

test_secondmate_home_return_recovers_a_stale_lock() {
  local case_dir lock rc stderr
  case_dir=$(make_secondmate_case secondmate-stale)
  lock=$(worktree_git_lock_path "$case_dir-subhome")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 202001010000 "$lock"

  set +e
  run_secondmate_case "$case_dir" ok-when-lock-gone none > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  stderr=$(cat "$case_dir/stderr")

  expect_code 0 "$rc" "secondmate-stale: teardown should complete"
  assert_absent "$lock" "secondmate-stale: the abandoned lock should have been removed"
  assert_contains "$stderr" "removed provably-stale" \
    "secondmate-stale: the recovery must run at the secondmate home call site too"
  assert_absent "$case_dir/state/domain.meta" "secondmate-stale: meta should be cleared once the home was retired"
  pass "F: the secondmate home return recovers a provably-stale lock through the same helper"
}

test_secondmate_home_return_refusal_aborts_teardown() {
  local case_dir lock rc stderr
  case_dir=$(make_secondmate_case secondmate-held)
  lock=$(worktree_git_lock_path "$case_dir-subhome")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 202001010000 "$lock"

  set +e
  run_secondmate_case "$case_dir" always-lock holder > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  stderr=$(cat "$case_dir/stderr")

  [ "$rc" -ne 0 ] || fail "secondmate-held: a still-leased home must fail teardown, not continue"
  assert_present "$lock" "secondmate-held: the lock of a live home was deleted - index corruption"
  assert_contains "$stderr" "a live process still holds" \
    "secondmate-held: the refusal must name the live holder"
  assert_contains "$stderr" "treehouse return failed for secondmate home" \
    "secondmate-held: the lock refusal must collapse into the generic leased-home failure"
  # Intended difference from the main worktree path: nothing is cleared, because a
  # still-held lease must never be hidden behind a husk cleanup.
  assert_present "$case_dir/state/domain.meta" "secondmate-held: meta cleared despite a still-held lease"
  assert_present "$case_dir-subhome" "secondmate-held: home removed despite a still-held lease"
  grep -F -- '- domain ' "$case_dir/data/secondmates.md" >/dev/null \
    || fail "secondmate-held: registry route removed despite a still-held lease"
  pass "F2: a lock-refused secondmate home return aborts teardown instead of hiding the lease"
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
test_holder_probe_unrelated_warning_is_still_no_holder
test_holder_probe_target_filesystem_warning_is_unknown
test_holder_probe_timeout_is_unknown
test_holder_probe_missing_lsof_is_unknown
test_provably_stale_only_when_both_proofs_hold
test_junk_staleness_threshold_cannot_skip_the_age_proof
test_judgeable_wait_cap_is_clamped_by_code_not_env
test_index_lock_signature_matches_git_only
test_live_held_lock_is_never_removed
test_provably_stale_lock_is_removed_and_return_retried
test_unanswerable_lsof_never_removes_and_fails_loudly
test_transient_lock_recovers_on_retry_without_removal
test_too_young_lock_is_waited_out_then_removed
test_waited_out_lock_is_reproved_not_assumed
test_failed_removal_is_not_reported_as_a_removal
test_secondmate_home_return_recovers_a_stale_lock
test_secondmate_home_return_refusal_aborts_teardown
test_lock_path_ignores_ambient_git_env
test_lock_path_refuses_a_path_it_cannot_vouch_for
test_timeout_probe_is_not_a_failure_without_a_timeout_binary
test_non_lock_failure_does_not_enter_lock_recovery
