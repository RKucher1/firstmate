#!/usr/bin/env bash
# Tear down a finished task: return the treehouse worktree or retire a
# secondmate home, kill the tmux window, clear volatile state, refresh/prune
# the project's clone for PR-based ship tasks, then print a backlog-refresh
# reminder.
# REFUSES if the worktree holds work that has not LANDED, because treehouse return
# hard-resets the worktree and kills its processes. Work has landed when it is
# reachable from any remote-tracking branch (a fork counts as a remote, so
# upstream-contribution PRs pushed to a fork satisfy this in any mode), OR - for a
# normal ship task whose commits are not so reachable - when its PR is merged and
# GitHub reports the current HEAD as that PR's head, or its content is already
# present in the up-to-date default branch. This recognizes the common
# squash-merge-then-delete-branch flow, where the branch's own commits live nowhere
# on a remote yet the change is fully in main.
# A gh lookup error falls back to the content check; if that is also inconclusive,
# teardown refuses rather than risk discarding unlanded work.
# Uncommitted changes are never landed.
# local-only projects additionally accept work merged into the local default
# branch (firstmate performs that merge on the captain's approval) as a fallback
# for the common case where there is no remote at all.
# Scout tasks (kind=scout in meta) carve out of that check: their worktree is
# declared scratch and the report at data/<task-id>/report.md is the work
# product - teardown proceeds once the report exists, and refuses without it.
# Secondmates (kind=secondmate in meta) are retired explicitly. Normal
# teardown refuses while their home has in-flight crewmate meta files; --force
# is the approved discard path that prevalidates child removal targets, discards
# child work, kills child windows, and removes the retired home. Removing a
# leased home releases its durable treehouse lease so the pool slot is freed,
# never left leased forever. If the treehouse return fails, teardown leaves the
# leased home and state in place instead of hiding a still-held lease.
# Usage: fm-teardown.sh <task-id> [--force]
#   --force skips ordinary-task dirty and landed-work checks, skips scout report
#   checks, and discards secondmate child work for kind=secondmate. Only use it
#   when the captain has explicitly said to discard the work.
# A crew process killed mid-git-operation can leave a stale git index.lock behind
# that makes the worktree return fail; teardown_treehouse_return recovers from it
# with bounded patience and, only for a provably-stale lock, removal. See the
# FM-LOCK-RECOVERY block below for the full safety proof.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
SECONDMATE_REG="$DATA/secondmates.md"
SUB_HOME_MARKER=".fm-secondmate-home"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"   # fm_path_mtime, used by the lock-recovery block
"$FM_ROOT/bin/fm-guard.sh" || true
ID=$1
FORCE=${2:-}

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
WT=$(grep '^worktree=' "$META" | cut -d= -f2-)
T=$(grep '^window=' "$META" | cut -d= -f2-)
PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
HOME_PATH=$(grep '^home=' "$META" | cut -d= -f2- || true)
PR_URL=$(grep '^pr=' "$META" | tail -1 | cut -d= -f2- || true)

KIND=$(grep '^kind=' "$META" | cut -d= -f2- || true)
[ -n "$KIND" ] || KIND=ship
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ -n "$MODE" ] || MODE=no-mistakes

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

meta_value() {
  local meta=$1 key=$2
  grep "^$key=" "$meta" | cut -d= -f2- || true
}

remove_grok_turnend_auth() {
  local state_dir=$1 id=$2 token hooks_dir
  token=$(cat "$state_dir/$id.grok-turnend-token" 2>/dev/null || true)
  case "$token" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  hooks_dir="${GROK_HOME:-$HOME/.grok}/hooks/fm-turn-end.d"
  rm -f "$hooks_dir/$token"
}

# Resolve the PR number for a worktree branch via gh-axi. Echoes the number on a
# single match and returns 0; returns non-zero on no match or any lookup failure,
# so the caller treats it as "no PR found" (fail-safe).
pr_number_from_branch() {
  local branch=$1 out n
  [ -n "$branch" ] && [ "$branch" != HEAD ] || return 1
  out=$( cd "$WT" && gh-axi pr list --state all --head "$branch" --limit 1 2>/dev/null ) || return 1
  n=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*\([0-9][0-9]*\),.*/\1/p' | head -1)
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

# Is the worktree's PR merged for this exact HEAD? Resolves the PR from the
# recorded pr= URL first, then from the branch name, and asks GitHub for both the
# PR state and head commit. Returns non-zero when the PR is not merged, the current
# HEAD is not the PR head, the head cannot be resolved, no PR is found, or any gh
# error occurs - the caller then falls back to the content check.
#
# The PR head commit is derived from the PR's commit list (the last commit is the
# branch tip, exactly what the head ref points at) rather than the `headRefOid`
# field, because older `gh` builds - like the one on this box - do not know that
# field and error out, which would false-refuse a genuinely merged PR. `commits`
# is a long-standing field, so this works on old and new gh alike while keeping the
# same safety contract: pass ONLY when the PR is MERGED and HEAD equals its head
# commit. gh-axi's `pr view` renders its own summary instead of honoring `--json`,
# so the raw `gh` binary is used for this structured query.
pr_is_merged() {
  local branch=$1 target view state head current
  if [ -n "$PR_URL" ]; then
    target=$PR_URL
  else
    target=$(pr_number_from_branch "$branch") || return 1
  fi
  [ -n "$target" ] || return 1
  view=$(cd "$WT" && gh pr view "$target" --json state,commits \
    -q '.state + "\t" + ((.commits // []) | last | .oid // "")' 2>/dev/null) || return 1
  state=${view%%$'\t'*}
  head=${view#*$'\t'}
  [ "$state" != "$view" ] || return 1
  case "$state" in
    MERGED|merged) ;;
    *) return 1 ;;
  esac
  [ -n "$head" ] || return 1
  current=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null) || return 1
  [ "$current" = "$head" ]
}

# Does `git merge-tree --write-tree` work here? That form needs Git 2.38+; older
# gits (this box runs 2.34.1) reject `--write-tree` as an unknown rev. The probe is
# a no-op 3-way self-merge of HEAD, so it has no worktree or index side effects; it
# just tells content_in_default whether to take the modern path or the read-tree
# fallback.
git_supports_merge_tree_write_tree() {
  git -C "$WT" merge-tree --write-tree HEAD HEAD >/dev/null 2>&1
}

# read-tree fallback for the merge-tree probe above, for Git < 2.38. Performs the
# same 3-way merge of the default branch and HEAD (base = their merge-base) into a
# throwaway index and writes the merged tree, without touching the worktree or the
# real index. Returns 0 with the merged tree only on a clean merge; a content-level
# conflict (which read-tree cannot trivially resolve) or any error returns non-zero,
# so the caller stays conservative and refuses rather than guesses. Args: ref default_tree
content_in_default_via_read_tree() {
  local ref=$1 default_tree=$2 base tmp_index merged_tree rc=1
  base=$(git -C "$WT" merge-base "$ref" HEAD 2>/dev/null) || return 1
  [ -n "$base" ] || return 1
  tmp_index=$(mktemp "${TMPDIR:-/tmp}/fm-teardown-idx.XXXXXX") || return 1
  rm -f "$tmp_index"  # read-tree writes a fresh index; an empty pre-created file is rejected
  if GIT_INDEX_FILE="$tmp_index" git -C "$WT" read-tree -m --aggressive "$base" "$ref" HEAD 2>/dev/null; then
    merged_tree=$(GIT_INDEX_FILE="$tmp_index" git -C "$WT" write-tree 2>/dev/null) && rc=0
  fi
  rm -f "$tmp_index"
  [ "$rc" -eq 0 ] || return 1
  [ -n "$merged_tree" ] || return 1
  [ "$merged_tree" = "$default_tree" ]
}

