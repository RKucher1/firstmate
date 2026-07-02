#!/usr/bin/env bash
# tests/fm-watch-dead-crew.test.sh - the watcher's dead-crew reaper (F7).
#
# A crewmate process that dies without teardown (a crash, a killed window, a
# husk pane) used to leak forever: the .meta stayed on disk, the treehouse
# worktree stayed leased, and the watcher's pane loop just `continue`d past the
# unreadable window every poll. The watcher now detects a PROVABLY dead crew -
# every pane pid dead, or the window gone while the tmux server is up - and
# within one cycle returns the worktree (treehouse return --force), logs the
# anomaly to the triage log, and clears the stale meta. The verdict is
# conservative: an unreachable tmux server (which also breaks the fake tmux in
# every other suite) is never treated as death, and live or secondmate crews are
# never disturbed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-dead-crew-tests)

# Fake tmux for this suite: pane-pid liveness and server liveness are the two
# signals the reaper reads.
#   FM_FAKE_TMUX_PANE_PID     printed for `list-panes -F '#{pane_pid}'`
#   FM_FAKE_TMUX_WINDOW_GONE  1 -> list-panes fails (window not found)
#   FM_FAKE_TMUX_SERVER_DOWN  1 -> list-sessions fails too (server unreachable)
#   FM_FAKE_TMUX_CAPTURE      capture-pane source (the normal stale-path read)
make_case() {  # <name> -> echoes case dir
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-panes)
    [ "${FM_FAKE_TMUX_WINDOW_GONE:-0}" = 1 ] && exit 1
    printf '%s\n' "${FM_FAKE_TMUX_PANE_PID:?FM_FAKE_TMUX_PANE_PID unset}"
    exit 0 ;;
  list-sessions)
    [ "${FM_FAKE_TMUX_SERVER_DOWN:-0}" = 1 ] && exit 1
    exit 0 ;;
  capture-pane)
    [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ] && cat "$FM_FAKE_TMUX_CAPTURE"
    exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  # Fake treehouse records "<cwd> <args...>" per call so the return is provable.
  cat > "$fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s %s\n' "\$PWD" "\$*" >> "$dir/treehouse-calls"
exit 0
SH
  chmod +x "$fakebin/treehouse"
  printf 'some pane output\n' > "$dir/pane.txt"
  printf '%s\n' "$dir"
}

# A ship meta with a real worktree + project dir (both must exist for the reap
# to attempt the return).
write_ship_meta() {  # <case-dir> <id> <window>
  local dir=$1 id=$2 window=$3
  mkdir -p "$dir/proj" "$dir/wt"
  fm_write_meta "$dir/state/$id.meta" \
    "window=$window" \
    "worktree=$dir/wt" \
    "project=$dir/proj" \
    "kind=ship"
}

watch_bg() {  # <dir> [env pairs...]
  local dir=$1
  shift
  PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 env "$@" "$WATCH" > "$dir/watch.out" &
}

