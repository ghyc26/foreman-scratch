---
name: code-update
description: Updates the foreman codebase based on the user's prompt — any code, config, or docs change. Follows the coding standards and the daemon's invariants, produces a user-approved plan, runs the CI gates, reviews the change with code-review, commits on a branch, pushes, and opens a pull request without asking. Invoked with /code-update.
---

# Code Update

## When to use this skill
Use this skill for every change to this repository: a fix, a refactor, a new capability, a
config or docs update. There is no separate feature skill in foreman — this is the one
editing path, so its scope runs from a one-line log tweak to a new pipeline phase.

Typical triggers: `/code-update`, "refactor X", "fix the Y bug", "add Z to the sweep",
"rename this", "update the README for that", "change the `foreman.yml` default".

Contrast with:
- `code-review` — reviews a change without making one (this skill invokes it in Step 8).
- `skill-review` — reviews a `SKILL.md`, not code.
- `task-run` — executes a forge issue by invoking this skill non-interactively (see below).

## Input
The user's free-form description of the change. No file path is required.

## Input validation
- If no description is provided, ask the user what they'd like to change before proceeding.

## Non-interactive mode (invoked from `task-run` or any autonomous run)

`task-run` invokes this skill with the Skill tool, passing the task's description. In that
mode there is no user at the keyboard, so the approval gates below would stall the run. When
invoked non-interactively:

- **Proceed without waiting** at the clarifying-questions gate (Step 1) and the plan approval
  (Step 3). Take scope from the task description alone, prefer the narrowest reading that
  satisfies it, and **record every decision made on the user's behalf** in the final report
  and the PR description.
- **The protected-change gates still stop.** Any change in the classes listed under
  "Protected changes" (Step 1) halts the run and reports back — under a headless `task-run`
  that is an exit to `status: needs-human`. Do not decide your way past a gate that exists
  to protect an invariant.
- **Code review disposition is fixed** (Step 8): fix Blockers and Warnings, re-stage, and
  record Suggestions in the PR description instead of fixing them — there is no pick-list to
  offer.
- **Push and PR proceed without asking** (Step 9), in every mode. Under `task-run`, delivery
  stops at the commit: commit on the current branch (the task branch `task-run` created) and
  return, because `task-run` owns the push, the PR (with its `Closes #n` body), and the
  status flip — do not push or open a PR from this skill when invoked by `task-run`. That
  push and PR happen without a confirmation step: under `/task-run --headless` the task's
  arming event (`status: ready` applied by a ready-applier — see `task-run`'s Headless mode)
  is the standing authorization; under an interactive `/task-run`, the invocation itself is.
  Under any other autonomous run, push and open the PR exactly as the interactive flow does.
  Never push to the default branch non-interactively. Record the decisions made on the
  user's behalf and any open review Suggestions in the final report so `task-run` can put
  them in the PR body.

## The foreman invariants (never weaken these)
Every change this skill makes must uphold the invariants in `CLAUDE.md` and
`docs/standards/coding-standards.md`. Treat a change that weakens one as unacceptable —
plan around it, don't work around it:

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
  changes take the light path noted in Steps 2, 5, and 8.
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
`bash scripts/lib/forge-cli.test.sh` when `forge-cli.sh` changed. Watch for the failure
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

### Step 8. Code review
Run a code review before opening the pull request.

1. Stage the files changed by this task with `git add <paths>` — stage the intended paths
   explicitly rather than sweeping unrelated working-tree changes into the review.
2. Invoke the `code-review` skill as a subagent to review the staged changes. It runs the
   CI gates again and returns a structured verdict. For docs-only changes it still runs:
   it checks the text against the code it describes.
3. Present the verdict (PASS / FAIL) and findings grouped by severity (Blockers, Warnings,
   Suggestions).
4. Ask the user which items to address. Offer these options:
   - **Fix blockers only** (recommended if FAIL)
   - **Fix blockers + warnings**
   - **Fix all items**
   - **Pick specific items** (let the user list item numbers)
   - **Skip** (deliver as-is)
5. If the user selects items, fix them and re-stage.

### Step 9. Commit and open the pull request
After verification and code review are both completed:

1. If you're on `main`, create a branch first (`task/<issue>-<slug>` when the change comes
   from a forge issue, otherwise a short descriptive name). Commit the staged change with a
   message that says what changed and why.
2. Fetch the latest default branch (`forge_default_branch`, normally `main`) and merge it
   into the branch. Resolve any merge conflicts before
   proceeding, and re-run Step 5 if the merge touched code.
3. State the branch and PR plan (title + summary) as a report, not a question. **Do not ask
   for permission to push or open the PR.** Completing Step 8 — every Blocker and Warning
   fixed, or explicitly left as-is by the user's disposition choice — is the authorization;
   the user opted into this skill knowing a PR is its deliverable. The only reason to stop
   here is a Step 8 finding the user has not yet dispositioned.
4. Push the branch, then source `scripts/lib/forge-cli.sh`, call `forge_detect_cli`, and
   create the PR with `forge_pr_create` and a summary of what changed, the decisions made,
   and any review Suggestions left open. Only if the user asked up front for a different
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
- `.agents/skills/code-review/SKILL.md` — the review this skill invokes in Step 8.
