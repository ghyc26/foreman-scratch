#!/usr/bin/env bash
# task-status.sh - perform one of /task-run's issue status transitions as a
# single command.
#
# Every transition below is a *sequence* of forge calls: read the current
# labels, remove only what is present, add the target, read back and check.
# Run by hand, step by step, that sequence is exactly the kind of thing a
# weaker model abbreviates or skips outright - foreman#514 is the issue for
# runs that never reached `in-progress` at all. So the whole sequence lives
# here, behind one invocation with one exit status: either the issue ends in
# the state the subcommand names, or the script exits non-zero saying which
# label is wrong. `.agents/skills/task-run/SKILL.md` calls it and maps a
# non-zero exit to its needs-human abort.
#
# Being one plain command is part of the point: nothing here has to be
# reproduced in the caller's shell, and the caller never sources
# lib/forge-cli.sh itself.
#
# Usage:
#   scripts/task-status.sh start       <issue> [--cloud]
#   scripts/task-status.sh in-review   <issue>
#   scripts/task-status.sh done        <issue>
#   scripts/task-status.sh needs-human <issue>
#
# The transitions, exactly as SKILL.md defines them:
#
#   start        Adds the plain `in-progress` run label, then consumes the
#                `status: ready` arming (removed, never re-applied) and
#                clears the legacy `in progress` spelling - in that order,
#                so a failed add leaves the task still armed. It never adds
#                `status: in-progress`: under the daemon the claim already
#                set it behind a `foreman-claim` marker, and a by-hand run
#                must not, because the coordinator's sweep reads that label
#                with no live claim as drift and strips it within a tick.
#                --cloud leaves `status: ready` alone as well, for a
#                cloud-started run, which consumes no arming and adds no
#                `status:` label of its own.
#   in-review    Clears the run label and moves the issue to
#                `status: in-review` (a PR was opened).
#   done         Clears the run label, moves the issue to `status: done`,
#                and - once those labels are verified - closes it. Closing
#                belongs to this subcommand because SKILL.md Step 7 defines
#                the two as one transition, and a half-applied one leaves
#                the board wrong in precisely the way this script exists to
#                prevent. It comes last because it is the one step a re-run
#                cannot undo.
#   needs-human  Clears the run label and moves the issue to
#                `status: needs-human` (the abort).
#
# The three closing transitions also clear whichever other work-state
# `status:` label is standing, so the issue ends up with at most one - but
# never `status: ready`, which only `start` consumes. Like `start` they add
# their target before removing anything; see `_task_status_plan` for why
# that order is load-bearing rather than incidental.
#
# Labels are written only through add-label / remove-label calls, one label
# per call - never a set-labels write, which would race the daemon's own
# label writes and could wipe `task` or `surface:*`. `status: merge-ready`
# is the daemon's to set and is never a target here, though a closing
# transition clears it like any other work-state label.
#
# No token is read, passed, or printed: `gh` / `tea` take their own from the
# environment.

set -uo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

RUN_LABEL="in-progress"
RUN_LABEL_LEGACY="in progress"
READY_LABEL="status: ready"

# Every `status:` label, for the "at most one" rule: a transition adds its
# own first and only then removes the ones actually present, so the issue
# ends up carrying one. That order is load-bearing - see `_task_status_plan`.
STATUS_LABELS=(
  "status: ready"
  "status: in-progress"
  "status: in-review"
  "status: needs-human"
  "status: merge-ready"
  "status: done"
)

usage() {
  cat <<'USAGE'
usage: task-status.sh <command> <issue> [--cloud]

commands:
  start        consume `status: ready` and add the `in-progress` run label
  in-review    clear the run label and set `status: in-review`
  done         clear the run label, set `status: done`, and close the issue
  needs-human  clear the run label and set `status: needs-human`

options:
  --cloud      `start` only: leave `status: ready` alone (cloud-started run)

Exits non-zero, with the offending label named, if the issue does not end in
the state the command promises.
USAGE
}

# --- pure helpers (offline-testable; see task-status.test.sh) --------------

