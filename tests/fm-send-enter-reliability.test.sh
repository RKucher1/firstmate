#!/usr/bin/env bash
# fm-send Enter-reliability budget (incident afk-invx-i5 / F3 regression).
#
# Against a claude TUI showing the bypass-permissions footer, the first Enter(s)
# after a programmatic text injection are reliably swallowed for longer than a
# couple of attempts; a later Enter then submits the already-typed text. fm-send
# must keep retrying Enter (never retyping the text) long enough that a SINGLE
# fm-send call lands the steer, rather than returning a false "Enter swallowed"
# that a manual follow-up Enter then has to submit.
#
# These tests pin that hermetically (stubbed tmux + sleep, no real agent) with a
# COUNTING-swallow fake: the first N Enters are swallowed (the composer keeps its
# text), then the next Enter clears the composer (submit lands):
#   1. The default budget recovers a multi-Enter swallow in one fm-send (exit 0),
#      typing the text exactly once (Enter-only retries, never a retype).
#   2. The OLD budget (FM_SEND_RETRIES=3) FAILS the same scenario - proving the
#      budget, not the detection, was the F3 bug and the new default fixes it.
#   3. A genuinely persistent swallow still exits non-zero (the safety the
#      verified-submit was built for is preserved).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"

TMP_ROOT=$(fm_test_tmproot fm-send-enter-reliability)

# make_counting_swallow_case <name> -> echoes case dir.
# Builds a fake tmux whose Enter handler swallows the first FM_FAKE_SWALLOW_N
# Enters (composer keeps its text => fm_tmux_composer_state reads "pending"),
# then on the next Enter clears the composer (submit lands => "empty"). The typed
# text is recorded once per `-l` send so a retype is detectable. FM_FAKE_COMPOSER
# holds the live composer line; FM_FAKE_SENT logs sends; FM_FAKE_COUNT holds the
# swallow counter.
make_counting_swallow_case() {  # <name>
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"; fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin"
  printf '\xe2\x94\x82 > \xe2\x94\x82\n' > "$dir/composer"   # │ > │  (empty)
  printf '0\n' > "$dir/count"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
COMPOSER="${FM_FAKE_COMPOSER:?FM_FAKE_COMPOSER unset}"
COUNT="${FM_FAKE_COUNT:?FM_FAKE_COUNT unset}"
case "${1:-}" in
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '0\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) cat "$COMPOSER" 2>/dev/null; exit 0 ;;
  list-windows) exit 0 ;;
  send-keys)
    shift
    text=""; is_enter=0; lit=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -t) shift ;;
        -l) lit=1 ;;
        Enter) is_enter=1 ;;
        *) [ "$lit" = 1 ] && text="$1" ;;
      esac
      shift
    done
    if [ "$is_enter" = 1 ]; then
      n=$(cat "$COUNT" 2>/dev/null || echo 0)
      if [ "$n" -lt "${FM_FAKE_SWALLOW_N:-0}" ]; then
        printf '%s\n' "$((n + 1))" > "$COUNT"          # swallow: composer unchanged
      else
        [ -n "${FM_FAKE_SENT:-}" ] && printf '[ENTER]\n' >> "$FM_FAKE_SENT"
        printf '\xe2\x94\x82 > \xe2\x94\x82\n' > "$COMPOSER"   # submit lands: composer clears
      fi
    elif [ "$lit" = 1 ]; then
      [ -n "${FM_FAKE_SENT:-}" ] && printf '%s\n' "$text" >> "$FM_FAKE_SENT"
      printf '\xe2\x94\x82 > %s \xe2\x94\x82\n' "$text" > "$COMPOSER"
    fi
    exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$dir"
}

# run_send <dir> [env...] -- always targets sess:win with a plain steer.
run_send() {  # <dir> [env-assignments...]
  local dir=$1; shift
  env "$@" PATH="$dir/fakebin:$PATH" \
    FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" \
    FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_COUNT="$dir/count" FM_FAKE_SENT="$dir/sent.log" \
    "$SEND" sess:win 'fix findings 1 and 3, skip 2' 2>"$dir/send.err"
}

test_default_budget_recovers_multi_enter_swallow() {
  local dir rc
  dir=$(make_counting_swallow_case default-recovers)
  : > "$dir/sent.log"
  # Swallow the first 4 Enters (more than the old budget of 3) - the 5th lands.
  run_send "$dir" FM_FAKE_SWALLOW_N=4 FM_SEND_SLEEP=0.05 FM_SEND_SETTLE=0; rc=$?
  expect_code 0 "$rc" "default-budget fm-send should land a 4-Enter swallow in one call"
  [ "$(grep -c '\[ENTER\]' "$dir/sent.log")" -eq 1 ] \
    || fail "expected exactly one landed Enter, got:"$'\n'"$(cat "$dir/sent.log")"
  [ "$(grep -cv '\[ENTER\]' "$dir/sent.log")" -eq 1 ] \
    || fail "steer text was retyped on retry (expected type-once):"$'\n'"$(cat "$dir/sent.log")"
  pass "fm-send: default budget recovers a multi-Enter swallow in a single call, no retype"
}

test_old_budget_would_fail_same_scenario() {
  local dir rc
  dir=$(make_counting_swallow_case old-budget-fails)
  : > "$dir/sent.log"
  # The exact F3 regression: with the OLD 3-Enter budget the same 4-Enter swallow
  # never lands - fm-send must exit non-zero and report the swallow.
  run_send "$dir" FM_FAKE_SWALLOW_N=4 FM_SEND_RETRIES=3 FM_SEND_SLEEP=0.05 FM_SEND_SETTLE=0; rc=$?
  [ "$rc" -ne 0 ] || fail "old 3-Enter budget unexpectedly landed a 4-Enter swallow (regression not pinned)"
  grep -F 'not submitted' "$dir/send.err" >/dev/null \
    || fail "fm-send did not report the swallow under the old budget: $(cat "$dir/send.err")"
  pass "fm-send: the old 3-Enter budget fails the F3 scenario (regression pinned to budget)"
}

test_persistent_swallow_still_fails_safe() {
  local dir rc
  dir=$(make_counting_swallow_case persistent-swallow)
  : > "$dir/sent.log"
  # A swallow that never clears (N larger than any budget) must still exit
  # non-zero - the never-silently-drop safety is preserved.
  run_send "$dir" FM_FAKE_SWALLOW_N=9999 FM_SEND_SLEEP=0.02 FM_SEND_SETTLE=0; rc=$?
  [ "$rc" -ne 0 ] || fail "a persistently swallowed Enter exited zero (silent unsubmitted steer)"
  grep -F 'not submitted' "$dir/send.err" >/dev/null \
    || fail "fm-send did not explain the persistent swallow: $(cat "$dir/send.err")"
  [ "$(grep -cv '\[ENTER\]' "$dir/sent.log")" -eq 1 ] \
    || fail "steer text retyped during persistent swallow (expected type-once):"$'\n'"$(cat "$dir/sent.log")"
  pass "fm-send: a persistent swallow still exits non-zero, text typed once"
}

test_default_budget_recovers_multi_enter_swallow
test_old_budget_would_fail_same_scenario
test_persistent_swallow_still_fails_safe
