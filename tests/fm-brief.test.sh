#!/usr/bin/env bash
# tests/fm-brief.test.sh - brief scaffolding contracts in bin/fm-brief.sh.
#
# Pins the F4 strand fix: the no-mistakes ship brief must tell the crewmate to
# SHEPHERD its pipeline run to a terminal state in the foreground. The observed
# failure (stress-test finding F4): crewmates fired `no-mistakes axi run` as a
# background command and ended their turn; the run advanced through non-gated
# steps, then a gated step (awaiting_approval / ask-user) stranded with the
# crewmate asleep - the crewmate->firstmate->captain escalation never propagated
# and the gate timed out to failed. The brief text is the contract that prevents
# that, so it is pinned here.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BRIEF_BIN="$ROOT/bin/fm-brief.sh"
TMP_ROOT=$(fm_test_tmproot fm-brief-tests)

# Scaffold one brief in a hermetic home (no data/projects.md, so the delivery
# mode falls back to the no-mistakes default). Echoes the brief path.
scaffold_brief() {  # <case> <id> [extra fm-brief args...]
  local case_dir="$TMP_ROOT/$1" id=$2
  shift 2
  mkdir -p "$case_dir/data" "$case_dir/state"
  FM_DATA_OVERRIDE="$case_dir/data" FM_STATE_OVERRIDE="$case_dir/state" \
    "$BRIEF_BIN" "$id" testrepo "$@" >/dev/null 2>&1 || fail "fm-brief.sh failed to scaffold $id"
  printf '%s\n' "$case_dir/data/$id/brief.md"
}

test_no_mistakes_brief_shepherds_run_to_terminal_state() {
  local brief
  brief=$(scaffold_brief shepherd task-a1)
  assert_grep 'Shepherd your run to a terminal state' "$brief" \
    "no-mistakes DOD does not tell the crewmate to shepherd the run"
  assert_grep 'Never fire' "$brief" \
    "no-mistakes DOD does not forbid fire-and-forget of the pipeline"
  assert_grep 'background command and end your turn' "$brief" \
    "no-mistakes DOD does not name the background-then-sleep strand"
  assert_grep 'no-mistakes axi status' "$brief" \
    "no-mistakes DOD does not give the poll fallback for backgrounding harnesses"
  pass "no-mistakes ship brief instructs foreground shepherding of the pipeline run (F4)"
}

test_scout_brief_has_no_pipeline_shepherding() {
  local brief
  brief=$(scaffold_brief scout task-s1 --scout)
  assert_no_grep 'Shepherd your run to a terminal state' "$brief" \
    "scout brief wrongly carries the no-mistakes shepherd instruction"
  pass "scout brief stays pipeline-free (no shepherd instruction)"
}

test_no_mistakes_brief_shepherds_run_to_terminal_state
test_scout_brief_has_no_pipeline_shepherding