# Is the branch's content already present in the up-to-date default branch? Fetches
# first, then 3-way merges the default branch with HEAD: when HEAD introduces nothing
# the default branch does not already contain (e.g. its change landed via squash) the
# merged tree equals the default branch's tree. This isolates branch-only changes, so
# unrelated commits the default branch gained past the merge-base do not count as
# "added". The merge uses `git merge-tree --write-tree` when available (Git 2.38+) and
# an equivalent read-tree merge on older gits, so old-tooling boxes behave the same
# instead of false-refusing. Returns non-zero when inconclusive (no default ref, or a
# merge conflict), so the caller refuses rather than guesses.
content_in_default() {
  local name ref default_tree merged_tree
  name=$(default_branch) || return 1
  if git -C "$WT" remote get-url origin >/dev/null 2>&1; then
    git -C "$WT" fetch --quiet origin "+refs/heads/$name:refs/remotes/origin/$name" >/dev/null 2>&1 || return 1
    ref="refs/remotes/origin/$name"
  elif git -C "$WT" rev-parse --quiet --verify "refs/heads/$name" >/dev/null 2>&1; then
    ref="refs/heads/$name"
  else
    return 1
  fi
  default_tree=$(git -C "$WT" rev-parse --quiet --verify "$ref^{tree}" 2>/dev/null) || return 1
  [ -n "$default_tree" ] || return 1
  if git_supports_merge_tree_write_tree; then
    merged_tree=$(git -C "$WT" merge-tree --write-tree "$ref" HEAD 2>/dev/null) || return 1
    merged_tree=$(printf '%s\n' "$merged_tree" | head -1)
    [ "$merged_tree" = "$default_tree" ]
  else
    content_in_default_via_read_tree "$ref" "$default_tree"
  fi
}

# Has the worktree's committed work actually LANDED, though its commits are not
# reachable from any remote-tracking branch? True when a merged PR proves the
# current HEAD, OR the content is already in the default branch (fallback, which
# also covers the no-PR and gh-error paths). False only for genuinely unlanded work.
work_is_landed() {
  local branch=$1
  pr_is_merged "$branch" && return 0
  content_in_default
}

backlog_refresh_reminder() {
  local pr done_cmd report_path
  if fm_tasks_axi_compatible; then
    case "$KIND" in
      scout)
        report_path="data/$ID/report.md"
        done_cmd="tasks-axi done $ID --report $report_path"
        ;;
      secondmate)
        done_cmd="tasks-axi done $ID --note \"retired\""
        ;;
      *)
        if [ "$MODE" = local-only ]; then
          done_cmd="tasks-axi done $ID --note \"local main\""
        else
          pr=$PR_URL
          if [ -n "$pr" ]; then
            done_cmd="tasks-axi done $ID --pr $pr"
          else
            done_cmd="tasks-axi done $ID --pr PR_URL"
          fi
        fi
        ;;
    esac
    printf '%s\n' "Backlog: $ID just finished. Run $done_cmd, then run tasks-axi ready for dependency-cleared candidates, check date gates, and dispatch only work whose blockers are gone and date is due."
  else
    printf '%s\n' "Backlog: $ID just finished. Update data/backlog.md - move $ID to Done, keep Done to the 10 most recent, then re-scan Queued and dispatch only work whose blockers are gone and date is due."
  fi
}

registry_home_for_line() {
  sed -n 's/^[^(]*(home: \([^;)]*\);.*/\1/p'
}

