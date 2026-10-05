---
name: task-create
description: Creates a forge issue (GitHub or Gitea) as a task with a title, description, optional skill reference, optional spec file, optional surface label, optional daemon metadata, and optional epic and blocker relationships recorded both in the metadata block and as the forge's native links. Invoked with /task-create.
---

# Create Task

## When to use this skill
Use this skill when the user wants to create a new task (forge issue) for the current repository. Typical triggers: `/task-create <title>`, "create a task for ...", "open a task to ...".

`task-run` executes a task after creation — by hand, or under the foreman daemon once a ready-applier adds `status: ready`, in whichever mode the repository's `auto-skills` entry for the task's skill selects (headless, or an operator-driven tmux seat).

## Forge CLI
Source `scripts/lib/forge-cli.sh` and call `forge_detect_cli` at the start; it sets `FORGE_CLI` to `gh` or `tea` from the `origin` remote (override with `FOREMAN_FORGE_CLI=tea|gh`).

```bash
source scripts/lib/forge-cli.sh
forge_detect_cli
```

**Under a daemon `claude -p` turn, run the helpers instead of sourcing them.** Claude Code refuses the `source` line above outright, as evaluating shell code, and no `--allowedTools` entry can grant it. Execute the file with the helper's name and arguments instead, one call per helper:

```bash
scripts/lib/forge-cli.sh forge_issue_fetch_json <number>
scripts/lib/forge-cli.sh forge_issue_ensure_label <name> <color> <description>
```

