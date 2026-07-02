#!/usr/bin/env bash
# Safe, home-scoped (re-)arm of the firstmate watcher, with honest verification.
#
# The watcher (bin/fm-watch.sh) blocks until it has an actionable wake to
# surface, then prints one reason line and exits. While state/.afk exists the
# daemon owns triage and the watcher exits on every wake for the daemon to
# classify. Reliability depends on arming through a mechanism that SURVIVES the
# call and NOTIFIES on exit, so firstmate must run this script as the harness's
# own tracked background task (e.g. run_in_background). Run it as its own
# standalone background task, never bundled onto the tail of another command.
# NEVER fire it and forget with a shell `&` inside another call: that backgrounded
# child is reaped when the call returns, leaving NO watcher running and a false
# "already running" off the dying process. That exact mistake silently took
# supervision down for ~30 minutes.
#
# This script forks the watcher DETACHED (its own session, reparented to init -
# never a child of this arm or of the captain's shell, so harness shell-tracking
# cannot hang on the watcher process; FM-WATCH-DETACH-1), verifies the outcome,
# and then keeps a LOGICAL wait on it: it blocks polling the identity-checked
# lock and the watcher's captured output until the watcher exits with its wake,
# then completes carrying that reason line. The arm's completion IS the wake
# notification for the harness, exactly as when the watcher was a wait()ed
# child - only the OS parenthood changed (the Silentwatchtoggle fix).
# It confirms a watcher process is genuinely alive AND the
# liveness beacon (state/.last-watcher-beat) is fresh within FM_GUARD_GRACE (the
# single source of truth, shared with fm-watch.sh and fm-guard.sh), and prints
# exactly one unambiguous status line:
#   watcher: started pid=<N> (beacon fresh)              - it launched one and confirmed it
#   watcher: healthy pid=<N> (beacon <age>s)             - a genuinely live+fresh watcher already held the lock
#   watcher: FAILED - no live watcher with a fresh beacon  - could not confirm one
# It NEVER reports started/healthy off a stale beacon or a dead/reused pid: a
# stale-beacon or dead-pid holder either self-heals (the fresh child steals the
# dead lock per the singleton self-eviction/steal path and is confirmed) or this
# returns the FAILED line. On started/healthy it exits zero; on FAILED it exits
# non-zero so the failure is loud and a caller can react. A healthy line means a
# live cycle already exists; do not churn extra no-op arms until that cycle fires.
#
# --restart: stop ONLY this FM_HOME's watcher (the pid recorded in THIS home's
# state/.watch.lock) and start a fresh one. It resolves and signals exactly that
# pid, so it can never touch another home's watcher. NEVER `pkill -f
# bin/fm-watch.sh`: that pattern matches every firstmate home's watcher
# (secondmate homes run the same script) and would kill siblings.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

WATCH="$SCRIPT_DIR/fm-watch.sh"
WATCH_LOCK="$STATE/.watch.lock"
BEAT="$STATE/.last-watcher-beat"
# "Fresh" reuses the guard's threshold so there is one definition of liveness.
GRACE=${FM_GUARD_GRACE:-300}
# How long to wait for a freshly forked watcher to acquire the lock and beat.
CONFIRM_TIMEOUT=${FM_ARM_CONFIRM_TIMEOUT:-10}

watch_lock_matches_pid() {
  local pid=$1 lock_home lock_path lock_identity current_identity
  lock_home=$(cat "$WATCH_LOCK/fm-home" 2>/dev/null || true)
  lock_path=$(cat "$WATCH_LOCK/watcher-path" 2>/dev/null || true)
  lock_identity=$(cat "$WATCH_LOCK/pid-identity" 2>/dev/null || true)
  [ "$lock_home" = "$FM_HOME" ] || return 1
  [ "$lock_path" = "$WATCH" ] || return 1
  [ -n "$lock_identity" ] || return 1
  current_identity=$(fm_pid_identity "$pid") || return 1
  [ "$current_identity" = "$lock_identity" ]
}

