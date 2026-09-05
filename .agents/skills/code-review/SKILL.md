---
name: code-review
description: Reviews local staged files, the current branch, or a PR (GitHub or Gitea) against coding standards. Invoked with /code-review.
---

# Code Review Skill

## When to use this skill
Use this skill when the user requests a code review of their current changes or a specific Pull Request (GitHub or Gitea, whichever `origin` points at).

## What it does
- Gathers project context (coding standards, architecture invariants) and analyzes the diff
- Reviews staged changes, the current branch against the default branch, or a PR
- Reads full files when changes touch trait boundaries, the claim/pipeline/review/sweep path, or forge-facing parsing
- Runs the CI trio: `cargo fmt --check`, `cargo clippy -D warnings`, `cargo test --workspace`
- Classifies findings by severity (Blocker / Warning / Suggestion) and outputs a structured verdict

## Input

All forms start by sourcing `scripts/lib/forge-cli.sh` and calling `forge_detect_cli`, which sets `FORGE_CLI` to `gh` or `tea` from the repo's `origin` remote (override with `FOREMAN_FORGE_CLI=tea|gh`). The script only detects the CLI and exposes `forge_default_branch`; the diff and checkout commands below are chosen by the skill per `FORGE_CLI`.

- **`/code-review`** with staged files: Review them using `git status` and `git diff --cached`.
- **`/code-review`** with nothing staged, on a branch other than the default: Review the
  branch — `base=$(forge_default_branch)`, then `git fetch origin "$base"` and
  `git diff "origin/$base...HEAD"` (plus `git diff HEAD` for uncommitted changes, if any).
  This is the form to use on a task branch (`task/<issue>-*`) whose work is already committed.
  A branch that has merged the default branch back in reviews correctly with the same
  three-dot diff — `origin/$base...HEAD` shows only the branch's own changes.
- **`/code-review [PR NUMBER]`**: Review a specific PR.
  - **Hybrid Approach**: First, perform a static analysis of the changes —
    `gh pr diff [PR NUMBER]`, or `tea pulls [PR NUMBER] --fields diff -o simple`.
  - If the diff is too complex, or if running tests/clippy is necessary to verify the PR,
    pull the changes locally (ensuring the user's working directory is clean or stashed
    first): record `original=$(git branch --show-current)`, then
    `gh pr checkout [PR NUMBER]` or `tea pulls checkout [PR NUMBER]`. When the checks are
    done, return with `git checkout "$original"` before writing the review — a review must
    not leave the user on a different branch.

## Input validation

- If no PR number is provided, no files are staged, and the current branch **is** the default branch, ask the user what they want to review (unstaged changes, a branch name, or a PR number).
- If `forge_default_branch` fails (no forge access), fall back to `main` and say so in the output.
- If a PR number is provided but does not exist or cannot be fetched (`gh pr view` / `tea pulls [PR NUMBER]` fails), report the error and stop.
- If a PR checkout is needed and the working directory has uncommitted changes, warn the user and ask them to commit or stash before proceeding. Do not overwrite local changes.

## Review process

### 1. Gather context
Read the reference documents listed below to understand the project's coding standards and architecture invariants. Then analyze the diff.

If a referenced document path is missing, search under `docs/standards/` before falling back to another source. In this repository, the coding standards live at `docs/standards/coding-standards.md`.

For large diffs (many files), prioritize reviewing:
1. Files on the correctness-critical path — `claim.rs`, `claimable.rs`, `markers.rs`, `facts.rs`, `sweep.rs`, `review.rs`, `pipeline.rs`, `worker.rs` — and anything implementing or widening a trait (`Forge`, `CommandRunner`, `Notifier`, `Clock`)
2. Files that parse forge-supplied text (`metadata.rs`, `markers.rs`, `review.rs`, `commands.rs`, `vendors.rs`) — untrusted-input handling
3. New files (likely to have the most issues)
4. Files with the most significant changes (by diff size)

Skim simple changes (renames, config tweaks, formatting, docs) rather than deep-reading every file.