Each call runs `forge_detect_cli` itself, then that one helper, with the same output and exit status as the sourced function (`task-run`'s **Forge CLI** section has the full rule, including the fleet grant `Bash(scripts/lib/forge-cli.sh:*)`). This form works by hand too.

## Input
- **Title** (required): provided as the argument to `/task-create`.
- **Skill** (optional): can be pre-specified with `--skill <name>`. Defaults to
  `feature-implement` for a `docs/features/` spec and to `code-update` otherwise (see Step 1).
- **Spec** (optional): can be pre-specified with `--spec <repo-relative-path>`.
- **Surface** (optional): `--surface <daemon|forge-adapter|tui|swift>` applies the matching
  `surface: <value>` issue label. `daemon`, `forge-adapter`, and `tui` name the workspace
  surfaces in `docs/architecture/README.md`; `swift` routes Swift/iOS toolchain work to workers
  tagged `swift`. A `--spec` under `docs/features/<surface>/` already names the feature surface, so it is
  taken from the path there and `--surface` is only checked against it (see Input validation).
  When neither is provided, infer the surface only from a strong, unambiguous cue in the title
  or description, such as `TUI`, `daemon`, or `forge-adapter`. Leave the task unlabeled when
  the cue is absent, generic, or points to more than one surface; never guess or prompt for
  the surface. Cross-cutting work, fleet operations, and skill authoring usually remain
  unlabeled.
- **Description** (optional): can be pre-specified with `--description "..."`.
- **Headless flag** (optional): `--headless` writes `headless: yes` into the metadata block, marking the task safe for unattended dispatch. Set it only under the conditions in Step 3's **When to set `headless: yes`** — never prompt for it.
- **Blockers** (optional): `--blocked-by <number>`, repeatable, names an existing issue this task
  cannot start before. The resolved numbers are written into the metadata block as one
  `blocked-by:` key — the machine-readable record of the dependency the description's prose
  states, which `/task-run` checks before starting. A headless run aborts to
  needs-human while a blocker is open. The forge's native "blocked by" link is additionally
  created from the key (Step 3b) so the relationship shows on the issue itself.
- **Epic** (optional): `--parent <number>` names the epic this task belongs to — an existing
  issue carrying the `epic` label, which `task-breakdown` files before its tasks. The
  resolved number is written into the metadata block as the `epic:` key, and the forge's native
  link is additionally created from it (Step 3b): a sub-issue on GitHub, which is what the
  board reads to group a task under its epic; a dependency on Gitea. Never prompt for it — a
  task filed by hand usually has no epic.
- Example usages:
  - `/task-create Reset the sweep requeue budget on an explicit retry`
  - `/task-create "Log the poll backoff delay at info" --description "worker.rs logs the computed next_poll_delay only at debug; promote the backoff case to info so the journal shows rate-limit recovery."`
  - `/task-create "Document the Gitea timeline check" --skill none --description "Verify the tea api timeline filter in task-run against a real Gitea instance and correct the SKILL.md."`
  - `/task-create "Surface the requeue budget on the dashboard" --blocked-by 57 --description "Depends on #57 (the budget reset) landing first; read the budget from the claim record and show it per task."`
  - `/task-create "Add the iOS task detail view" --surface swift --description "Build and verify the SwiftUI task detail view in the iOS app."`
  - `/task-create "Show the claim's build version in the task table" --surface tui --description "The board has the version from the claim marker but never renders it; add it to the task table's detail row."`
  - `/task-create "Versioning C: emit the claim marker's version key" --parent 125 --blocked-by 121 --description "Part C of the versioning plan (docs/plans/versioning.md, epic #125): ..."`

## Input validation
- If no title is provided, ask the user for one before proceeding.
- If `--skill feature-implement` is provided, require `--spec` naming an approved file under
  `docs/features/`; stop and request that path if it is absent or outside that directory. If
  `--spec` names a file under `docs/features/`, reject an explicit `--skill` other than
  `feature-implement`: `task-run` passes the spec path instead of the description, so those
  inputs must stay paired.
- If `--surface` is provided, accept only `daemon`, `forge-adapter`, `tui`, or `swift`. Reject
  anything else — a crate name such as `foreman-tui`, a plural, a different case — and ask the
  user for one of the supported values rather than mapping a near miss onto one.
- If `--spec` names a file under `docs/features/<surface>/`, that path already fixes the
  surface: take it from the path, and reject an explicit `--surface` that disagrees rather than
  silently preferring one, the same way `--skill feature-implement` and `--spec` must stay
  paired. The value read off the path is held to the same three: a spec filed under a folder
  that is not a row of the surface table stops the run and reports the folder, rather than
  inventing a fourth label the repository has never created. A `--spec` elsewhere under `docs/`
  (a plan under `docs/plans/`) fixes nothing, and `--surface` stays optional beside it.
- If neither `--surface` nor a surface-bearing feature-spec path was provided, inspect the
  title and description for a strong, case-insensitive surface cue. Infer `swift` from an
  explicit Swift/iOS/SwiftUI reference; infer `tui` from an
  explicit `TUI`/`foreman-tui` reference or a named screen such as `Backlog`, `Factory`,
  `PRs`, `Diff`, or `Workers tab` in a TUI context; infer `daemon` from an explicit daemon,
  worker-daemon, or worker-pipeline reference; infer `forge-adapter` from an explicit
  forge-adapter, Forge trait, or forge adapter reference. Do not infer from a generic word
  such as "task", "worker", "board", or "API" alone. An explicit `--surface` or
  surface-bearing spec path always wins; if the title and description contain cues for
  different surfaces without either of those authoritative inputs, infer none and omit the
  label. Record whether the resolved surface came from `--surface`, the spec path, or this
  inference in the Step 4 summary.
- If `--blocked-by` is provided, accept only a positive integer issue number per occurrence;
  reject a non-numeric value, zero, or a negative number, and ask the user for the blocking
  issue's number. A leading `#` is accepted and stripped, and a number given twice counts once.
  Resolving each number against the repository happens in Step 2b, before anything is created.
- If `--parent` is provided, accept exactly one positive integer issue number under the same
  rules (a leading `#` stripped; a second `--parent` is an error, not a second epic). A number
  that also appears in `--blocked-by` is rejected: an epic regroups tasks and is never a
  prerequisite of one. Resolving it happens in Step 2c, before anything is created.

## Process

### Step 0. Check for an existing task

Before asking anything, search the tasks for a near match, so a duplicate is caught while the
user has spent nothing on prompts. This runs first, straight after input validation, together
with the Step 2b blocker resolution and the Step 2c epic resolution; only then does Step 1 ask
its first question.

```bash
if [[ "$FORGE_CLI" == "gh" ]]; then
  gh issue list --label task --state all --search "<key words> in:title" --limit 5 --json number,title,state,url
else
  tea issues list --labels task --state all --keyword "<key words>" --limit 5 --output json
fi
```

`tea --keyword` matches bodies as well as titles, so expect a little more noise there; the
exact-title rule compares titles either way. Its JSON names the issue number `index`.

Pick two to four distinctive words from the title — the feature or screen name and the verb —
and drop prefixes and filler. Run the search once; do not iterate on the words or read the
matches' bodies.

- **An open issue whose title equals the requested title, case-insensitively, is a
  duplicate.** Stop, show it, and do not create a second one — in every mode. A
  **closed** issue with the same title is a near match, not a stop: redoing finished work is a
  legitimate task, and the match is shown so the user knows.
- **Otherwise, when there are near matches**, list them (number, title, state) and ask the user
  whether to continue or to work the existing issue with `/task-run <number>` instead. When the
  caller supplied `--description` — a scripted caller's path — do not ask; carry the near matches into
  the Step 4 summary instead.
- No matches: continue silently.

### Step 1. Choose the skill
**If `--skill` was provided**, use that value directly (`none` means no skill) and skip the interactive prompt. Verify that any named skill exists as a directory under `.agents/skills/` — stop and report if it does not.

Otherwise, default to **`feature-implement`** when `--spec` names a file under `docs/features/` (that is the skill that builds an approved feature spec), and to **`code-update`** in every other case — it is this repository's general editing skill and the daemon's only `always` auto-eligible skill — and confirm with the user, offering:
- `code-update` (recommended without a feature spec) — any code, config, or docs change, run through plan → implement → CI gates → review
- `feature-implement` (recommended with a `docs/features/` spec) — builds or revises the feature an `approved` spec describes; `requires-headless-flag` under this repository's `auto-skills`, so here it runs headless only with `--headless` (on a repo that lists it `interactive` instead, the flag is inert and the turn opens an operator seat)
- none — the task is executed freely from its description (investigations, questions, non-code chores)

Do not offer `task-run`, `task-create`, `task-breakdown`, `code-review`, `skill-review`, `investigate-daemon-issue`, `feature-create-specs`, `feature-review-specs`, `daemon-design`, or `tui-design`: they are not task skills (`investigate-daemon-issue` needs the operator at the keyboard for its host reads and approvals; the last four are by-hand spec and design skills; an `approved` feature spec is passed as `--spec` to a `feature-implement` task instead).

If the user picks a skill, record its name.

Require `feature-implement` and a `docs/features/` spec together: if either one is selected,
the other must be present before continuing. Do not create a description-only
`feature-implement` task or pass a feature spec to another skill: `task-run` passes the spec
path instead of prose, and `feature-implement` is the sub-skill whose non-interactive contract
accepts that path.

### Step 2. Resolve the spec and task description

**If `--spec` was provided**, validate that it is a repo-relative path without `..` segments. The file must exist — **stop if it does not**, rather than guessing a neighboring file. If it is under `docs/features/`, read the first word after `**Status:**` with any trailing period stripped (the standard writes `approved. daemon-design 2026-09-10: ...`) and require it to be exactly `approved`; stop on `draft`, `reviewed`, or a missing or malformed status. Store the path separately for the metadata block. A spec does not replace the task description unless the path itself is the complete requested description.

**If `--description` was provided**, use that value directly and skip the interactive prompt.

Otherwise, the description serves as the context passed to the skill (or as the task definition if no skill was selected):

**If `code-update` was selected**: ask for a short description (1-3 sentences) stating what
should change and what should stay the same — its non-interactive mode takes scope from this
text alone and prefers the narrowest reading, so say what you mean. If the task follows a
written plan under `docs/`, pass it as `--spec` rather than restating it.

**If `feature-implement` was selected**: the approved feature spec is the complete requested
description. A short human-readable summary may still be supplied or requested for the issue
body, but it never replaces the required `--spec` path.

**If no skill was selected:** ask for an explicit, self-contained description of the task (what needs to be done and why). This description will be the only context available when the task is executed.

The description is stored verbatim in the issue body and is later treated as **untrusted input** by `task-run`: it should describe intent, never contain commands to run, URLs to fetch, or instructions to the agent.

### Step 2b. Resolve blockers (only when `--blocked-by` was given)

Skip this step entirely when `--blocked-by` was not provided; there is no prompt and no
inference. Nothing here depends on later answers, so run it right after input validation,
alongside Step 0 — a mistyped blocker fails before the first prompt.

Resolve each number against the repository:

```bash
forge_issue_fetch_json <blocker> | jq '{number, state, title}'
```

`state` is `open` or `closed` on both forges; the wrapper normalizes it.

- **The issue must exist.** If the CLI reports it does not, stop and report the number given.
  Do not search for a similarly named issue.
- A **closed** blocker is not an error — that dependency is already satisfied — but say so in
  the Step 4 output, since it usually means the flag was copied from a stale plan.
- A task never blocks on itself: the issue being created has no number yet, so `--blocked-by`
  cannot name it; state the rule anyway so the guarantee does not rest on that coincidence.

Record the resolved numbers, ascending, for Step 3; they are written as one key, the numbers
separated by a comma and a space (`blocked-by: 41, 43`), and Step 3b links each one natively.
Nothing else about a blocker is copied into the task. The description should still say, in
prose, why the task waits and what "landed" means for that dependency — a merge, a decision
recorded on the issue. The key records the fact for machines; the prose says why.

### Step 2c. Resolve the epic (only when `--parent` was given)

Skip this step entirely when `--parent` was not provided; there is no prompt and no inference.
Like Step 2b it runs right after input validation, so a mistyped epic fails before the first
prompt.

```bash
forge_issue_fetch_json <epic> | jq '{number, state, title, labels}'
```

- **The issue must exist and carry the `epic` label.** If the CLI reports it does not exist,
  or `labels` lacks `epic`, stop and report the number given. Do not search for an epic with a
  similar title, and never parent a task to a plain issue: an epic is unclaimable *because* it
  carries only that label, and a task parented to a `task`-labelled issue would say otherwise
  to every reader of the graph.
- A **closed** epic is not an error — a late task can join a finished initiative — but say so
  in the Step 4 output.

Record the number for Step 3; it is written as `epic: <number>` and Step 3b links it natively.

### Step 3. Create the issue
**Ensure every label the create command names exists first** — a create that names a label the
repository does not have fails and files nothing, so both ensures run before the issue does.
The `task` label: `forge_issue_ensure_label task "0052cc" "Work-ticket for /task-run and the foreman daemon"` (the colour is an arbitrary default for a fresh repository; `--force` semantics mean an existing label is left as configured).

**When a surface was resolved explicitly, from a spec path, or by the strong-cue inference
above**, ensure all four supported routing labels the same way — all four, not just the one
applied: the taxonomy is only useful once every value exists, and creating them together keeps
the colours consistent on a fresh repository.

```bash
forge_issue_ensure_label "surface: daemon"        "546e7a" "Touches crates/foreman"
forge_issue_ensure_label "surface: forge-adapter" "78909c" "Touches crates/forge-adapter"
forge_issue_ensure_label "surface: tui"           "90a4ae" "Touches crates/foreman-tui"
forge_issue_ensure_label "surface: swift"         "7e57c2" "Swift/iOS toolchain work"
```

The first three values are exactly `docs/architecture/README.md`'s feature surfaces. `swift` is
a routing label for Swift/iOS toolchain work that can cross those ownership areas. All four
labels route tasks to workers by matching `workers.<name>.tags`; they are also shown on the board.
If none of the configured workers has a matching tag, the ready task falls back to the
`linux`/`cloud` default pool and the coordinator warns; add new host-specific values to a
worker's tags before relying on them for routing. No `platform:` issue label or task-metadata
key is used for routing.

During the surface-routing rollout, do not arm a new task that relies on host-specific
`surface:` routing (such as `surface: swift`) until every worker runs the new daemon. Older
workers ignore that label and treat the task as default-pool work, which can send it to the
wrong machine. Surfaces whose work already belongs on the default pool do not need to wait;
see [`docs/fleet.md`](../../../docs/fleet.md) for the dual-label transition for existing
host-bound tasks.

**Then create the issue** on the current repository with the `task` label, plus the `surface: <value>` label when a surface was resolved. Write the issue body to a temporary file and use a body-file argument (avoid process substitution to prevent shell permission prompts):

```bash
# gh — repeat --label once per label
gh issue create --title "<title>" --label task --label "surface: <value>" --body-file /tmp/task_body.md
# tea — one comma-separated --labels value
tea issues create --title "<title>" --labels "task,surface: <value>" --description "$(cat /tmp/task_body.md)"
```

Drop the `surface:` label from the command entirely when none was resolved; an empty or
placeholder label value is not the same thing as no label.

**Issue body structure:**

Always include the `## Description` section. Always end with the `<!-- task-metadata -->` block.

**Example — skill, no spec (the common case):**
```markdown
## Description

Reset the sweep's requeue budget when the release reason is `retry`, so an
explicit `/foreman retry` after two automatic sweeps does not land in
needs-human on the next stall.

<!-- task-metadata
skill: code-update
-->
```

**Example — skill with a spec:**
```markdown
## Description

`docs/plans/sweep-budget.md`

<!-- task-metadata
skill: code-update
spec: docs/plans/sweep-budget.md
-->
```

**Example — no skill, no spec:**
```markdown
## Description

Investigate why the Linux worker's journal shows two claim markers for #41
and write up the timeline in the issue.

<!-- task-metadata
-->
```

**Example — task blocked by an earlier task:**
```markdown
## Description

Surface the sweep's requeue budget on the dashboard, per task. Depends on #57 (the
budget reset on explicit retry) landing first.

<!-- task-metadata
skill: code-update
blocked-by: 57
-->
```

**Example — task filed under an epic by `task-breakdown`:**
```markdown
## Description

Part C of the versioning plan (`docs/plans/versioning.md`, epic #125): emit the
`version:` key on the claim marker. Depends on #121 (the tolerant parser) being
deployed on every worker. Arm only after #121 is deployed on every worker.

<!-- task-metadata
skill: code-update
epic: 125
blocked-by: 121
-->
```

**Rules for the `<!-- task-metadata -->` block:**
- This HTML comment is **machine-readable metadata** used by `/task-run` and parsed by the daemon (`crates/foreman/src/metadata.rs`). It is invisible when rendered on the forge.
- Always include the block at the very end of the body, even if all fields are empty.
- One `key: value` per line; omit a field entirely if it has no value (do not write empty values). Unknown keys are ignored by the parser.
- `blocked-by` holds the issue numbers this task cannot start before, written by `--blocked-by`
  as `blocked-by: 41, 43`. It is informational: `/task-run` reads it to warn when a blocker is
  still open — and, headless, to abort to needs-human rather than start — and nothing derives an
  order or a schedule from it. Its absence means no blocker was recorded, not that the description's prose was checked.
  The daemon's parser (`metadata.rs`) does not read it today; headless `task-run` is what
  enforces it, so a claimed task with an open blocker costs one worker turn before it lands in
  needs-human. Reading the key before claiming is a daemon improvement, not a task-create one.
- `epic` holds the number of the epic this task belongs to, written by `--parent` as
  `epic: 125`. It is informational and **not a dispatcher instruction key**: the daemon never
  routes, qualifies, or schedules from it, and `metadata.rs` ignores it as an unknown key
  today. The board groups a task under its epic from the forge's native link — GitHub's
  sub-issue `parent` (`WorkTicket::parent`), which Step 3b derives from this key; Gitea has no
  per-task field yet (foreman#230), so there the key is the only task-side record. Its absence
  means the task belongs to no epic.
- **The keys are the record; the native links are display state derived from them.** Step 3b
  creates the links after the issue exists, and a link that could not be made never removes
  its key — a task whose metadata names its epic and blockers is correct with or without the
  links, which can be re-derived from the keys at any time. The reverse is not true.

**Optional daemon keys:**

The daemon reads additional optional keys from the same block. Every one of them has a `foreman.yml` default, so write a key only when this specific task should override the default. They are instructions to the daemon, not to `/task-run` — the skill itself ignores them in every mode, except that its headless-eligibility check reads `headless` from this table. Do not prompt for these keys; write them when the user explicitly provides them.

| Key | Values | Meaning |
|---|---|---|
| `agent` | `claude` \| `codex` \| `cursor` \| `opencode` \| `copilot` | Which agent CLI implements the task (default: `phase-models.implementation.agent`) |
| `model` | e.g. `fable`, `sonnet`, or `anthropic/claude-sonnet-4` for OpenCode | Model passed to the agent CLI (default: the vendor-matched entry in `phase-models.implementation.model`, or its scalar fleet fallback; a missing map entry escalates) |
| `reviewer` | `claude` \| `codex` \| `cursor` \| `opencode` \| `copilot` | Overrides the configured `reviewers` strategy for this task |
| `max-rounds` | integer | Overrides the review-loop round cap (`max-rounds`, default 5) |
| `headless` | exactly `yes` | Asserts this task's skill pass asks no questions, satisfying `requires-headless-flag` entries in `auto-skills`. Only the literal value `yes` counts — `true`, `1`, and other spellings do not. Written by the `--headless` input flag |

`agent` and `model` resolve as a pair at claim time. If a task changes the
agent from the repository default, it must set `model` explicitly as well;
otherwise the daemon escalates the task to `status: needs-human` instead of
stamping the previous vendor's model into the claim. For example, use
`agent: codex` together with `model: gpt-5.2`, or `agent: opencode` together
with `model: anthropic/claude-sonnet-4`, not either agent alone.

**When to set `headless: yes`:** only when the pass is known to ask no questions — a well-scoped mechanical change, or a pass whose spec already answers everything the skill would otherwise ask. Tasks that intentionally involve judgment calls must never get the flag. The flag unlocks exactly one thing: a skill the target repo's `auto-skills` lists as `requires-headless-flag`. It changes nothing for an `always` entry, and nothing at all for an `interactive` one — that mode opens an operator seat with or without it, and no metadata key can make it headless or open a seat that the policy did not. In this repository `code-update` is `always` and `feature-implement` is `requires-headless-flag`, so a `feature-implement` task here is claimable only with the flag — set it only when its spec leaves that skill nothing to ask (every *Other surfaces* item landed, no protected change, no open *Decisions*; see `feature-implement`'s *Eligibility*), and never for a protected change. Check the target repo's own `auto-skills` rather than assuming this one's. The flag does not bypass any security gate — a headless run that still hits a question or a suspicious-content flag aborts to `status: needs-human`.

**Arming for the daemon** is a separate, human step: a ready-applier adds `status: ready` on the forge. This skill never applies `status: ready` and never posts `foreman-*` marker comments.

**Capture the created issue's number** from the command's output — `gh issue create` prints
the issue URL, `tea issues create` a summary line with `#<index>` — Step 3b and Step 4 need it.
If the number cannot be read from `tea`'s line, take it from
`tea issues list --state open --labels task --limit 5 --output json` by exact title (its
`index` field); two exact matches is a stop, not a guess, since Step 0 already ruled out an
open twin before this create.

### Step 3b. Link the relationships natively (only when Step 2b or 2c resolved one)

Skip this step entirely when neither `--blocked-by` nor `--parent` was given: a task with no
relationships makes no relationship call, not even the capability read.

The links are **second writes, made after the issue exists, on both forges** — never part of
the create command. On GitHub the create call could carry `--parent` and `--blocked-by`, but a
failed flagged create leaves the question of whether the issue was created, which is the one
question this skill must never have to guess at; a separate write can fail without costing or
duplicating the issue. On Gitea there is no other way: `tea` cannot link at all, and both
relationships are emulated through the dependency endpoint. `scripts/lib/forge-cli.sh` holds
one helper per operation, with the per-forge calls and the Gitea direction rule in its own
comment block; the skill runs them in this order:

1. **Capability read, once.** `forge_issue_relationships_supported` — on GitHub, the installed
   `gh` has the relationship flags (they shipped in 2.94.0; 2.100.0 is what this was verified
   on); on Gitea, the repository has issue dependencies enabled. When it fails, make no link
   call: keep every key and report every link as **unavailable** in Step 4 — tooling absence,
   not a failed call.
2. **One call per relationship.** `forge_issue_set_parent <task> <epic>` for the epic, and
   `forge_issue_add_blocker <task> <blocker>` once per blocker, in ascending order. A call
   that fails is recorded as **missing** for that link and is not retried: the issue and its
   keys exist, one attempt is enough, and the link can be re-derived from the key later. The
   links are independent — a failed blocker call does not skip the epic, or the next blocker.
3. **Read-back.** `forge_issue_relationships <task>` prints what the forge actually holds,
   `{"parent": <n or null>, "blocked_by": [...]}` on both forges. Step 4 reports *that*, not
   what an exit status implied — on Gitea the read comes from the dependency listings, and
   on GitHub a relationship write can be accepted and still not land. When the read-back
   itself fails, report every link attempted in point 2 as **missing**, the conservative
   reading: a wrongly reported "created" is not re-derivable and a missing link is.

Unavailable and missing are different states, and Step 4 names which. Neither ever drops a
key. On Gitea the emulated link adds one behaviour beyond display, and it is accepted: an issue
cannot close while one it depends on is open (HTTP 412), so an epic stays open until its tasks
close, and a blocked task until its blockers do — a stronger form of the state the
`blocked-by:` key exists to warn about.

### Step 4. Output
After the issue is created, display ALL of the following in a summary block:
- **Title** — the task title
- **Description** — the FULL task description as written in the issue body (do NOT omit this)
- **Skill** — the associated skill name (if any)
- **Spec file** — the associated spec file path (if any)
- **Surface** — the `surface:` label applied, and whether it came from `--surface`, the
  `--spec` path, or strong title/description cues. Omit the line entirely when no surface was
  resolved
- **Epic** — the epic's number and title when `--parent` was used, and whether the native link
  was created per Step 3b's read-back: **created**, **missing** (a call failed or the read-back
  could not verify it), or **unavailable** (the capability read failed). Say plainly when the
  epic is closed. Omit the line entirely when `--parent` was not used