clear_stale_recorded_watcher_lock() {
  local lock_home lock_path lock_identity
  lock_home=$(cat "$WATCH_LOCK/fm-home" 2>/dev/null || true)
  lock_path=$(cat "$WATCH_LOCK/watcher-path" 2>/dev/null || true)
  lock_identity=$(cat "$WATCH_LOCK/pid-identity" 2>/dev/null || true)
  [ "$lock_home" = "$FM_HOME" ] || return 0
  [ "$lock_path" = "$WATCH" ] || return 0
  [ -n "$lock_identity" ] || return 0
  fm_lock_remove_path "$WATCH_LOCK" || true
}

# A watcher is "healthy" iff the lock names a live process that is genuinely THIS
# home's watcher (the identity match guards against a recycled/reused pid) AND the
# liveness beacon is fresh within GRACE. Sets HEALTHY_PID on success. This is the
# single honesty gate: a dead pid, a reused pid, or a stale beacon all fail it, so
# this script can never report a watcher that is not really there.
HEALTHY_PID=
healthy_watcher() {
  local pid age
  HEALTHY_PID=
  pid=$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" || return 1
  watch_lock_matches_pid "$pid" || return 1
  age=$(fm_path_age "$BEAT")
  [ "$age" -lt "$GRACE" ] || return 1
  HEALTHY_PID=$pid
  return 0
}

report_healthy() {
  local age
  age=$(fm_path_age "$BEAT")
  echo "watcher: healthy pid=$HEALTHY_PID (beacon ${age}s)"
}

watch_output_has_wake() {
  local out=$1
  grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$out" 2>/dev/null
}

print_watch_output() {
  local out=$1
  [ -s "$out" ] && cat "$out"
}

# The LOGICAL wait (Silentwatchtoggle fix). The watcher exits precisely when it
# has an actionable wake to surface (or when it stands down to a peer / dies),
# so blocking here until the confirmed watcher is gone and then completing with
# whatever it printed restores the pre-detach contract - the arm's completion
# notifies the harness of the wake - without re-parenting the watcher: only the
# lock and files are polled, never a `wait` on a child. watch_lock_matches_pid
# guards the poll against pid reuse, and a watcher that lost the singleton ends
# this wait too (the surviving watcher's own arm carries its wakes).
block_until_wake_exit() {
  while fm_pid_alive "$child" && watch_lock_matches_pid "$child"; do
    sleep 1
  done
  if watch_output_has_wake "$child_out"; then
    print_watch_output "$child_out"
    rm -f "$child_out" 2>/dev/null || true
    exit 0
  fi
  # No wake: either our watcher stood down to a peer that now holds the
  # singleton (report it honestly - that peer's arm observes its wakes), or it
  # died outright (fail loudly so the caller re-arms).
  if healthy_watcher; then
    report_healthy
    rm -f "$child_out" 2>/dev/null || true
    exit 0
  fi
  print_watch_output "$child_out"
  rm -f "$child_out" 2>/dev/null || true
  echo "watcher: FAILED - watcher exited without a wake"
  exit 1
}

mode=arm
case "${1:-}" in
  ''|arm|--arm) mode=arm ;;
  --restart) mode=restart ;;
  *) echo "usage: $(basename "$0") [--restart]" >&2; exit 2 ;;
esac

if [ "$mode" = restart ]; then
  # Home-scoped stop: only the watcher pid recorded in THIS home's lock.
  lock_pid=$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)
  if fm_pid_alive "$lock_pid"; then
    if watch_lock_matches_pid "$lock_pid"; then
      kill -TERM "$lock_pid" 2>/dev/null || true
      # Wait for it to actually exit before relaunching, so the fresh watcher
      # either takes a released lock or reclaims a now-dead-pid stale lock instead
      # of seeing the dying one as a live holder and no-opping.
      i=0
      while [ "$i" -lt 50 ] && fm_pid_alive "$lock_pid"; do
        sleep 0.1
        i=$((i + 1))
      done
    else
      clear_stale_recorded_watcher_lock
    fi
  fi