wait_gone() {  # <path> [limit]
  local path=$1 limit=${2:-40} i=0
  while [ "$i" -lt "$limit" ]; do
    [ ! -e "$path" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

reap_proc() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# A pid that is certainly dead for the duration of the test.
dead_pid() {
  local p=999999
  while kill -0 "$p" 2>/dev/null; do p=$((p + 1)); done
  printf '%s\n' "$p"
}

test_dead_pane_pid_reaps_within_one_cycle() {
  local dir pid
  dir=$(make_case dead-pid)
  write_ship_meta "$dir" task-d1 "test:fm-task-d1"
  watch_bg "$dir" FM_FAKE_TMUX_PANE_PID="$(dead_pid)"
  pid=$!
  wait_gone "$dir/state/task-d1.meta" || { reap_proc "$pid"; fail "dead-pid crew meta was not cleared"; }
  kill -0 "$pid" 2>/dev/null || fail "watcher exited while reaping (reap must not be a wake): $(cat "$dir/watch.out")"
  reap_proc "$pid"
  grep -F "$dir/proj return --force $dir/wt" "$dir/treehouse-calls" >/dev/null \
    || fail "treehouse return --force was not run from the project for the leaked worktree"
  grep -F "reaped dead crew task-d1" "$dir/state/.watch-triage.log" >/dev/null \
    || fail "reap anomaly was not logged to the triage log"
  [ ! -s "$dir/state/.wake-queue" ] || fail "reap enqueued a wake"
  pass "a crew with a dead pane pid is reaped within one cycle: worktree returned, anomaly logged, meta cleared"
}

test_window_gone_with_live_server_reaps() {
  local dir pid
  dir=$(make_case window-gone)
  write_ship_meta "$dir" task-g1 "test:fm-task-g1"
  watch_bg "$dir" FM_FAKE_TMUX_PANE_PID=1 FM_FAKE_TMUX_WINDOW_GONE=1
  pid=$!
  wait_gone "$dir/state/task-g1.meta" || { reap_proc "$pid"; fail "gone-window crew meta was not cleared"; }
  reap_proc "$pid"
  grep -F "return --force $dir/wt" "$dir/treehouse-calls" >/dev/null \
    || fail "gone-window reap did not return the worktree"
  pass "a recorded window missing from a live tmux server is reaped"
}

test_unreachable_server_is_not_death() {
  local dir pid
  dir=$(make_case server-down)
  write_ship_meta "$dir" task-s1 "test:fm-task-s1"
  watch_bg "$dir" FM_FAKE_TMUX_PANE_PID=1 FM_FAKE_TMUX_WINDOW_GONE=1 FM_FAKE_TMUX_SERVER_DOWN=1
  pid=$!
  sleep 2.5
  [ -e "$dir/state/task-s1.meta" ] || { reap_proc "$pid"; fail "unreachable tmux server was treated as crew death"; }
  reap_proc "$pid"
  [ ! -e "$dir/treehouse-calls" ] || fail "unreachable server triggered a worktree return"
  pass "an unreachable tmux server never reaps (conservative: no positive evidence of death)"
}

test_live_crew_untouched() {
  local dir pid
  dir=$(make_case live-crew)
  write_ship_meta "$dir" task-l1 "test:fm-task-l1"
  # $$ is this test shell: alive for the whole run.
  watch_bg "$dir" FM_FAKE_TMUX_PANE_PID="$$"
  pid=$!
  sleep 2.5
  [ -e "$dir/state/task-l1.meta" ] || { reap_proc "$pid"; fail "a live crew's meta was cleared"; }
  reap_proc "$pid"
  [ ! -e "$dir/treehouse-calls" ] || fail "a live crew's worktree was returned"
  pass "a live crew is never disturbed by the reaper"
}

test_secondmate_never_reaped() {
  local dir pid
  dir=$(make_case secondmate)
  mkdir -p "$dir/proj" "$dir/wt"
  fm_write_meta "$dir/state/task-m1.meta" \
    "window=test:fm-task-m1" \
    "worktree=$dir/wt" \
    "project=$dir/proj" \
    "kind=secondmate"
  watch_bg "$dir" FM_FAKE_TMUX_PANE_PID="$(dead_pid)"
  pid=$!
  sleep 2.5
  [ -e "$dir/state/task-m1.meta" ] || { reap_proc "$pid"; fail "a secondmate meta was reaped"; }
  reap_proc "$pid"
  [ ! -e "$dir/treehouse-calls" ] || fail "a secondmate home was treehouse-returned by the reaper"
  pass "secondmates are exempt from the dead-crew reaper (their retirement is explicit teardown)"
}

test_dead_crew_with_gone_worktree_still_clears_meta() {
  local dir pid
  dir=$(make_case gone-worktree)
  write_ship_meta "$dir" task-w1 "test:fm-task-w1"
  rm -rf "$dir/wt"
  watch_bg "$dir" FM_FAKE_TMUX_PANE_PID="$(dead_pid)"
  pid=$!
  wait_gone "$dir/state/task-w1.meta" || { reap_proc "$pid"; fail "meta was not cleared when the worktree was already gone"; }
  reap_proc "$pid"
  [ ! -e "$dir/treehouse-calls" ] || fail "treehouse return ran for an already-gone worktree"
  grep -F "reaped dead crew task-w1" "$dir/state/.watch-triage.log" >/dev/null \
    || fail "gone-worktree reap was not logged"
  pass "a dead crew whose worktree is already gone still gets its meta cleared"
}

test_dead_pane_pid_reaps_within_one_cycle
test_window_gone_with_live_server_reaps
test_unreachable_server_is_not_death
test_live_crew_untouched
test_secondmate_never_reaped
test_dead_crew_with_gone_worktree_still_clears_meta
