#!/usr/bin/env bash
# tests/fm-teardown-reap-watcher.test.sh - fm-teardown.sh reaps a self-dev home's
# own detached watcher (COCKPIT-FM-CLEANUP-1). Two invariants:
#   1. The reap is scoped by the ABSOLUTE worktree path, so it kills only THIS
#      worktree's watcher and never a sibling home's (the safety property that
#      makes it safe where a bare `pkill -f bin/fm-watch.sh` is banned).
#   2. The reap line is actually present in fm-teardown.sh in that safe form.
# Real-process unit, in the spirit of fm-watcher-lock.test.sh: a scoping bug may
# not reproduce through the heavy e2e teardown path.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEARDOWN="$ROOT/bin/fm-teardown.sh"

# Spawn a stand-in watcher whose argv matches the real one: `bash <wt>/bin/fm-watch.sh`.
spawn_fake_watcher() {  # <wt> -> echoes pid
  local wt=$1
  mkdir -p "$wt/bin"
  cat > "$wt/bin/fm-watch.sh" <<'SH'
#!/usr/bin/env bash
while :; do sleep 0.2; done
SH
  chmod +x "$wt/bin/fm-watch.sh"
  # Redirect all stdio: a backgrounded child that inherits the $() subshell's
  # stdout would make the command substitution below block until it exits (never).
  bash "$wt/bin/fm-watch.sh" >/dev/null 2>&1 &
  echo $!
}

test_reap_kills_only_this_worktrees_watcher() {
  local root wt1 wt2 pid1 pid2 i
  root=$(fm_test_tmproot fm-reap-watcher)
  wt1="$root/wt-target"
  wt2="$root/wt-sibling"
  pid1=$(spawn_fake_watcher "$wt1")
  pid2=$(spawn_fake_watcher "$wt2")

  # The exact command fm-teardown.sh runs, with WT bound to the target worktree.
  WT="$wt1"; pkill -f "$WT/bin/fm-watch.sh" 2>/dev/null || true

  # Target dies within a short window; sibling must survive.
  i=0
  while [ "$i" -lt 25 ] && kill -0 "$pid1" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  kill -0 "$pid1" 2>/dev/null && { kill "$pid1" "$pid2" 2>/dev/null; fail "reap did not kill the target worktree's watcher (pid $pid1)"; }
  kill -0 "$pid2" 2>/dev/null || fail "reap killed the SIBLING worktree's watcher (pid $pid2) - path scoping broken"

  kill "$pid2" 2>/dev/null || true
  pass "reap kills only this worktree's watcher, spares a sibling home's"
}

test_reap_line_present_and_safely_scoped() {
  assert_grep 'pkill -f "$WT/bin/fm-watch.sh"' "$TEARDOWN" \
    "fm-teardown.sh reaps the watcher scoped by absolute worktree path"
  assert_grep '|| true' "$TEARDOWN" \
    "reap is guarded against set -e on no-match (|| true present)"
  # The banned bare form (matches every home's watcher) must NOT appear.
  assert_no_grep 'pkill -f "bin/fm-watch.sh"' "$TEARDOWN" \
    "fm-teardown.sh does not use the unscoped, sibling-killing pkill form"
  pass "reap line is present and scoped to the absolute worktree path only"
}

test_reap_line_present_and_safely_scoped
test_reap_kills_only_this_worktrees_watcher