# _task_status_has <label> <newline-separated label list>
#
# Exits 0 when the label is present as a whole line.
#
# The list is an argument fed through a here-string, never a pipeline: with
# `grep -q` exiting at the first match, `printf ... | grep -Fxq` reports the
# upstream printf's SIGPIPE status under `set -o pipefail`, so a label that
# *is* present reads as absent once the list outgrows the pipe buffer. That
# would turn an `absent` check into a false pass - silently defeating the
# read-back this script exists for - so no helper here uses a pipeline.
_task_status_has() {
  grep -Fxq -- "$1" <<<"$2"
}

# _task_status_target <command> prints the `status:` label a command moves the
# issue to. `start` sets none, and prints nothing.
_task_status_target() {
  case "$1" in
    start) printf '' ;;
    in-review) printf 'status: in-review' ;;
    done) printf 'status: done' ;;
    needs-human) printf 'status: needs-human' ;;
    *) return 1 ;;
  esac
}

# _task_status_plan <command> [cloud|normal] <current labels>
#
# Prints the ordered forge writes as tab-separated `op<TAB>label` lines (tab,
# so the legacy `in progress` spelling survives the round trip). Pure: it
# reads only the label list it is given, and emits nothing for a write that
# would be a no-op, so a re-run against an issue already in the target state
# plans zero writes.
#
# The order matters, because the executor stops at the first failure and the
# state it stops in has to be the recoverable one. `start` therefore adds
# `in-progress` *first*, before consuming the arming and before clearing the
# legacy spelling: a failed add then leaves the task still armed and still
# carrying whatever it had, rather than disarmed and marked with nothing.
#
# `status: ready` is never removed by a closing transition, only by `start`.
# Starting work consumes the arming; aborting does not, and an abort can
# happen before Step 3 ever runs (an eligibility, authorship, or
# authorization failure). To `claimable.rs` a ready-applier removing the
# label with no claim comment between is a *revocation*, and `/foreman retry`
# never re-stamps it - so a needs-human abort that stripped `ready` would
# leave a task no one could re-queue without re-arming it by hand. The daemon
# makes the same exception (`pipeline.rs` removes only `status: in-progress`
# and `status: in-review` when it escalates).
_task_status_plan() {
  local command="$1" mode="${2:-normal}" current="${3:-}" target label

  case "$command" in
    start)
      if ! _task_status_has "$RUN_LABEL" "$current"; then
        printf 'add\t%s\n' "$RUN_LABEL"
      fi
      if [[ "$mode" != "cloud" ]] && _task_status_has "$READY_LABEL" "$current"; then
        printf 'remove\t%s\n' "$READY_LABEL"
      fi
      if _task_status_has "$RUN_LABEL_LEGACY" "$current"; then
        printf 'remove\t%s\n' "$RUN_LABEL_LEGACY"
      fi
      ;;
    in-review | done | needs-human)
      target="$(_task_status_target "$command")" || return 1
      # Target first, removals after - the same add-first doctrine `start`
      # follows, and here it closes a window the daemon itself would walk
      # into. Removing first leaves the issue momentarily carrying *none* of
      # the three work-state labels, which is exactly the drift `sweep.rs`
      # corrects by re-adding `status: in-progress`; the read-back below
      # then asserts that label absent and the transition fails on a task
      # nothing was wrong with. Adding first makes the transient state two
      # status labels instead of zero. (The daemon's own `announce_pr_opened`
      # runs the same pair in the opposite order, but it does not verify, so
      # it absorbs the outcome where this script would report it.)
      #
      # How much that buys differs by transition, and it is not "the race is
      # closed for all three":
      #   in-review    covered. Two labels is the state the sweep's drift fix
      #                tolerates - it acts only when all three are absent -
      #                and the board's own precedence renders the
      #                destination, so the window is benign either way.
      #   needs-human  covered, and more strongly: the sweep returns on the
      #                escalated path before the drift fix is reached at all.
      #   done         *not* covered, and cannot be. `status: done` is not
      #                work state - the daemon never writes it and does not
      #                count it - so once the removals land the issue reads
      #                as zero work-state labels no matter what order we used
      #                (the pre-reorder sequence ended identically). The
      #                exposure is one round trip until the close, it is
      #                self-limiting because a closed issue leaves the open
      #                poll entirely and `clear_closed_task_labels` strips
      #                the label anyway, and a re-run recovers it.
      if ! _task_status_has "$target" "$current"; then
        printf 'add\t%s\n' "$target"
      fi
      for label in "$RUN_LABEL" "$RUN_LABEL_LEGACY"; do
        if _task_status_has "$label" "$current"; then
          printf 'remove\t%s\n' "$label"
        fi
      done
      for label in "${STATUS_LABELS[@]}"; do
        [[ "$label" == "$target" ]] && continue
        [[ "$label" == "$READY_LABEL" ]] && continue
        if _task_status_has "$label" "$current"; then
          printf 'remove\t%s\n' "$label"
        fi
      done
      ;;
    *)
      return 1
      ;;
  esac
}

