---
name: code-update
description: Updates the foreman codebase from the user's prompt when the change is not driven by an approved feature spec under docs/features/. Handles code, config, and docs changes; follows the coding standards and daemon invariants; produces a user-approved plan; runs the CI gates and an iterated code-review cycle; commits, pushes, and opens a pull request without asking. Invoked with /code-update.
---

# Code Update

## When to use this skill
Use this skill for every change to this repository that does not come from a feature spec:
a fix, a refactor, a new capability, a config or docs update, a plan under `docs/plans/`.
Its scope runs from a one-line log tweak to a new pipeline phase; the one thing it does not
take is an approved spec under `docs/features/`, which `feature-implement` builds.

Typical triggers: `/code-update`, "refactor X", "fix the Y bug", "add Z to the sweep",
"rename this", "update the README for that", "change the `foreman.yml` default".

Contrast with:
- `feature-implement` — builds or revises a feature from an approved spec under
  `docs/features/`; it mirrors this skill's gates, invariants, and delivery rules, and the
  two must stay in step.
- `code-review` — reviews a change without making one (Step 8's cycle invokes it).
- `skill-review` — reviews a `SKILL.md`, not code.
- `task-run` — executes a forge issue by invoking this skill non-interactively (see below).

## Input
The user's free-form description of the change. No file path is required.

## Input validation
- If no description is provided, ask the user what they'd like to change before proceeding.

## Non-interactive mode (invoked from `task-run` or any autonomous run)

`task-run` invokes this skill with the Skill tool, passing the task's description. In that
mode there is no user at the keyboard, so the approval gates below would stall the run.

**Under `task-run --interactive` there is one** — the operator at the pane. This mode still
applies there (scope still comes from the task description, and delivery still stops at the
commit), but every halt that asks for a **named confirmation** — the protected-change gate —
is instead **put to the operator and waited on**, per `task-run`'s interactive overlay, whose
list of what becomes a question at the pane is exhaustive. Step 8's cycle halts are not
confirmations: nobody at the pane can make a reviewer return a verdict or a red build green,
so they stop in every mode. `feature-implement` carries the same rule; the two stay in step.

When invoked non-interactively:

- **Proceed without waiting** at the clarifying-questions gate (Step 1) and the plan approval
  (Step 3). Take scope from the task description alone, prefer the narrowest reading that
  satisfies it, and **record every decision made on the user's behalf** in the final report
  and the PR description.
- **The protected-change gates still stop.** Any change in the classes listed under
  "Protected changes" (Step 1) halts the run and reports back — under a headless `task-run`
  that is an exit to `status: needs-human`. Do not decide your way past a gate that exists
  to protect an invariant.
- **The code review cycle asks nothing** (Step 8): it fixes every finding it does not
  decline and reports rather than offering choices, so it has no approval gate to map and
  runs identically in both modes. Reaching its iteration limit is **not** an abort: it does
  not halt the run and does not set `status: needs-human`. The still-open findings go in the
  final report — and in the PR description outside `task-run` — for a human to decide. Two
  cycle outcomes do halt it, in either mode: the reviewer-failure exit (the change was never
  reviewed) and a limit exit over a failing CI gate. Neither is a question anyone at a pane
  can answer, so both report back and, under `task-run` in either daemon mode, exit to
  `status: needs-human`.
- **A verification stop returns a report, and a headless or interactive `task-run` preserves the work in a draft PR.**
  A **verification stop** is a stop where the change exists but was not verified: Step 8's
  reviewer-failure exit, any exit with a CI gate still red (a limit exit over a failing
  gate included), and a pre-flight divergence left unfixed because the budget to review the
  fix is gone. Every other stop — a protected change, an invariant conflict, a missing
  description — is not one and aborts as before. Under `task-run`, a verification stop
  returns with its work **staged and uncommitted** (commit nothing, push nothing, open no
  PR from here) and a **verification-stop report** in three parts, each present even when
  empty: **Failed checks** (each gate whose *latest* result is a failure — a gate that failed
  earlier and passed after a fix is resolved and left out — its command, and a bounded
  excerpt of its failing output), **Checks not run** (each gate or check not run or not finished by the end of the run — one that ran later is not listed — and
  why — one you cannot show passed goes here), and **Incomplete review** (why the cycle did
  not conclude: the reviewer that returned nothing, the findings still open with their
  severity, or the unreviewed fix), with the declined register beside them. For a
  `--headless` or `--interactive` `task-run` only, `task-run`'s *Verification-stop recovery
  delivery* then commits and pushes that work, creates or updates a **draft** PR, records
  its URL, and leaves the task `needs-human`. A by-hand `/task-run` has no recovery
  delivery: it hands the report and the staged work to the user. The report states a
  failing check as failing and never softens it; it changes no authorization, and a clean
  task still delivers its ordinary PR at Step 9 exactly as before. Outside `task-run` (by
  hand, or any other autonomous run) a verification stop reports and stops as it always
  did.
- **Push and PR proceed without asking** (Step 9), in every mode. Under `task-run`, delivery
  stops at the commit: commit on the current branch (the task branch `task-run` created) and
  return, because `task-run` owns the push, the PR (with its `Closes #n` body), and the
  status flip — do not push or open a PR from this skill when invoked by `task-run`. That
  push and PR happen without a confirmation step: under `/task-run --headless`, the
  task's authorization (the normal `status: ready` arming event, or the exact
  `foreman cloud session: requested` artefact for a cloud-started run — see
  `task-run`'s Headless mode) is the standing authorization. Under
  `--interactive`, only the normal arming event authorizes delivery; under a
  by-hand `/task-run`, the
  invocation itself is.
  Under any other autonomous run, push and open the PR exactly as the by-hand flow does.
  Never push to the default branch non-interactively. Record the decisions made on the
  user's behalf, the declined register, and any findings left open at the iteration limit in
  the final report so `task-run` can put them in the PR body.

## The foreman invariants (never weaken these)
Every change this skill makes must uphold the invariants in `CLAUDE.md` and
`docs/standards/coding-standards.md`. `feature-implement` points here rather than restating
them, so this list is the one both skills run on. Treat a change that weakens one as
unacceptable — plan around it, don't work around it:

1. **The issue tracker is the only shared store.** Machine state lives in the structured
   `foreman-*` marker comments; `status:*` labels foreman writes are display state,
   re-derivable from the markers. Never introduce a second store (a local file, a database)
   that another worker would have to trust, and never make a label the arbiter of anything.
2. **Claims are comment-id compare-and-swap.** The claim comment goes first, the
   server-assigned id is the tiebreaker, only the winner mutates labels, and only through
   add-label / remove-label endpoints — never a set-labels write. Authorization is
   re-checked on every re-list.
3. **Untrusted text is never interpreted.** Issue bodies, comments, and reviewer output are
   parsed into typed fields; free prose never flows into a decision, and values only ever
   land in fixed CLI argument slots.
4. **Secrets never touch argv, config files, or logs.** Tokens come from the environment
   (`FOREMAN_GITHUB_TOKEN`, `MATTERMOST_TOKEN`); `Debug` impls redact them.
5. **A forge failure is data, not a crash.** Errors from the forge are logged and backed
   off; nothing propagates out of the tick loop and exits the daemon.
6. **Config has drain semantics.** Work takes a `ConfigHandle::snapshot()` when it starts
   and uses it until it ends; a reload affects future claims and turns only.
7. **The exit-condition tests are not negotiable.** `tests/race.rs` (no double-runs, no
   lost tasks), `tests/fleet.rs` (degraded mode), and `tests/loop.rs` (ready → merge-ready)
   are never weakened to make a change pass.

## Process (follow these steps in order)

### Step 1. Clarify the request
- If the user's intent is ambiguous or implementation choices exist, ask clarifying
  questions with recommended options.
- Confirm the scope: what should change and what should stay the same.
- **Classify the change**: code (touches `crates/`), config (`foreman.yml`, `deploy/`,
  `scripts/`), or docs-only (`README.md`, `docs/`, `CLAUDE.md`, `.agents/`). Docs-only
  changes take the light path noted in Steps 2 and 5; Step 8's cycle runs unchanged.
- **Protected changes — stop and confirm explicitly before planning.** These alter a
  fleet-wide contract, so even a request that plainly asks for them gets a named
  confirmation (and halts a non-interactive run):
  - a **marker comment format** — the `foreman-claim` / `foreman-release` markers in
    `markers.rs`, or the `foreman-review` / `foreman-fix` / `foreman-loop` blocks in
    `review.rs` — every worker in the fleet parses these, and old and new daemons overlap
    during a rollout;
  - the **claim protocol or claimable predicate** (`claim.rs`, `claimable.rs`) — race
    safety and authorization semantics;
  - the **`foreman.yml` schema** (`config.rs`) — hot-reloaded on every host, so the
    committed `foreman.yml`, `README.md` § Configuration, and the setup runbooks' § 5 must
    move in step;
  - **weakening an exit-condition test** (`tests/race.rs`, `tests/fleet.rs`,
    `tests/loop.rs`) — including loosening an assertion, skipping a case, or widening a
    timeout to make a change pass.
- Do not proceed to planning until the scope is clear.

### Step 2. Research & context gathering
Before planning, understand the environment:
- Read `CLAUDE.md` (build commands, crate layout, cross-module invariants) and
  `docs/standards/coding-standards.md` (Rust rules, error-handling split, test
  expectations).
- Locate and examine the relevant existing code; match its naming, structure, and idioms.
  Module doc comments (`//!`) at the top of each `src/*.rs` file state that module's
  contract — read the one for every module you will touch.
- Identify dependencies and side effects across the daemon: a change to what the worker
  writes to the forge affects `facts.rs` parsing, the sweep's re-derivation, and
  `FakeForge`; a change to `worker.rs` tick order affects heartbeat timing and the
  integration tests' tick-driven expectations.
- For docs-only changes, read the surrounding document and any code it describes so the
  text stays accurate; skip the code-archaeology above.

### Step 3. Implementation planning
Create a targeted plan:
- **Files to be modified**: list only the files that need to change.
- **Scope boundary**: explicitly state what existing behavior is being preserved and will
  not be touched.
- **Architecture**: describe how the change fits the existing module split and trait
  boundaries (`Forge`, `CommandRunner`, `Notifier`, `Clock`, `ProcessProbe`) — new
  behavior goes in the module that owns the concern, not into `worker.rs` or
  `pipeline.rs` by default.
- **Forge-facing changes**: if anything the daemon writes to or reads from the forge
  changes, say how the emitter, the parser, and `FakeForge` change together.
- **Invariant check**: confirm the plan upholds every foreman invariant above.
- **Testing strategy**: name the offline test that will prove the change — a
  `#[cfg(test)]` case in the module, or a scenario in `tests/loop.rs` / `race.rs` /
  `fleet.rs` against `FakeForge`, `TestClock`, and the scripted runner. A live forge run is
  never the only evidence.
- **Edge cases**: address error states (forge errors, timeouts, missing PR, malformed
  markers) — fail closed toward `needs-human` rather than shipping a wrong or partial
  action.

Ask the user clarifying questions if implementation choices need to be made. When asking
questions, provide options with a recommended one. Show the complete plan to the user and
obtain explicit approval before proceeding.

### Step 4. Implementation
Once the plan is approved:
- Implement the changes incrementally.
- Follow the coding standards: `thiserror` typed errors in library modules, `anyhow` only at
  the binary edge; no `unwrap`/`expect`/`panic!` in production paths beyond the accepted
  `Mutex::lock().unwrap()`; newtypes and enums over primitives; `tracing` for logs.
- Keep the diff focused; do not reformat or rename across modules you aren't otherwise
  touching. Formatting is `cargo fmt --all` only.
- Add or update the test named in the plan alongside the code, not afterwards.

### Step 5. Verification
Run the CI gates yourself from the workspace root — there is no separate test skill:

```bash
cargo fmt --all --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
```

Always run the full workspace — do not skip crates. If the change touches anything that
compiles differently on macOS (`locks.rs`, `runner.rs`, `libc` use), also run
`scripts/check-macos.sh`; on Linux it needs zig, and if it cannot run, say so in the
report.
**Shell scripts** (`scripts/**/*.sh`): the cargo gates see none of them. Run `sh -n <file>`
on every changed script (a syntax failure blocks), `shellcheck` if installed, and
`bash scripts/lib/forge-cli.test.sh` when `forge-cli.sh` changed,
`bash scripts/lib/daemon-log.test.sh` when `daemon-log.sh` or a redeploy script changed,
`bash scripts/task-status.test.sh` when `task-status.sh` changed, and
`bash scripts/ticket-timeline.test.sh` when `ticket-timeline.sh` changed.
Watch for the failure
modes `code-review` lists for scripts: PATH assumptions under `sudo` or non-login shells,
unquoted expansions, commands needing privileges the invoking user may lack.

Verification must never touch the real world: no forge writes, no daemon started against a
real repository, no reading of tokens. Docs-only changes skip the cargo gates.

### Step 6. Pre-flight checklist
Verify the implementation against the original stated change:
- Re-read the user's original request.
- For **each stated change**, confirm the implementation matches.
- For **each item in the scope boundary**, confirm it is unaffected (no regressions).
- Re-confirm **every foreman invariant** still holds in the final diff.
- Flag any divergence to the user with an explanation.

### Step 7. Finalize
- Update project documentation that describes the affected code: the module's `//!` doc
  comment, `CLAUDE.md`'s invariants or layout, `README.md` (status, layout, configuration),
  the setup runbooks under `docs/`, or the commented `foreman.yml` for config changes.
- If the change diverged from the plan (e.g., a file was added or an approach was adjusted),
  note the divergence for the commit message and PR description.

### Step 8. Iterated code review
Review the staged change, fix what the review finds, and review again — so that the fixes a
review prompts are themselves reviewed — until the reviewer comes back clean or the iteration
limit is reached.

**This is this skill's own pre-PR review cycle, and it is unrelated to the daemon's
cross-vendor review/fix loop.** That loop (`review.rs`, the `foreman-review` / `foreman-fix` /
`foreman-loop` markers, the `max-rounds` setting, `status: merge-ready`) runs *after* a PR
exists and is driven by other vendors' agents on the forge. This cycle runs *before*
delivery, entirely inside one invocation of this skill, and touches none of those markers,
settings, or labels. `feature-implement` step 11 runs this same cycle around a wider reviewer
set. The shared parts — review, report, clean check, limit check, fix, decline, the register,
the post-cycle pre-flight, and the iteration budget — stay in step, so a change to any of
them belongs in both files.

The cycle asks the user nothing: it fixes every finding it does not decline, and reports
rather than offering choices. Interactive and non-interactive runs behave identically — the
cycle's two halting exits below stop in either mode, so they are exceptions to "the cycle
never halts", not to that.

Two rules bind every exit. **A finding that reports a failing CI gate is never declinable**,
and **no exit delivers while a gate is red**: a red build stops the cycle before Step 9 in
either mode — under `task-run`, in either daemon mode, an exit to `status: needs-human`.
That red-build stop, the reviewer-failure exit, and an unfixed pre-flight divergence below
are this skill's **verification stops**: the change was produced and staged but not verified.
Under `task-run` each returns the work staged and uncommitted with the three-part
verification-stop report described under *Non-interactive mode*, which a `--headless` or
`--interactive` `task-run` turns into a draft PR (its *Verification-stop recovery
delivery*; a by-hand run hands both to the user); nothing in this cycle commits,
pushes, or opens that PR, and none of them reaches Step 9's delivery.

**Before the first iteration:**

1. Stage the files changed by this task with `git add <paths>` — stage the intended paths
   explicitly rather than sweeping unrelated working-tree changes into the review.
2. Open an empty **declined register** and set the iteration counter to 1. Both persist
   across every iteration of the cycle.
3. **Budget the iterations.** The iteration limit is an upper bound, not a target. Under
   `task-run --headless` this skill runs inside one bounded implement turn
   (`crates/foreman/src/vendors.rs`, `IMPLEMENT_TIMEOUT`); an interactive session is bounded
   instead by its ceiling budget; the idle budget is only relevant when tmux activity
   stops. Every iteration re-runs the full CI gates through `code-review`, so prefer the
   smallest fix that closes a finding and never spend an iteration on cosmetics no finding
   raised — a cosmetic finding is still fixed or declined on the grounds below, never skipped
   for budget. A turn killed at its mode's bound is not one of the three exits named below:
   the daemon sees the turn itself fail — a headless timeout through
   `vendors::extract_turn_result` into `pipeline.rs`'s `finish_implement`, an exhausted
   session budget through its `tend_session` — and escalates straight to
   `status: needs-human`, delivering nothing, even if a PR was already open.

The cycle has exactly three exits, named here and used by those names in Step 9: the
**clean-result exit**, the **limit exit**, and the **reviewer-failure exit**.

**Each iteration** — review, report, check for a clean result, check the limit, fix,
decline:

1. **Review.** Invoke the `code-review` skill as a subagent to review the staged changes,
   instructing it to **report only** — it must not fix, stage, or commit, because the cycle's
   safety rests on the staged tree being exactly what the review read. It runs the CI gates
   itself and returns a structured verdict. For docs-only changes it still
   runs: it checks the text against the code it describes. If it returns no usable verdict —
   it errors, times out, or comes back as prose — that iteration did not happen: retry it
   once, and if it fails again take the **reviewer-failure exit**. A missing verdict is never
   a clean result. That exit is a halt, not a delivery: the change has not been reviewed, so
   report the failure and stop before Step 9 in either mode — under `task-run`, in either
   daemon mode, an exit to `status: needs-human`. It never reaches Step 9, and unlike an
   ordinary limit exit it authorizes nothing.
2. **Report** — the iteration number first, then the verdict (PASS / FAIL), `code-review`'s
   **Check results** (fmt / clippy / test, and check-macos where it ran), and every finding
   grouped by severity (Blockers, Warnings, Suggestions). Carry the check results explicitly:
   `code-review` grades a fmt or clippy failure as a *Warning*, and a clippy failure outside
   the changed files as no finding at all, so the verdict and the finding list alone can read
   clean while a gate is red — and the red-build rule above is judged on those results.
   From iteration 2 on, also say which
   of the previous iteration's findings are gone, which came back, and which are already on
   the declined register. This is a report, not a question: do not ask the user which items
   to address.
3. **Check for a clean result — against the report just produced, before fixing anything.**
   Count the **open findings**: those not already on the declined register. Zero means the
   reviewer has settled, so take the **clean-result exit** here. Evaluate the exit at this
   point and nowhere else: the fix and decline steps below make "every finding is fixed or
   declined" true by construction, so a check placed after them would pass on the first
   iteration every time and no fix would ever be reviewed.
4. **Check the iteration limit — also before fixing anything.** If the counter is at or past
   7, take the **limit exit** here, with the findings this report just listed still open and
   **unfixed**. Leaving ahead of the fix is what gives "still open" a referent: the staged
   tree stays the one this iteration's review read and gated, and every fix the cycle did
   make was seen by a later review. Fixing first and then stopping would deliver an
   unreviewed, ungated edit — the very defect this cycle exists to remove. **One exception:
   if this iteration's verdict includes a failing CI gate, the limit exit is a stop, not a
   flag**, per the red-build rule above.
5. **Fix every open finding** — every finding not on the register, Blockers, Warnings, and
   Suggestions alike — then re-stage.
   Keep each fix inside Step 3's scope boundary; a fix that would push outside it is grounds
   to decline the finding, not to widen the change. If a finding the previous iteration fixed
   has come back, that fix was wrong: change approach rather than re-applying it. If a fix
   moves code away from what a document Step 7 updated describes, update that document in the
   same iteration and re-stage it too.
6. **Decline only what must not be fixed**, recording it on the declined register with a
   one-line rationale.

Then increment the iteration counter and begin the next iteration.

**The declined register.** "Iterate until there are no findings" is unreachable if a reviewer
keeps re-raising something that must not be fixed, so a declined finding is recorded once,
with its severity and a one-line rationale, and stops counting toward the exit check from
the *next* iteration's check onward — so a report of nothing but must-decline findings costs
one more iteration to confirm, and that confirming pass is deliberate. The grounds are
narrow. Decline a finding only when:

- it is **wrong** — it misreads the diff, or the code already does what it asks;
- acting on it would **weaken a foreman invariant** (above), contradict the approved plan or
  its scope boundary, or contradict an authority document (`CLAUDE.md`,
  `docs/standards/coding-standards.md`);
- it is **out-of-diff** — a pre-existing problem in a neighbouring file, where fixing it
  would widen the change past Step 3's scope boundary;
- it **conflicts with another finding**, and you applied the one the standards support.

Never decline a finding for being merely a Suggestion, for being inconvenient, or for having
been raised twice. Match a re-raised finding against the register on **substance, not
wording**. The whole register goes in the PR description (Step 9) — or, under `task-run`, in
the final report, which `task-run` carries into the PR body — and a declined **Blocker** gets
its own called-out line there. That line is the escalation: the cycle does not halt for it,
but no PR merges without a human, and the called-out line is what puts the decision in front
of the person who merges.

**Reaching the iteration limit is a flag, not a stop — unless a CI gate is red (item 4),
which stops.** Otherwise, at iteration 7 the cycle ends with the findings just reported still
open, and Step 9 still delivers: the PR description — or,
under `task-run`, the final report — carries an `## Outstanding review findings` heading that
names every still-open finding with its severity and says a human must decide it. Say the
same in the final report to the user. That heading is ordinary prose in the PR body: it is
never a `foreman-*` marker, and nothing in the daemon parses it.

**On leaving the cycle**, if any fix was made, re-run **Step 6's pre-flight checklist**
against the final diff: nothing inside the cycle checks the change back against the user's
original request, Step 3's scope boundary, or the foreman invariants. Step 5 does not need a
second run — `code-review` runs Step 5's gates itself
(`.agents/skills/code-review/SKILL.md`, *Format, lint, build, and test*: the three cargo
gates, the shell-script pass, and `scripts/check-macos.sh`), so they were re-run in every
iteration. That holds only while the working tree matches what is staged, because those gates
compile the working tree while the review reads the staged diff: if unstaged changes remain
outside the reviewed paths, re-run Step 5 against the final diff before Step 9.

If that pre-flight finds a divergence, fixing it puts an unreviewed, ungated edit back into
the staged tree, so do not go straight to Step 9. **Check the budget before fixing:** a
re-entry increments the iteration counter like any other iteration, so if the increment would
put the counter at or past 7, do **not** apply the fix — the budget to review it is gone.
Report the divergence unfixed and stop before Step 9, in either mode; under `task-run`, in
either daemon mode, exit to `status: needs-human`. Otherwise increment the counter, fix,
re-stage, run one more iteration of the cycle so the fix is reviewed and gated like any
other, and pre-flight again. Spending the same budget is what stops repeated pre-flight
misses from looping. If the re-entered iteration does not come back clean, the cycle simply
continues from there.

### Step 9. Commit and open the pull request
After verification is complete, Step 8's cycle has been left by its **clean-result exit** or
its **limit exit** with the still-open findings recorded, and — where any fix was made —
Step 8's re-run of Step 6's pre-flight has passed. The **reviewer-failure exit** does not
reach this step; neither does a limit exit over a failing CI gate.

1. If you're on `main`, create a branch first (`task/<issue>-<slug>` when the change comes
   from a forge issue, otherwise a short descriptive name). Commit the staged change with a
   message that says what changed and why.