path_is_ancestor_of() {
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] || return 1
  [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in
    "$ancestor"/*) return 0 ;;
  esac
  return 1
}

removal_target_abs_path() {
  local target=$1
  if [ -d "$target" ]; then
    cd "$target" && pwd -P
  else
    cd "$(dirname "$target")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$target")"
  fi
}

worktree_registered_for_project() {
  local project=$1 target=$2 abs_target listed line listed_abs
  [ -n "$project" ] || return 1
  [ -d "$project" ] || return 1
  git -C "$project" rev-parse --git-dir >/dev/null 2>&1 || return 1
  abs_target=$(removal_target_abs_path "$target")
  listed=$(git -C "$project" -c core.quotePath=false worktree list --porcelain 2>/dev/null) || return 1
  while IFS= read -r line; do
    case "$line" in
      worktree\ *)
        listed_abs=$(removal_target_abs_path "${line#worktree }" 2>/dev/null || true)
        [ "$listed_abs" = "$abs_target" ] && return 0
        ;;
    esac
  done <<EOF
$listed
EOF
  return 1
}

firstmate_home_has_treehouse_slot() {
  local home=$1
  worktree_registered_for_project "$FM_ROOT" "$home"
}

validate_removal_target() {
  local target=$1 label=$2 abs_target abs_home abs_root
  [ -n "$target" ] || return 0
  [ -e "$target" ] || return 0
  abs_target=$(removal_target_abs_path "$target")
  if abs_home=$(cd "$FM_HOME" 2>/dev/null && pwd -P); then
    :
  else
    abs_home=
  fi
  abs_root=$(cd "$FM_ROOT" && pwd -P)
  case "$abs_target" in
    ''|/) echo "REFUSED: unsafe $label removal target $target" >&2; return 1 ;;
  esac
  if [ -n "$abs_home" ] && [ "$abs_target" = "$abs_home" ]; then
    echo "REFUSED: unsafe $label removal target $target is the active firstmate home" >&2
    return 1
  fi
  if [ "$abs_target" = "$abs_root" ]; then
    echo "REFUSED: unsafe $label removal target $target is the firstmate repo" >&2
    return 1
  fi
  if [ -n "$abs_home" ] && path_is_ancestor_of "$abs_target" "$abs_home"; then
    echo "REFUSED: unsafe $label removal target $target is an ancestor of the active firstmate home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_target" "$abs_root"; then
    echo "REFUSED: unsafe $label removal target $target is an ancestor of the firstmate repo" >&2
    return 1
  fi
  if [ -n "$abs_home" ] && path_is_ancestor_of "$abs_home" "$abs_target"; then
    echo "REFUSED: unsafe $label removal target $target is inside the active firstmate home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_root" "$abs_target"; then
    echo "REFUSED: unsafe $label removal target $target is inside the firstmate repo" >&2
    return 1
  fi
  printf '%s\n' "$abs_target"
}

registered_descendant_home_for_removal() {
  local reg=$1 target=$2 line id registered_home registered_abs
  [ -f "$reg" ] || return 1
  while IFS= read -r line; do
    case "$line" in
      "- "*)
        id=${line#- }
        id=${id%% *}
        registered_home=$(printf '%s\n' "$line" | registry_home_for_line)
        [ -n "$registered_home" ] || continue
        registered_abs=$(removal_target_abs_path "$registered_home" 2>/dev/null || true)
        [ -n "$registered_abs" ] || continue
        [ "$registered_abs" = "$target" ] && continue
        if path_is_ancestor_of "$target" "$registered_abs"; then
          printf '%s\t%s\n' "$id" "$registered_abs"
          return 0
        fi
        ;;
    esac
  done < "$reg"
  return 1
}

validate_firstmate_operational_dirs_for_removal() {
  local home=$1 label=$2 name dir abs_home abs_dir
  abs_home=$(removal_target_abs_path "$home")
  for name in data state config projects; do
    dir="$home/$name"
    [ -e "$dir" ] || [ -L "$dir" ] || continue
    if [ -L "$dir" ] && [ ! -e "$dir" ]; then
      echo "REFUSED: unsafe $label $name directory $dir resolves outside the secondmate home" >&2
      return 1
    fi
    if [ -d "$dir" ]; then
      abs_dir=$(cd "$dir" && pwd -P)
    elif [ -e "$dir" ]; then
      echo "REFUSED: unsafe $label $name path $dir is not a directory" >&2
      return 1
    else
      abs_dir=
    fi
    if [ -z "$abs_dir" ] || ! path_is_ancestor_of "$abs_home" "$abs_dir"; then
      echo "REFUSED: unsafe $label $name directory $dir resolves outside the secondmate home" >&2
      return 1
    fi
  done
}

validate_child_worktree_for_removal() {
  local target=$1 project=$2 abs_target abs_home abs_root
  [ -n "$target" ] || return 0
  [ -e "$target" ] || return 0
  abs_target=$(validate_removal_target "$target" "child worktree") || return 1
  if abs_home=$(cd "$FM_HOME" 2>/dev/null && pwd -P); then
    if path_is_ancestor_of "$abs_home" "$abs_target"; then
      echo "REFUSED: unsafe child worktree removal target $target is inside the active firstmate home" >&2
      return 1
    fi
  fi
  abs_root=$(cd "$FM_ROOT" && pwd -P)
  if path_is_ancestor_of "$abs_root" "$abs_target"; then
    echo "REFUSED: unsafe child worktree removal target $target is inside the firstmate repo" >&2
    return 1
  fi
  if ! worktree_registered_for_project "$project" "$target"; then
    echo "REFUSED: unsafe child worktree removal target $target is not a git worktree for ${project:-the recorded project}" >&2
    return 1
  fi
  printf '%s\n' "$abs_target"
}

safe_rm_rf() {
  local target=$1 label=$2
  validate_removal_target "$target" "$label" >/dev/null || return 1
  rm -rf -- "$target"
}

safe_rm_rf_child_worktree() {
  local target=$1 project=$2
  validate_child_worktree_for_removal "$target" "$project" >/dev/null || return 1
  rm -rf -- "$target"
}

# FM-LOCK-RECOVERY-BEGIN
# Transient / stale worktree git index.lock recovery.
#
# Hand-ported from upstream firstmate (kunchenguid/firstmate): commit 678f2b5
# (PR #296, "recover provably stale git index locks") and commit 38086ea (PR
# #435, "retry transient index locks during worktree return"). Ported by hand to
# this file's conventions rather than cherry-picked, and deliberately narrower:
# upstream routes its returns through a runtime-backend abstraction
# (bin/fm-backend.sh) that this teardown does not have and must not grow, and
# upstream's companion "safety inspection itself blocked by the lock" path is not
# taken here - our landed-work checks run before the return and this fix does not
# change them. Diff against those two commits if upstream later fixes something
# we did not take.
#
# Three behaviors here DELIBERATELY DIVERGE from those upstream commits, because
# upstream's versions make its own stale-removal path unreachable in practice:
#   1. lsof classification reads stdout, not merged output. Upstream captures
#      `lsof <path> 2>&1` and calls any output an error, so a routine unrelated
#      warning ("lsof: WARNING: can't stat() nsfs file system ...", emitted on any
#      host with docker/NFS/autofs mounts) turns a genuine no-match into UNKNOWN
#      and no lock is ever provably stale. We run `lsof -t`, whose stdout is PIDs
#      only, judge on that, and keep stderr as a printed diagnostic - while still
#      returning UNKNOWN whenever lsof could not actually run or complete. That
#      leniency is scoped: a "can't stat() ... file system <mount>" warning whose
#      mount CONTAINS the probe target means lsof could not enumerate the target's
#      own filesystem, so its silence is not evidence and the answer is UNKNOWN.
#   2. the retry window is followed by a bounded wait until the lock is old enough
#      to judge. Upstream pairs a 30s staleness threshold with a 3x1s retry
#      window, so a lock born DURING teardown (the exact case the port exists for:
#      `treehouse return --force` killing a git process mid-operation) can never
#      reach its own threshold and is always refused. We wait out the difference,
#      capped, and then re-prove staleness on a fresh read.
#   3. the lsof probe itself is bounded to $LSOF_PROBE_TIMEOUT_SECS seconds when a
#      `timeout`/`gtimeout` binary exists. lsof stats the whole mount table and can
#      block forever on a hung NFS/autofs mount - the very hosts this path targets -
#      and upstream leaves that unbounded. A timed-out probe is UNKNOWN, never NONE,
#      so the bound can only ever refuse a removal. Where no timeout binary exists
#      (stock macOS) the probe runs unwrapped rather than degrading to a permanent
#      UNKNOWN that would disable the removal path on that platform entirely.
#
# A crew process killed mid-git-operation can leave a
# .git/worktrees/<wt>/index.lock (or, for a non-linked repo, .git/index.lock)
# behind, so `treehouse return --force` fails with
#   fatal: Unable to create '...index.lock': File exists
# That lock is USUALLY TRANSIENT - the owning process is simply still exiting -
# so the fix is patience, not rm: teardown_treehouse_return retries the return a
# bounded number of times first, and the common case never gets any further.
#
# Removal is considered only for a lock that outlives the whole retry window, and
# only when it is PROVABLY STALE, which needs BOTH proofs together:
#   1. lsof reports no live process holding the lock file open AND none holding
#      the worktree directory open (cwd or fd). A live git process keeps its own
#      lock open for the whole operation, so "nothing holds it" means the file was
#      abandoned by a process that has since exited - not that nobody ever held it.
#   2. the lock's mtime age is at least $STALE_WORKTREE_LOCK_AGE_SECS. A lock
#      created moments ago may belong to a process lsof has not reflected yet.
# If lsof is missing, errors, or otherwise cannot answer, that is UNKNOWN, not
# stale: there is no fallback that removes a lock without lsof. Anything short of
# both proofs leaves the lock untouched and reports the failure loudly, because
# removing the lock of a live worktree corrupts its git index.
#
# A lock too YOUNG to judge is the one refusal worth waiting out, so the retries
# are followed by a bounded wait of at most $STALE_WORKTREE_LOCK_AGE_SECS +
# $STALE_WORKTREE_LOCK_WAIT_MARGIN_SECS seconds, itself hard-capped at
# $STALE_WORKTREE_LOCK_WAIT_CAP_MAX_SECS so the bound is a property of this code
# rather than of whoever set the threshold env var. The timer is never itself the
# proof: when it ends, the age and the holder check are BOTH re-read and removal
# happens only if worktree_lock_is_provably_stale passes on that fresh read.
STALE_WORKTREE_LOCK_AGE_SECS=${FM_STALE_WORKTREE_LOCK_AGE_SECS:-30}
# Floor under that threshold. A threshold of 0 is not a fast setting, it is the
# age proof switched off: no age can be below it, so removal would rest on the
# lsof probe alone - exactly the single-proof state this block forbids.
STALE_WORKTREE_LOCK_AGE_MIN_SECS=1
# Margin on top of the threshold so a lock that ages into judge-ability right at
# the boundary is still judged; the wait can never exceed threshold + margin.
STALE_WORKTREE_LOCK_WAIT_MARGIN_SECS=5
# Absolute ceiling on that wait. Teardown blocks in the foreground while it runs,
# and firstmate must not sit in a long foreground operation with tasks in flight,
# so no threshold setting can stretch the wait past this.
STALE_WORKTREE_LOCK_WAIT_CAP_MAX_SECS=60
# Ceiling on a single lsof probe, applied only when timeout/gtimeout exists.
LSOF_PROBE_TIMEOUT_SECS=5
TREEHOUSE_RETURN_LOCK_RETRIES=${FM_TREEHOUSE_RETURN_LOCK_RETRIES:-3}
TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=${FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS:-1}
# Tri-state answer to "does anything still hold this?". UNKNOWN is never stale.
LOCK_HOLDER_LIVE=0
LOCK_HOLDER_NONE=1
LOCK_HOLDER_UNKNOWN=2
# teardown_treehouse_return's distinct "a lock blocked the return" exit code.
TEARDOWN_TREEHOUSE_LOCK_REFUSED=2
# Why the last staleness check said no; set by worktree_lock_is_provably_stale.
TEARDOWN_LOCK_STALE_REASON=
# Set alongside it when the ONLY thing missing was age - the one refusal that
# waiting can turn into a decision. Empty for every other refusal.
TEARDOWN_LOCK_STALE_TOO_YOUNG=

# Accepts "1", "0.5", ".5"; rejects junk. case globs, not [[ =~ ]], for bash 3.2.
lock_wait_secs_is_valid() {
  case "$1" in
    ''|.|*[!0-9.]*|*.*.*) return 1 ;;
  esac
  return 0
}
if ! lock_wait_secs_is_valid "$TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS"; then
  echo "teardown: invalid lock retry wait '$TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS'; using 1s" >&2
  TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=1
fi
case "$TREEHOUSE_RETURN_LOCK_RETRIES" in
  ''|*[!0-9]*)
    echo "teardown: invalid lock retry count '$TREEHOUSE_RETURN_LOCK_RETRIES'; using 3" >&2
    TREEHOUSE_RETURN_LOCK_RETRIES=3
    ;;
esac
# Half the safety invariant lives in this number, so no value may reach the age
# comparison in a form that skips the proof: junk or a negative makes
# `[ "$age" -lt abc ]` exit 2, which reads as "old enough", and a zero (or any
# sub-floor value) is never above an age at all, so both would leave removal
# resting on the lsof probe alone.
case "$STALE_WORKTREE_LOCK_AGE_SECS" in
  ''|*[!0-9]*)
    echo "teardown: invalid stale lock age '$STALE_WORKTREE_LOCK_AGE_SECS'; using 30s" >&2
    STALE_WORKTREE_LOCK_AGE_SECS=30
    ;;
esac
if [ "$STALE_WORKTREE_LOCK_AGE_SECS" -lt "$STALE_WORKTREE_LOCK_AGE_MIN_SECS" ]; then
  echo "teardown: stale lock age ${STALE_WORKTREE_LOCK_AGE_SECS}s would disable the age proof; using ${STALE_WORKTREE_LOCK_AGE_MIN_SECS}s" >&2
  STALE_WORKTREE_LOCK_AGE_SECS=$STALE_WORKTREE_LOCK_AGE_MIN_SECS
fi

# Absolute path git reports for a `rev-parse` spec inside $dir, resolved with the
# ambient repo environment scrubbed. `-C` does NOT override an inherited GIT_DIR,
# GIT_WORK_TREE or GIT_INDEX_FILE: with one of those set, git answers for that
# other repository instead, and the answer would become both the lsof probe target
# and the rm target. Non-zero when git or the path resolution cannot answer.
worktree_git_rev_parse_path() {
  local dir=$1 out abs_dir
  shift
  out=$(unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE; git -C "$dir" rev-parse "$@" 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  case "$out" in
    /*) removal_target_abs_path "$out" 2>/dev/null || return 1 ;;
    *)
      abs_dir=$(removal_target_abs_path "$dir" 2>/dev/null) || return 1
      removal_target_abs_path "$abs_dir/$out" 2>/dev/null || return 1
      ;;
  esac
}

# Absolute path of the git index lock for a worktree or repo dir. Non-zero when
# it cannot be resolved (dir missing, not a git worktree at all, or git named a
# path that is not this dir's own index.lock).
#
# The result is the only thing the recovery ever probes or removes, so it is
# validated here rather than at the removal: the basename must be index.lock, and
# the file must live under the dir itself, its git dir, or its common git dir. A
# path failing either check is unresolvable - the caller then refuses instead of
# touching anything.
worktree_git_lock_path() {
  local dir=$1 lock abs_dir owner spec
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  lock=$(worktree_git_rev_parse_path "$dir" --git-path index.lock) || return 1
  [ "${lock##*/}" = "index.lock" ] || return 1
  abs_dir=$(removal_target_abs_path "$dir" 2>/dev/null) || return 1
  if path_is_within "$abs_dir" "$lock"; then
    printf '%s\n' "$lock"
    return 0
  fi
  for spec in --git-dir --git-common-dir; do
    owner=$(worktree_git_rev_parse_path "$dir" "$spec") || continue
    if path_is_within "$owner" "$lock"; then
      printf '%s\n' "$lock"
      return 0
    fi
  done
  return 1
}