fi

# If a genuinely live+fresh watcher already holds the lock, do not start a second
# one - the singleton would no-op anyway. Report it honestly and return success.
# (--restart skips this: it just stopped this home's watcher and wants a fresh one.)
if [ "$mode" = arm ] && healthy_watcher; then
  report_healthy
  exit 0
fi

# Start a watcher detached and confirm it before settling in. The watcher is
# never kept as a child (that parenthood is what hung the captain's shell
# tracking on '1 shell still running'; FM-WATCH-DETACH-1) - instead this arm
# holds the logical wait in block_until_wake_exit, so the watcher's eventual
# wake exit still propagates out and the harness re-notifies firstmate.
# Killing this arm still tears the watcher down via the signal traps, keeping
# the invariant behind the healthy-watcher short-circuit above: a live watcher
# implies a live arm blocking on it.
child=
child_out=
cleanup_child() {
  if [ -n "$child" ] && fm_pid_alive "$child"; then
    kill -TERM "$child" 2>/dev/null || true
  fi
  if [ -n "$child_out" ]; then
    rm -f "$child_out" 2>/dev/null || true
  fi
}
trap 'cleanup_child; exit 129' HUP
trap 'cleanup_child; exit 143' TERM INT

child_out=$(mktemp "$STATE/.watch-arm-output.XXXXXX") || {
  echo "watcher: FAILED - no live watcher with a fresh beacon"
  exit 1
}
# Double-fork under setsid: the watcher gets its own session and the
# intermediate subshell exits at once, so the watcher reparents to init
# immediately and is never a child of this (still-running) arm. $! inside the
# subshell is the watcher's pid: setsid execs in place when it is not already a
# process-group leader, which holds for a script-spawned subshell job, and the
# confirm loop below cross-checks that pid against the identity-checked lock
# before trusting it.
child=$( (setsid "$WATCH" >"$child_out" 2>&1 </dev/null & echo $!) )
case "$child" in
  ''|*[!0-9]*)
    echo "watcher: FAILED - no live watcher with a fresh beacon"
    rm -f "$child_out" 2>/dev/null || true
    exit 1
    ;;
esac
child_done=0

# Verify the outcome: poll until this child is the confirmed healthy watcher, or
# until some other watcher legitimately holds the singleton (a startup race), or
# until the child gives up. Only then print the honest line.
deadline=$(( $(date +%s) + CONFIRM_TIMEOUT ))
while :; do
  if healthy_watcher; then
    if [ "$HEALTHY_PID" = "$child" ]; then
      echo "watcher: started pid=$child (beacon fresh)"
      # Block until the watcher fires. The watcher is already OS-detached (own
      # session, ppid=init) so nothing here re-creates the '1 shell still
      # running' hang; this is the logical wait that makes the wake observable.
      block_until_wake_exit
    fi
    # Another watcher won the singleton; our detached child stood down (it
    # self-evicts within one poll). Report the live one.
    report_healthy
    rm -f "$child_out" 2>/dev/null || true
    exit 0
  fi
  if [ "$child_done" -eq 0 ] && ! fm_pid_alive "$child"; then
    child_done=1
    # The watcher is not our child, so there is no exit status to reap; its
    # captured output is the record. A wake line means it fired immediately
    # (before confirmation) - propagate it as the arm's completion.
    if watch_output_has_wake "$child_out"; then
      print_watch_output "$child_out"
      rm -f "$child_out" 2>/dev/null || true
      exit 0
    fi
  fi
  [ "$(date +%s)" -ge "$deadline" ] && break
  sleep 0.2
done

trap - HUP TERM INT
echo "watcher: FAILED - no live watcher with a fresh beacon"
cleanup_child
exit 1