### 2. Analyze changed files in context
For each changed file in the diff:
- If the change touches function signatures, trait definitions or implementations, marker/comment formats, or the claimable predicate, read the full file(s) for surrounding context — do not review the diff in isolation. A marker-format change must be checked against both parser and emitter, and against the fake forge.
- If the change touches the `foreman.yml` schema (`config.rs`), confirm the commented example `foreman.yml`, `README.md` § Configuration, and § 5 Config of `docs/setup-linux.md` and `docs/setup-macos.md` still match.
- For simple, self-contained changes (e.g., log message updates, doc tweaks), the diff alone is sufficient.

### 3. Format, lint, build, and test
Run the same three gates CI runs, from the workspace root:

```bash
cargo fmt --all --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
```

`cargo test` builds every target, so a build failure surfaces there. Always run the full workspace — do not skip crates. If the change touches anything that compiles differently on macOS (`locks.rs`, `runner.rs`, `libc` use), also run `scripts/check-macos.sh`; on Linux it needs zig, and if it cannot run, list it as "not run" under Check results — that is an environment limitation, not a finding.

**Shell scripts** (`scripts/**/*.sh`): the cargo gates see none of them, so they need their own pass. Run `sh -n <file>` on every changed script (a syntax failure is a Blocker); run `shellcheck` if installed, otherwise list it as "not run" under Check results. Then review manually for the failure modes no gate catches: PATH assumptions under `sudo` or non-login shells (rustup's cargo lives in `~/.cargo/bin`), unquoted expansions, commands needing privileges the invoking user may lack (`journalctl`, `systemctl`), and time-window or polling-loop race assumptions. A new script ranks with "new files" in the review priorities — in this repository's first script review, every finding was in the shell script and none were visible to the cargo gates.

The review is read-only: do not format, fix, or commit code. Report what the gates say. When the user has also asked for fixes, still produce the full structured verdict first (so the pre-fix state is on record), then apply the fixes and re-run the gates — never fix silently mid-review.

**Interpreting results for the review:**
- Build failures → automatic **Blocker** findings. Continue the review — the static analysis is still valuable.
- Test failures → **Blocker** findings. Include the failing test names and error output. A failure in `tests/race.rs` or `tests/fleet.rs` is a Blocker even if the change "shouldn't" affect it — those pin the fleet's exit conditions.
- Clippy warnings on changed files → **Warning** findings (they fail CI, so the PR cannot merge as-is).
- `fmt --check` differences → **Warning** findings.
- A behavior change in the claim / pipeline / review / sweep path with no new or updated offline test → **Warning** finding.

### 4. Classify findings
Analyze the diff against the coding standards and architecture invariants. Combine with results from Step 3. Classify each finding by severity:

- **Blocker**: Build errors, test failures, a forge error that can escape the tick loop and exit the daemon, free prose from an issue/PR/review flowing into a decision, a token reaching argv/config/logs, a label write that bypasses the comment-CAS winner, a `set-labels`-style write instead of add/remove, or a severe architecture violation. These are showstoppers.
- **Warning**: Clippy/fmt findings *related to the changes*, `unwrap`/`expect`/`panic!` in production paths (outside the accepted `Mutex::lock().unwrap()` case), reading live config mid-task instead of a snapshot, missing edge cases, missing tests, or other deviations from coding standards.
- **Suggestion**: Nice-to-have improvements, better naming, or minor refactoring ideas.

## Pass/Fail Criteria

- **FAIL**: If there is at least one **Blocker**, the code review fails.
- **PASS**: If there are only **Warnings** and **Suggestions** (or no issues at all), the code review passes.

## Output

Output a structured review directly in the chat — never as a PR or issue comment. In this repository, review comments in the `foreman-review` format are the machine record of the automated loop and are trusted only from `marker-authors`; a human-driven review must not emit `foreman-*` markers or anything that could be mistaken for them. Include:
- **Verdict**: PASS or FAIL
- **Findings by severity**: Blockers first, then Warnings, then Suggestions — with file paths and line references
- **Check results**: pass/fail for each of fmt, clippy, and test from Step 3 (and check-macos: pass/fail/not run), with failing test names
- **What was reviewed**: staged files, `origin/<base>...HEAD` for a branch, or the PR number — and the base branch used

## Reference documents
- `docs/standards/coding-standards.md` — Project coding standards (primary review baseline)
- `CLAUDE.md` — Build commands, crate layout, and the cross-module invariants
- `docs/fleet.md` — Multi-worker semantics and degraded mode (for changes to caps, routing, or the sweep)