# The mountpoint named by an lsof "can't stat() <fstype> file system <path>"
# warning, or nothing for any other line.
lsof_warning_mount_path() {
  case "$1" in
    "lsof: WARNING: can't stat()"*" file system "*)
      printf '%s\n' "${1#*" file system "}"
      ;;
  esac
}

# Is $path the same as, or inside, directory $ancestor? Pure string comparison:
# a match it misses only leaves today's classification in place, while the
# matches it makes are what push a doubtful probe to UNKNOWN.
path_is_within() {
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] && [ -n "$path" ] || return 1
  case "$ancestor" in */) ancestor=${ancestor%/} ;; esac
  if [ -z "$ancestor" ]; then
    case "$path" in /*) return 0 ;; *) return 1 ;; esac
  fi
  [ "$path" = "$ancestor" ] && return 0
  case "$path" in "$ancestor"/*) return 0 ;; esac
  return 1
}

# Is everything lsof wrote to stderr while probing $2 a warning about some OTHER
# filesystem? Those ("lsof: WARNING: can't stat() nsfs file system
# /run/docker/netns/default" plus its indented continuation) are routine on any
# host with docker, NFS or autofs mounts and say nothing about the target, so
# they are noise. This is a whitelist, not a blacklist: ANY other diagnostic - a
# status error on the target path, a usage error, a missing pwd entry - means
# lsof did not answer for this path, and an unrecognized one is treated the same
# way. The whitelist is scoped to OTHER filesystems: when the mount a warning
# names contains the probe target, lsof could not walk the target's own
# filesystem, so its silence about the target is not evidence either.
lsof_diagnostics_are_benign() {
  local err=$1 target=$2 line mount
  [ -n "$err" ] || return 0
  if printf '%s\n' "$err" | grep -qv -e '^lsof: WARNING:' -e '^[[:space:]]' -e '^$'; then
    return 1
  fi
  while IFS= read -r line; do
    mount=$(lsof_warning_mount_path "$line")
    [ -n "$mount" ] || continue
    if path_is_within "$mount" "$target"; then
      return 1
    fi
  done <<EOF
$err
EOF
  return 0
}

# `timeout`/`gtimeout` binary to bound an lsof probe with, or nothing when the
# host has neither (stock macOS).
lsof_probe_timeout_bin() {
  local bin
  for bin in timeout gtimeout; do
    if command -v "$bin" >/dev/null 2>&1; then
      printf '%s\n' "$bin"
      return 0
    fi
  done
  # "No timeout binary" is a normal answer, not a failure. Stated explicitly so a
  # caller under set -eu never depends on the exit status of a trailing loop.
  return 0
}

# Does any live process hold $target open? LIVE / NONE / UNKNOWN.
#
# `lsof -t` puts PIDs on stdout and every diagnostic on stderr, so the answer is
# read from stdout alone and stderr is printed but never counted as evidence -
# that is what keeps a benign mount warning from masking a real "nothing holds
# this". Empty stdout is NONE only when lsof actually RAN and finished: a missing
# binary (caught by the caller's command -v guard), a non-1 exit, an unreadable
# target, or any diagnostic outside the benign set is UNKNOWN, never no-holder.
#
# The probe is capped at $LSOF_PROBE_TIMEOUT_SECS seconds wherever a timeout
# binary exists, so a hung mount cannot wedge teardown; a probe cut short that way
# is UNKNOWN whatever it managed to print, so the cap can only refuse a removal.
lsof_path_holder_state() {
  local target=$1 pids errfile err status=0 timeout_bin
  errfile=$(mktemp "${TMPDIR:-/tmp}/fm-teardown-lsof.XXXXXX" 2>/dev/null) || {
    echo "teardown: could not stage the lsof check for $target, so it is no evidence" >&2
    return "$LOCK_HOLDER_UNKNOWN"
  }
  timeout_bin=$(lsof_probe_timeout_bin)
  if [ -n "$timeout_bin" ]; then
    pids=$("$timeout_bin" "$LSOF_PROBE_TIMEOUT_SECS" lsof -t -- "$target" 2>"$errfile") || status=$?
  else
    pids=$(lsof -t -- "$target" 2>"$errfile") || status=$?
  fi
  err=$(cat "$errfile" 2>/dev/null || true)
  rm -f "$errfile"
  [ -z "$err" ] || printf '%s\n' "$err" | sed 's/^/teardown: lsof: /' >&2
  if [ -n "$timeout_bin" ] && { [ "$status" -eq 124 ] || [ "$status" -eq 137 ]; }; then
    echo "teardown: lsof check for $target timed out after ${LSOF_PROBE_TIMEOUT_SECS}s, so it is no evidence" >&2
    return "$LOCK_HOLDER_UNKNOWN"
  fi
  if [ "$status" -ne 0 ] && [ "$status" -ne 1 ]; then
    echo "teardown: lsof check for $target could not run (exit $status), so it is no evidence" >&2
    return "$LOCK_HOLDER_UNKNOWN"
  fi
  if [ -n "$pids" ]; then
    case "$pids" in
      *[!0-9[:space:]]*)
        echo "teardown: lsof check for $target returned unexpected output, so it is no evidence" >&2
        return "$LOCK_HOLDER_UNKNOWN"
        ;;
    esac
    return "$LOCK_HOLDER_LIVE"
  fi
  if [ "$status" -eq 0 ]; then
    echo "teardown: lsof check for $target reported a match but named no process, so it is no evidence" >&2
    return "$LOCK_HOLDER_UNKNOWN"
  fi
  if lsof_diagnostics_are_benign "$err" "$target"; then
    return "$LOCK_HOLDER_NONE"
  fi
  echo "teardown: lsof check for $target did not complete cleanly, so it is no evidence" >&2
  return "$LOCK_HOLDER_UNKNOWN"
}

# LIVE / NONE / UNKNOWN across the lock file AND the worktree dir. NONE only when
# both probes positively answered "nothing holds this"; a missing lsof is UNKNOWN.
worktree_lock_holder_state() {
  local lock=$1 dir=$2 target state unknown=
  command -v lsof >/dev/null 2>&1 || return "$LOCK_HOLDER_UNKNOWN"
  for target in "$lock" "$dir"; do
    [ -n "$target" ] || continue
    state=$LOCK_HOLDER_LIVE
    lsof_path_holder_state "$target" || state=$?
    if [ "$state" -eq "$LOCK_HOLDER_LIVE" ]; then
      return "$LOCK_HOLDER_LIVE"
    fi
    if [ "$state" -eq "$LOCK_HOLDER_UNKNOWN" ]; then
      unknown=1
    fi
  done
  if [ -n "$unknown" ]; then
    return "$LOCK_HOLDER_UNKNOWN"
  fi
  return "$LOCK_HOLDER_NONE"
}

# Seconds since $lock was last modified; non-zero when that cannot be read.
worktree_lock_age() {
  local lock=$1 mtime now
  mtime=$(fm_path_mtime "$lock") || return 1
  case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s) || return 1
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$(( now - mtime ))"
}

# The safety invariant itself: true ONLY when the lock exists, nothing holds it,
# and it is old enough. Any doubt is a false, with the reason left in
# TEARDOWN_LOCK_STALE_REASON for the caller's error message.
worktree_lock_is_provably_stale() {
  local lock=$1 dir=$2 state age
  TEARDOWN_LOCK_STALE_REASON=
  TEARDOWN_LOCK_STALE_TOO_YOUNG=
  if [ -z "$lock" ] || [ ! -e "$lock" ]; then
    TEARDOWN_LOCK_STALE_REASON="the lock file is no longer there"
    return 1
  fi
  state=$LOCK_HOLDER_LIVE
  worktree_lock_holder_state "$lock" "$dir" || state=$?
  if [ "$state" -eq "$LOCK_HOLDER_LIVE" ]; then
    TEARDOWN_LOCK_STALE_REASON="a live process still holds the lock or the worktree"
    return 1
  fi
  if [ "$state" -eq "$LOCK_HOLDER_UNKNOWN" ]; then
    TEARDOWN_LOCK_STALE_REASON="lsof cannot answer whether a process still holds it (missing or errored), so staleness is unprovable"
    return 1
  fi
  if ! age=$(worktree_lock_age "$lock"); then
    TEARDOWN_LOCK_STALE_REASON="its mtime could not be read"
    return 1
  fi
  if [ "$age" -lt "$STALE_WORKTREE_LOCK_AGE_SECS" ]; then
    TEARDOWN_LOCK_STALE_REASON="it is only ${age}s old (staleness threshold ${STALE_WORKTREE_LOCK_AGE_SECS}s)"
    TEARDOWN_LOCK_STALE_TOO_YOUNG=1
    return 1
  fi
  return 0
}

# Wait, BOUNDED, for a lock that is merely too young to be judged. The cap is
# $STALE_WORKTREE_LOCK_AGE_SECS + $STALE_WORKTREE_LOCK_WAIT_MARGIN_SECS seconds,
# itself clamped to $STALE_WORKTREE_LOCK_WAIT_CAP_MAX_SECS so no threshold setting
# can stretch this foreground wait, and the loop can never run past it; a lock born
# during teardown (age ~0s) otherwise outlives the short retry window without ever
# becoming judge-able.
# Returns as soon as the lock is old enough, vanishes, or the cap is reached -
# and NONE of those outcomes is proof of anything. The caller must re-run
# worktree_lock_is_provably_stale on a fresh read before removing anything.
worktree_lock_wait_until_judgeable() {
  local lock=$1 label=$2 cap deadline now age
  cap=$(( STALE_WORKTREE_LOCK_AGE_SECS + STALE_WORKTREE_LOCK_WAIT_MARGIN_SECS ))
  [ "$cap" -le "$STALE_WORKTREE_LOCK_WAIT_CAP_MAX_SECS" ] || cap=$STALE_WORKTREE_LOCK_WAIT_CAP_MAX_SECS
  now=$(date +%s) || return 1
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  deadline=$(( now + cap ))
  echo "teardown: $label index.lock $lock is too young to judge; waiting up to ${cap}s for it to clear or age past the ${STALE_WORKTREE_LOCK_AGE_SECS}s staleness threshold" >&2
  while [ -e "$lock" ]; do
    age=$(worktree_lock_age "$lock") || return 1
    [ "$age" -lt "$STALE_WORKTREE_LOCK_AGE_SECS" ] || return 0
    now=$(date +%s) || return 1
    case "$now" in ''|*[!0-9]*) return 1 ;; esac
    [ "$now" -lt "$deadline" ] || return 1
    sleep 1
  done
  return 0
}

# True when treehouse/git output carries the transient index.lock signature. Any
# other return failure must not enter the retry-then-remove path at all.
treehouse_return_is_index_lock_error() {
  printf '%s\n' "$1" | grep -Eq "Unable to create ['\"]?[^']*index\.lock['\"]?: File exists"
}

# Return a worktree or secondmate home via `treehouse return --force`, tolerating
# a transient or provably-stale git index.lock. Exit codes:
#   0                                 returned
#   $TEARDOWN_TREEHOUSE_LOCK_REFUSED  a lock outlived the retries and the bounded
#                                     wait and was not proved stale, or was proved
#                                     stale but could not be removed; either way it
#                                     is LEFT IN PLACE and the return did not happen
#   1                                 any other failure
teardown_treehouse_return() {
  local dir=$1 cd_dir=$2 label=$3 out lock attempt=0 remove=0

  # Capture both streams: non-lock failures stay visible, and the lock signature
  # can be matched even when the lock file itself races away mid-check.
  if out=$( ( cd "$cd_dir" && treehouse return --force "$dir" ) 2>&1 ); then
    [ -z "$out" ] || printf '%s\n' "$out"
    return 0
  fi
  [ -z "$out" ] || printf '%s\n' "$out" >&2
  treehouse_return_is_index_lock_error "$out" || return 1

  lock=$(worktree_git_lock_path "$dir") || lock=""
  while [ "$attempt" -lt "$TREEHOUSE_RETURN_LOCK_RETRIES" ]; do
    attempt=$(( attempt + 1 ))
    echo "teardown: $label return hit a git index.lock (${lock:-index.lock}); waiting ${TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS}s and retrying ($attempt/$TREEHOUSE_RETURN_LOCK_RETRIES) - the owning process may simply be exiting" >&2
    sleep "$TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS"
    if out=$( ( cd "$cd_dir" && treehouse return --force "$dir" ) 2>&1 ); then
      [ -z "$out" ] || printf '%s\n' "$out"
      echo "teardown: $label return succeeded on retry; the index.lock cleared on its own" >&2
      return 0
    fi
    [ -z "$out" ] || printf '%s\n' "$out" >&2
    if ! treehouse_return_is_index_lock_error "$out"; then
      echo "teardown: $label return failed with a non-lock error after a retry; leaving any lock alone" >&2
      return 1
    fi
  done

  # Patience exhausted. Re-resolve the lock: it may have appeared, moved, or
  # cleared while we waited.
  lock=$(worktree_git_lock_path "$dir") || lock=""
  if [ -z "$lock" ] || [ ! -e "$lock" ]; then
    echo "ERROR: teardown: $label return kept failing on the index.lock signature across $TREEHOUSE_RETURN_LOCK_RETRIES retries although no lock file is present; $dir was NOT returned" >&2
    return 1
  fi

  # A lock too young to judge is waited out (bounded) and then RE-PROVED from a
  # fresh read - the timer expiring is never itself the proof.
  remove=0
  if worktree_lock_is_provably_stale "$lock" "$dir"; then
    remove=1
  elif [ -n "$TEARDOWN_LOCK_STALE_TOO_YOUNG" ]; then
    worktree_lock_wait_until_judgeable "$lock" "$label" || true
    if [ -e "$lock" ] && worktree_lock_is_provably_stale "$lock" "$dir"; then
      remove=1
    fi
  fi

  if [ "$remove" -eq 1 ]; then
    if ! rm -f "$lock" 2>/dev/null || [ -e "$lock" ]; then
      echo "ERROR: teardown: git index.lock $lock is provably stale but could not be removed." >&2
      echo "ERROR: teardown: the lock is still in place and $label $dir was NOT returned. Clear the lock by hand, then rerun teardown." >&2
      return "$TEARDOWN_TREEHOUSE_LOCK_REFUSED"
    fi
    echo "teardown: removed provably-stale git index.lock $lock (no live holder, age >= ${STALE_WORKTREE_LOCK_AGE_SECS}s); retrying $label return" >&2
  elif [ ! -e "$lock" ]; then
    echo "teardown: git index.lock $lock cleared on its own before any removal was needed; retrying $label return" >&2
  else
    echo "ERROR: teardown: refusing to remove git index.lock $lock: $TEARDOWN_LOCK_STALE_REASON." >&2
    echo "ERROR: teardown: the lock was left in place and $label $dir was NOT returned. Confirm no git process is running against that worktree, clear the lock, then rerun teardown." >&2
    return "$TEARDOWN_TREEHOUSE_LOCK_REFUSED"
  fi

  if out=$( ( cd "$cd_dir" && treehouse return --force "$dir" ) 2>&1 ); then
    [ -z "$out" ] || printf '%s\n' "$out"
    echo "teardown: $label return succeeded after stale-lock cleanup" >&2
    return 0
  fi
  [ -z "$out" ] || printf '%s\n' "$out" >&2
  echo "ERROR: teardown: $label return still failing after clearing the index.lock; $dir was NOT returned" >&2
  return 1
}
# FM-LOCK-RECOVERY-END

validate_firstmate_home_for_removal() {
  local home=$1 label=$2 expected_id=${3:-} abs_home_path marker_id conflict child_id child_home
  [ -n "$home" ] || return 0
  [ -e "$home" ] || return 0
  abs_home_path=$(validate_removal_target "$home" "$label") || return 1
  if [ ! -f "$abs_home_path/$SUB_HOME_MARKER" ]; then
    echo "REFUSED: unsafe $label removal target $home is not a seeded secondmate home" >&2
    return 1
  fi
  if [ -n "$expected_id" ]; then
    marker_id=$(cat "$abs_home_path/$SUB_HOME_MARKER" 2>/dev/null || true)
    if [ "$marker_id" != "$expected_id" ]; then
      echo "REFUSED: unsafe $label removal target $home is marked for secondmate ${marker_id:-unknown}, expected $expected_id" >&2
      return 1
    fi
  fi
  validate_firstmate_operational_dirs_for_removal "$abs_home_path" "$label" || return 1
  conflict=$(registered_descendant_home_for_removal "$SECONDMATE_REG" "$abs_home_path" || true)
  if [ -z "$conflict" ]; then
    conflict=$(registered_descendant_home_for_removal "$abs_home_path/data/secondmates.md" "$abs_home_path" || true)
  fi
  if [ -n "$conflict" ]; then
    IFS=$'\t' read -r child_id child_home <<EOF
$conflict
EOF
    echo "REFUSED: unsafe $label removal target $home contains registered secondmate home $child_home for $child_id" >&2
    return 1
  fi
  printf '%s\n' "$abs_home_path"
}

remove_firstmate_home() {
  local home=$1 label=$2 expected_id=${3:-} abs_home_path
  [ -n "$home" ] || return 0
  [ -e "$home" ] || return 0
  abs_home_path=$(validate_firstmate_home_for_removal "$home" "$label" "$expected_id") || return 1
  [ -n "$abs_home_path" ] || return 0
  if firstmate_home_has_treehouse_slot "$abs_home_path"; then
    command -v treehouse >/dev/null 2>&1 || {
      echo "error: treehouse command not found; cannot return $label $abs_home_path" >&2
      return 1
    }
    teardown_treehouse_return "$abs_home_path" "$FM_ROOT" "$label" || {
      echo "error: treehouse return failed for $label $abs_home_path; lease may still be held" >&2
      return 1
    }
    return 0
  fi
  safe_rm_rf "$abs_home_path" "$label"
}

validate_firstmate_home_children_removal() {
  local home=$1 sub_state child_meta child_id child_wt child_proj child_kind child_home
  sub_state="$home/state"
  [ -d "$sub_state" ] || return 0
  for child_meta in "$sub_state"/*.meta; do
    [ -e "$child_meta" ] || continue
    child_id=$(basename "$child_meta" .meta)
    child_wt=$(meta_value "$child_meta" worktree)
    child_kind=$(meta_value "$child_meta" kind)
    [ -n "$child_kind" ] || child_kind=ship
    if [ "$child_kind" = secondmate ]; then
      child_home=$(meta_value "$child_meta" home)
      [ -n "$child_home" ] || child_home=$child_wt
      validate_firstmate_home_for_removal "$child_home" "child firstmate home" "$child_id" >/dev/null || return 1
      validate_firstmate_home_children_removal "$child_home" || return 1
    elif [ -n "$child_wt" ] && [ -d "$child_wt" ]; then
      child_proj=$(meta_value "$child_meta" project)
      validate_child_worktree_for_removal "$child_wt" "$child_proj" >/dev/null || return 1
    fi
  done
}

cleanup_firstmate_home_children() {
  local home=$1 sub_state child_meta child_id child_t child_wt child_proj child_kind child_home
  sub_state="$home/state"
  [ -d "$sub_state" ] || return 0
  for child_meta in "$sub_state"/*.meta; do
    [ -e "$child_meta" ] || continue
    child_id=$(basename "$child_meta" .meta)
    child_t=$(meta_value "$child_meta" window)
    child_wt=$(meta_value "$child_meta" worktree)
    child_proj=$(meta_value "$child_meta" project)
    child_kind=$(meta_value "$child_meta" kind)
    [ -n "$child_kind" ] || child_kind=ship
    if [ -n "$child_t" ]; then
      tmux kill-window -t "$child_t" 2>/dev/null || true
    fi
    if [ "$child_kind" = secondmate ]; then
      child_home=$(meta_value "$child_meta" home)
      [ -n "$child_home" ] || child_home=$child_wt
      if [ -n "$child_home" ] && [ -d "$child_home" ]; then
        cleanup_firstmate_home_children "$child_home"
        remove_firstmate_home "$child_home" "child firstmate home" "$child_id"
      fi
    elif [ -n "$child_wt" ] && [ -d "$child_wt" ]; then
      validate_child_worktree_for_removal "$child_wt" "$child_proj" >/dev/null || return 1
      rm -f "$child_wt/.claude/settings.local.json" "$child_wt/.opencode/plugins/fm-turn-end.js" "$child_wt/.fm-grok-turnend"
      if [ -n "$child_proj" ] && [ -d "$child_proj" ] && command -v treehouse >/dev/null 2>&1; then
        ( cd "$child_proj" && treehouse return --force "$child_wt" ) || safe_rm_rf_child_worktree "$child_wt" "$child_proj"
      else
        safe_rm_rf_child_worktree "$child_wt" "$child_proj"
      fi
    fi
    remove_grok_turnend_auth "$sub_state" "$child_id"
    rm -f "$sub_state/$child_id.status" "$sub_state/$child_id.turn-ended" "$sub_state/$child_id.check.sh" "$sub_state/$child_id.meta" "$sub_state/$child_id.pi-ext.ts" "$sub_state/$child_id.grok-turnend-token"
  done
}

remove_secondmate_registry_entry() {
  local id=$1 tmp
  [ -f "$SECONDMATE_REG" ] || return 0
  tmp="$SECONDMATE_REG.tmp.$$"
  grep -vE "^- $id( |$)" "$SECONDMATE_REG" > "$tmp" || true
  mv "$tmp" "$SECONDMATE_REG"
}

if [ "$KIND" = secondmate ]; then
  [ -n "$HOME_PATH" ] || HOME_PATH=$WT
  validate_firstmate_home_for_removal "$HOME_PATH" "secondmate home" "$ID" >/dev/null || exit 1
  if [ "$FORCE" = "--force" ]; then
    validate_firstmate_home_children_removal "$HOME_PATH" || exit 1
  fi
fi

if [ "$KIND" = secondmate ] && [ "$FORCE" != "--force" ]; then
  SUB_STATE="$HOME_PATH/state"
  if [ -d "$SUB_STATE" ]; then
    for child_meta in "$SUB_STATE"/*.meta; do
      [ -e "$child_meta" ] || continue
      echo "REFUSED: secondmate $ID still has in-flight work in $SUB_STATE." >&2
      echo "Found $(basename "$child_meta"). Let that home finish or explicitly discard with --force." >&2
      exit 1
    done
  fi
fi

if [ "$KIND" = secondmate ] && [ "$FORCE" = "--force" ]; then
  cleanup_firstmate_home_children "$HOME_PATH"
fi

if [ -d "$WT" ] && [ "$FORCE" != "--force" ]; then
  if [ "$KIND" = secondmate ]; then
    :
  elif [ "$KIND" = scout ]; then
    # Scout worktrees are scratch by contract, but only once the deliverable exists.
    REPORT="$DATA/$ID/report.md"
    if [ ! -f "$REPORT" ]; then
      echo "REFUSED: scout task $ID has no report at $REPORT." >&2
      echo "The report is the work product. Have the crewmate write it (or get the captain's explicit OK to discard, then --force)." >&2
      exit 1
    fi
  else
    # The fm-spawn hook file is ours, never work product; ignore it in the dirty check.
    dirty=$(git -C "$WT" status --porcelain 2>/dev/null | grep -vE '^\?\? (\.claude/|\.fm-grok-turnend$)' | head -1 || true)
    # Reachability test: is HEAD reachable from ANY remote-tracking branch? Empty
    # means the work is already pushed (a fork is a remote too, so upstream-
    # contribution PRs pushed to a fork pass here). Non-empty does NOT prove the work
    # is unlanded: a squash or rebase merge rewrites the branch into a new commit on
    # the default branch, and a repo that auto-deletes the head branch on merge also
    # drops its remote-tracking ref - so a merged-and-deleted branch trips this test
    # while being fully landed. We therefore treat reachability as a fast accept, not
    # the sole verdict, and fall through to a landed-work check before refusing.
    unpushed=$(git -C "$WT" log --oneline HEAD --not --remotes -- 2>/dev/null | head -5 || true)
    if [ -n "$unpushed" ] && [ "$MODE" = local-only ]; then
      # local-only ships have no remote in the common case, so the "on a remote"
      # test above is expected to be non-empty. The work is safe once it is merged
      # into the local default branch (firstmate does that merge on the captain's
      # approval). Refuse until then.
      DEFAULT=$(default_branch) || { echo "REFUSED: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master." >&2; exit 1; }
      unmerged=$(git -C "$WT" log --oneline HEAD --not "$DEFAULT" -- 2>/dev/null | head -5 || true)
      if [ -n "$dirty" ] || [ -n "$unmerged" ]; then
        echo "REFUSED: local-only worktree $WT has work not yet merged into $DEFAULT and not on any remote." >&2
        [ -n "$dirty" ] && echo "uncommitted changes present" >&2
        [ -n "$unmerged" ] && printf 'commits not yet on %s:\n%s\n' "$DEFAULT" "$unmerged" >&2
        echo "Merge the branch into local $DEFAULT first (bin/fm-merge-local.sh after the captain approves), or push to a fork/remote, or get the captain's explicit OK to discard, then --force." >&2
        exit 1
      fi
    elif [ -n "$dirty" ]; then
      # Uncommitted changes are never landed and the reset would discard them; always
      # refuse, regardless of whether the committed work itself has landed.
      echo "REFUSED: worktree $WT has uncommitted changes." >&2
      echo "uncommitted changes present" >&2
      echo "Commit them (or get the captain's explicit OK to discard, then --force)." >&2
      exit 1
    elif [ -n "$unpushed" ]; then
      # Commits not reachable from any remote. Before refusing, recognize LANDED work:
      # a merged PR for the current HEAD or content already in the up-to-date default
      # branch. On a gh lookup error work_is_landed falls back to the content check,
      # and if that is also inconclusive it returns false - so we never silently allow
      # teardown of possibly-unlanded work; only genuinely unlanded work is refused.
      branch=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
      if ! work_is_landed "$branch"; then
        echo "REFUSED: worktree $WT has work not on any remote and not landed." >&2
        printf 'unpushed commits:\n%s\n' "$unpushed" >&2
        echo "Push the branch, land its PR, or get the captain's explicit OK to discard, then --force." >&2
        exit 1
      fi
    fi
  fi
fi

# Note the local task branch so it can be dropped after the return below, keeping
# the shared repo from accumulating refs. Detached or unnamed HEAD has nothing to drop.
if [ -d "$WT" ] && [ "$KIND" != secondmate ]; then
  branch=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
  # Remove our hook file so a reused pool worktree cannot fire signals for a dead task.
  rm -f "$WT/.claude/settings.local.json" "$WT/.opencode/plugins/fm-turn-end.js" "$WT/.fm-grok-turnend"
  # Reap a watcher that ran as THIS worktree's own firstmate home. A self-dev home
  # arms bin/fm-watch.sh setsid/disown (ppid=1, FM-WATCH-DETACH-1), so the treehouse
  # return below - which only kills processes still parented into the worktree -
  # leaves it running forever (two 3-day-old orphans observed in COCKPIT-FM-CLEANUP-1).
  # Scoped by the ABSOLUTE worktree path so it matches only this home's watcher, never
  # a sibling's or the captain's - that is exactly why the bare `pkill -f
  # bin/fm-watch.sh` is banned but this full-path form is safe. || true: pkill exits
  # non-zero on no match, and set -e is active.
  pkill -f "$WT/bin/fm-watch.sh" 2>/dev/null || true
  # Kills remaining processes in the worktree (including the agent), resets, returns
  # to pool. treehouse resolves the pool from the working directory, so run it from
  # the project. teardown_treehouse_return absorbs the transient index.lock a killed
  # crew git process leaves behind, and removes that lock only when it is provably
  # stale (see the FM-LOCK-RECOVERY block).
  # Guarded against set -eu (finding F11): a return failure (lingering run
  # processes, a release race) used to abort teardown BEFORE kill-window and
  # meta-clear, stranding a husk window and a ghost meta - warn and continue, the
  # same pattern as the fleet-sync call below. The lock-refused case keeps that
  # husk cleanup but is surfaced as a loud error, not a soft warning: the worktree
  # is still checked out and still locked, and a human has to resolve it.
  return_rc=0
  teardown_treehouse_return "$WT" "$PROJ" "worktree" || return_rc=$?
  if [ "$return_rc" -eq "$TEARDOWN_TREEHOUSE_LOCK_REFUSED" ]; then
    echo "ERROR: teardown: worktree $WT was NOT returned - its git index.lock could not be safely recovered (see above). Continuing so the window and meta are still cleared; rerun 'treehouse return --force $WT' once the lock is resolved." >&2
  elif [ "$return_rc" -ne 0 ]; then
    echo "warning: treehouse return --force failed for $WT (rerun it manually); continuing teardown so the window and meta are still cleared" >&2
  fi
  # Drop the task branch only after a SUCCESSFUL return, and from the project repo:
  # deleting it needs no index write there, so it cannot be blocked by the very
  # index.lock this teardown just recovered from - unlike the worktree-side detach
  # this replaces, which failed under a lock and leaked the ref every time. When the
  # return did not succeed (lock-refused, or the warn-and-continue path above) the
  # branch is deliberately left alone: it is still checked out in that worktree and
  # still holds the work. Best-effort either way.
  if [ "$return_rc" -eq 0 ] && [ "$branch" != HEAD ] && [ -n "$branch" ]; then
    git -C "$PROJ" branch -D "$branch" >/dev/null 2>&1 || true
  fi
fi

tmux kill-window -t "$T" 2>/dev/null || true
if [ "$KIND" = secondmate ]; then
  [ -n "$HOME_PATH" ] || HOME_PATH=$WT
  remove_firstmate_home "$HOME_PATH" "secondmate home" "$ID"
  remove_secondmate_registry_entry "$ID"
fi
remove_grok_turnend_auth "$STATE" "$ID"
rm -f "$STATE/$ID.status" "$STATE/$ID.turn-ended" "$STATE/$ID.check.sh" "$STATE/$ID.meta" "$STATE/$ID.pi-ext.ts" "$STATE/$ID.grok-turnend-token"
if [ "$KIND" != scout ] && [ "$KIND" != secondmate ] && [ "$MODE" != local-only ]; then
  "$FM_ROOT/bin/fm-fleet-sync.sh" "$PROJ" || true
fi
echo "teardown $ID complete (window $T, worktree $WT)"
backlog_refresh_reminder