2. Fetch the latest default branch (`base=$(forge_default_branch)`, normally `main`) and
   merge it into the branch. Resolve any merge conflicts before
   proceeding, and re-run Step 5 if the merge touched code.
3. State the branch and PR plan (title + summary) as a report, not a question. **Do not ask
   for permission to push or open the PR.** Either of Step 8's two delivering exits — the
   clean-result exit, or the limit exit with every still-open finding recorded — is the
   authorization; the user opted into this skill knowing a PR is its deliverable. Step 8
   leaves nothing for the user to decide before the PR, so open-yet-recorded findings are not
   a reason to stop here.
4. Push the branch, then source `scripts/lib/forge-cli.sh`, call `forge_detect_cli`, and
   create the PR with `forge_pr_create "$base" "<branch>" "<title>" <body_file> 0` — its
   fourth argument is a **file path**, so write the body to a temp file and pass that.
   **Under a daemon `claude -p` turn, run the helper instead of sourcing it** — Claude Code
   refuses `source` outright and no `--allowedTools` entry can grant it, so call
   `scripts/lib/forge-cli.sh forge_pr_create "$base" "<branch>" "<title>" <body_file> 0`
   directly: it runs `forge_detect_cli` itself and dispatches to that one helper with the
   same output and exit status (`task-run`'s **Forge CLI** section has the full rule). This
   skill's own Step 9 only runs push/PR when it is not invoked by `task-run`, so today that
   is not a live path — kept here so it still holds if that ever changes. The
   body carries a summary of what changed, the decisions made,
   how many review iterations ran, and the whole declined register — each entry with its
   severity and rationale, a declined **Blocker** on its own called-out line. **Only if the
   cycle reached the iteration limit**, add an `## Outstanding review findings` section
   naming every still-open finding with its severity and saying a human must decide it.
   Only if the user asked up front for a different
   delivery — push straight to `main` (fast-forward `main` to the branch, push, and delete
   the branch locally and on the remote) or leave it local (stop after the commit) — honor
   that instead; never offer it as a question.
5. **Output the PR URL** (or the pushed commit hash) to the user as plain text — do NOT
   wrap a URL in markdown bold (`**`), italics, or other formatting that would corrupt the
   link.

## Reference documents
- `CLAUDE.md` — build commands, crate layout, and the cross-module invariants (the
  operating baseline).
- `docs/standards/coding-standards.md` — Rust rules and test expectations (primary
  implementation baseline).
- `README.md` — locked design decisions, configuration, and the phased roadmap.
- `docs/fleet.md` — multi-worker routing, the two caps, and degraded mode; read before
  touching caps, routing, or the sweep.
- `.agents/skills/code-review/SKILL.md` — the review Step 8's cycle invokes each iteration.