# _task_status_expect <command> [cloud|normal]
#
# Prints the end state the command promises, as `present<TAB>label` /
# `absent<TAB>label` lines. The post-write read-back is checked against this,
# so a forge call that reported success without landing is still caught.
#
# The closing transitions walk `STATUS_LABELS` with the same two skips as
# `_task_status_plan` - the target, and `status: ready` - deliberately, so
# that every label the planner can remove is also a label the read-back
# asserts gone. Listing the expectations by hand instead left a hole of
# exactly the kind this script exists to close: a `remove status:
# in-progress` that reported success without landing still passed, because
# nothing checked for it. Any label added to one loop must reach the other.
_task_status_expect() {
  local command="$1" mode="${2:-normal}" target label
  case "$command" in
    start)
      printf 'present\t%s\n' "$RUN_LABEL"
      printf 'absent\t%s\n' "$RUN_LABEL_LEGACY"
      [[ "$mode" == "cloud" ]] || printf 'absent\t%s\n' "$READY_LABEL"
      ;;
    in-review | done | needs-human)
      target="$(_task_status_target "$command")" || return 1
      printf 'present\t%s\n' "$target"
      printf 'absent\t%s\n' "$RUN_LABEL"
      printf 'absent\t%s\n' "$RUN_LABEL_LEGACY"
      for label in "${STATUS_LABELS[@]}"; do
        [[ "$label" == "$target" ]] && continue
        [[ "$label" == "$READY_LABEL" ]] && continue
        printf 'absent\t%s\n' "$label"
      done
      ;;
    *)
      return 1
      ;;
  esac
}

# _task_status_check <expectations> <actual labels>
#
# Prints one human-readable line per violated expectation, and exits non-zero
# if there was any; prints nothing and exits 0 when the state matches. Pure.
#
# Both sides are arguments rather than a file or a pipe. An earlier version
# routed the expectations through a `mktemp` file, which failed *open*: if
# mktemp failed the redirect wrote nowhere, the loop read nothing, and the
# check passed over a transition that had not landed - vouching for exactly
# the bug this script exists to catch. There is nothing here left to fail.
# For the same reason an unrecognized expectation is a violation, and so is
# an *empty* expectation set: "checked nothing" must never read as "checked
# it and it was fine", whatever a later edit does to `_task_status_expect`.
_task_status_check() {
  local expect="$1" actual="$2" violations=0 kind label
  if [[ -z "${expect//[[:space:]]/}" ]]; then
    echo "internal error: nothing to verify, the expected end state is empty"
    return 1
  fi
  while IFS=$'\t' read -r kind label; do
    [[ -n "$kind" ]] || continue
    case "$kind" in
      present)
        if ! _task_status_has "$label" "$actual"; then
          echo "expected label [$label] to be present, it is not"
          violations=$((violations + 1))
        fi
        ;;
      absent)
        if _task_status_has "$label" "$actual"; then
          echo "expected label [$label] to be absent, it is still on the issue"
          violations=$((violations + 1))
        fi
        ;;
      *)
        echo "internal error: unrecognized expectation [$kind]"
        violations=$((violations + 1))
        ;;
    esac
  done <<<"$expect"
  [[ "$violations" -eq 0 ]]
}

# --- forge-backed execution ------------------------------------------------

die() {
  echo "task-status: $*" >&2
  exit 1
}