- **Blocked by** — every resolved blocker's number, title, and state, and its native link's
  verdict per blocker — **created**, **missing**, or **unavailable**, as Step 3b defines them;
  say plainly when one is already closed. Omit the line entirely when `--blocked-by` was not
  used
- **Near matches** — the issues Step 0 surfaced, if any
- **Daemon keys** — any daemon metadata keys written (e.g. `headless: yes`), if any
- **Issue URL** — the issue URL, as a plain URL (no markdown formatting around it)
- **Hint** — "Run `/task-run <number>` to work on it now, or add `status: ready` to arm it for the daemon."

IMPORTANT: Always include the description. The user must be able to review exactly what was written without opening the issue.

## Reference documents
- `.agents/skills/task-run/SKILL.md` — how the body and metadata written here are parsed and verified.
- `.agents/skills/task-breakdown/SKILL.md` — the caller that files an epic and passes
  `--parent` and `--blocked-by` for every task of an approved plan.
- `scripts/lib/forge-cli.sh` — `forge_issue_fetch_json`, `forge_issue_ensure_label`, and the
  relationship helpers Step 3b runs (`forge_issue_relationships_supported`,
  `forge_issue_set_parent`, `forge_issue_add_blocker`, `forge_issue_relationships`), with the
  per-forge mechanism recorded in their comment block.
- `crates/foreman/src/metadata.rs` — the daemon's parser for the metadata block.
- `crates/forge-adapter/src/lib.rs` — `WorkTicket::parent`, the native link the board reads
  on GitHub; `gitea.rs`'s module doc records why it is `None` on Gitea (foreman#230).
- `foreman.yml` — the per-repository defaults the optional keys override.
- `docs/architecture/README.md` — the surface table `--surface` draws its three values from.