# already_settled <issue> <add|remove> <label>
#
# Did a failed label write fail only because someone else had already put the
# issue where the write was trying to put it? Re-reads the labels and exits 0
# when the intended outcome already holds.
#
# The plan is built from one snapshot, and the daemon writes the same labels
# from its own poll tick - `announce_pr_opened` adds `status: in-review`
# exactly where this script's `in-review` does. Between the snapshot and the
# write, a concurrent daemon tick can make a planned removal redundant, and
# a label removal errors on a label that is no longer there (a REST
# `DELETE .../labels/<name>` answers 404, as `gh issue edit --remove-label`
# used to before forge-cli.sh's gh branch became REST-only).
# Failing then would abort a transition whose end state had already been
# reached, which contradicts this script being safe to re-run. It is not a
# blanket retry: anything else (auth, network, a label that really is still
# standing) still fails, and the read-back afterwards has the final say.
# It says so out loud when it rescues: the failed write has already printed
# the vendor's own error to stderr, and leaving that standing next to a
# final `ok` reads as a partial failure to exactly the kind of caller this
# script exists to keep honest.
already_settled() {
  local issue="$1" op="$2" label="$3" current settled
  current="$(forge_issue_labels "$issue")" || return 1
  case "$op" in
    add)
      _task_status_has "$label" "$current" || return 1
      settled="added"
      ;;
    remove)
      ! _task_status_has "$label" "$current" || return 1
      settled="removed"
      ;;
    *) return 1 ;;
  esac
  echo "task-status: the error above is stale - [$label] was already $settled by another writer, continuing" >&2
}

# Ensure the labels this transition needs exist before it writes them.
#
# `start` seeds the whole set, not just the run label it adds itself, and
# that is deliberate: no daemon code ever creates a label. `GithubForge` and
# `GiteaForge` both only resolve and attach existing ones - and on Gitea
# `resolve_label_id` returns `NotFound` for a name the repo does not have,
# so a missing label makes the daemon's write *fail*, not degrade. Its own
# doc names `forge_issue_ensure_label` here as where labels come from. So
# this is the fleet's only creator of `status: in-progress` and
# `status: merge-ready`, which this skill never writes and the daemon writes
# constantly.
#
# It is not a complete answer: the claim adds `status: in-progress` before
# the agent that runs this script is ever invoked, so on a virgin repo the
# *first* claim is still unseeded - this covers every claim after it, and
# `merge-ready` always, the review loop running long after. Seeding at task
# creation would close that gap properly; `/task-create` is the place, and
# it is not this change's to edit.
#
# The cost is seven `forge_issue_ensure_label` calls once per run, which
# also re-asserts SKILL.md's palette as canonical. On GitHub that is seven
# requests in the steady state: the gh branch reads each label and writes
# only when its colour or description actually differs, so an already-seeded
# repo - every repo, after the first run - pays one request per label and
# fourteen only on the run that creates or corrects them. On Gitea it is
# fourteen every time, because forge-cli.sh's tea branch re-fetches the
# whole label listing before each write. Those shapes belong to
# forge-cli.sh, but these are the numbers a repo actually pays.
ensure_labels() {
  case "$1" in
    start)
      forge_issue_ensure_label "status: ready" "006b75" "Armed for autonomous pickup" >/dev/null || return 1
      forge_issue_ensure_label "status: in-progress" "fbca04" "Task is being worked on" >/dev/null || return 1
      forge_issue_ensure_label "status: in-review" "1d76db" "PR created, awaiting review" >/dev/null || return 1
      forge_issue_ensure_label "status: needs-human" "d93f0b" "Human decision needed" >/dev/null || return 1
      forge_issue_ensure_label "status: merge-ready" "5319e7" "Review loop converged; PR awaits merge" >/dev/null || return 1
      forge_issue_ensure_label "status: done" "0e8a16" "Task completed" >/dev/null || return 1
      forge_issue_ensure_label "$RUN_LABEL" "fef2c0" "Work is actively underway on this task" >/dev/null || return 1
      ;;
    in-review)
      forge_issue_ensure_label "status: in-review" "1d76db" "PR created, awaiting review" >/dev/null || return 1
      ;;
    done)
      forge_issue_ensure_label "status: done" "0e8a16" "Task completed" >/dev/null || return 1
      ;;
    needs-human)
      forge_issue_ensure_label "status: needs-human" "d93f0b" "Human decision needed" >/dev/null || return 1
      ;;
  esac
}

main() {
  local command="${1:-}" issue="${2:-}" mode="normal"

  case "$command" in
    -h | --help | help)
      usage
      exit 0
      ;;
    start | in-review | done | needs-human) ;;
    "")
      usage >&2
      die "no command given"
      ;;
    *)
      usage >&2
      die "unknown command '$command' (start|in-review|done|needs-human)"
      ;;
  esac

  [[ "$issue" =~ ^[0-9]+$ ]] || die "issue number must be digits, got '${issue:-<missing>}'"

  # Options come after the two fixed arguments. Written as a guarded shift
  # with a guarded loop rather than `for arg in "${@:3}"`: bash before 4.4
  # (3.2 is still /bin/bash on macOS) treats an empty `$@` expansion under
  # `set -u` as an unbound variable, and the normal call `start 514` leaves
  # exactly that. Neither the shift nor the loop is reached empty here.
  if [[ $# -gt 2 ]]; then
    local arg
    shift 2
    for arg in "$@"; do
      case "$arg" in
        --cloud)
          [[ "$command" == "start" ]] || die "--cloud applies to 'start' only"
          mode="cloud"
          ;;
        *) die "unknown option '$arg'" ;;
      esac
    done
  fi

  # shellcheck source=lib/forge-cli.sh
  source "$script_dir/lib/forge-cli.sh" || die "cannot source lib/forge-cli.sh"
  forge_detect_cli

  ensure_labels "$command" || die "#$issue $command: ensuring labels failed"

  local before
  before="$(forge_issue_labels "$issue")" || die "#$issue $command: reading labels failed"

  local plan
  plan="$(_task_status_plan "$command" "$mode" "$before")" \
    || die "#$issue $command: planning failed"

  local op label
  while IFS=$'\t' read -r op label; do
    [[ -n "$op" ]] || continue
    case "$op" in
      add)
        forge_issue_add_label "$issue" "$label" >/dev/null \
          || already_settled "$issue" add "$label" \
          || die "#$issue $command: adding label [$label] failed"
        ;;
      remove)
        forge_issue_remove_label "$issue" "$label" >/dev/null \
          || already_settled "$issue" remove "$label" \
          || die "#$issue $command: removing label [$label] failed"
        ;;
      *)
        die "#$issue $command: internal error, unrecognized planned op [$op]"
        ;;
    esac
  done <<<"$plan"

  # Read back and verify. A forge call that reported success but did not land
  # is the failure mode this whole script exists to surface.
  local after expect violations line
  after="$(forge_issue_labels "$issue")" || die "#$issue $command: reading labels back failed"
  expect="$(_task_status_expect "$command" "$mode")" \
    || die "#$issue $command: internal error building the expected end state"

  if ! violations="$(_task_status_check "$expect" "$after")"; then
    echo "task-status: #$issue $command did not take:" >&2
    while IFS= read -r line; do
      [[ -n "$line" ]] && echo "  $line" >&2
    done <<<"$violations"
    exit 1
  fi

  # Closing comes last, and only once the labels are verified: closing an
  # issue whose `status: done` never landed would leave it closed *and*
  # wrong, and closing is the one step here a re-run cannot put back.
  #
  # `done` promises a closed issue as well as its label, so the state is
  # read back rather than `forge_issue_close`'s exit status trusted. The
  # close is rescued the same way a label write is: whether closing an
  # already-closed issue errors or is a no-op differs by forge and version,
  # and this script depends on neither - a failed close whose state reads
  # `closed` is the outcome we wanted, from a re-run or from anyone else.
  # (Anyone else is fine here: nothing in the daemon closes an issue, and a
  # human closing it mid-run has produced the state this promises. A failed
  # close over a *still-open* issue is the real failure, and dies.)
  #
  # The rescue's read doubles as the read-back, so the state is fetched once
  # on either path.
  if [[ "$command" == "done" ]]; then
    local state
    if forge_issue_close "$issue" >/dev/null; then
      state="$(forge_issue_fetch_json "$issue" | jq -r '.state')" \
        || die "#$issue $command: reading the issue state back failed"
    else
      state="$(forge_issue_fetch_json "$issue" | jq -r '.state')" \
        || die "#$issue $command: closing the issue failed"
      [[ "$state" == "closed" ]] \
        || die "#$issue $command: closing the issue failed, it is still '$state'"
      echo "task-status: the error above is stale - #$issue was already closed, continuing" >&2
    fi
    [[ "$state" == "closed" ]] \
      || die "#$issue $command: the issue is still '$state', it did not close"
  fi

  echo "task-status: #$issue $command ok (labels: $(tr '\n' ' ' <<<"$after" | sed 's/ *$//'))"
}

# Sourced by the test file, which exercises the pure helpers directly; only a
# direct run performs forge writes.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
