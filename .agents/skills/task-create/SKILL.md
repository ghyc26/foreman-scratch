---
name: task-create
description: Creates a forge issue (GitHub or Gitea) as a task with a title, description, optional skill reference, optional spec file, and optional daemon metadata. Invoked with /task-create.
---

# Create Task

## When to use this skill
Use this skill when the user wants to create a new task (forge issue) for the current repository. Typical triggers: `/task-create <title>`, "create a task for ...", "open a task to ...".

`task-run` executes a task after creation — interactively, or headlessly when the foreman daemon claims it after a ready-applier adds `status: ready`.

## Forge CLI
Source `scripts/lib/forge-cli.sh` and call `forge_detect_cli` at the start; it sets `FORGE_CLI` to `gh` or `tea` from the `origin` remote (override with `FOREMAN_FORGE_CLI=tea|gh`).

```bash
source scripts/lib/forge-cli.sh
forge_detect_cli
```

## Input
- **Title** (required): provided as the argument to `/task-create`.
- **Skill** (optional): can be pre-specified with `--skill <name>`. Defaults to `code-update` (see Step 1).
- **Spec** (optional): can be pre-specified with `--spec <repo-relative-path>`.
- **Description** (optional): can be pre-specified with `--description "..."`.
- **Headless flag** (optional): `--headless` writes `headless: yes` into the metadata block, marking the task safe for unattended dispatch. Set it only under the conditions in Step 3's **When to set `headless: yes`** — never prompt for it.
- **Blockers** (optional): `--blocked-by <number>`, repeatable, names an existing issue this task
  cannot start before. The resolved numbers are written into the metadata block as one
  `blocked-by:` key — the machine-readable record of the dependency the description's prose
  states, which `/task-run` checks before starting. A headless run aborts to
  needs-human while a blocker is open.
- Example usages:
  - `/task-create Reset the sweep requeue budget on an explicit retry`
  - `/task-create "Log the poll backoff delay at info" --description "worker.rs logs the computed next_poll_delay only at debug; promote the backoff case to info so the journal shows rate-limit recovery."`
  - `/task-create "Document the Gitea timeline check" --skill none --description "Verify the tea api timeline filter in task-run against a real Gitea instance and correct the SKILL.md."`
  - `/task-create "Surface the requeue budget on the dashboard" --blocked-by 57 --description "Depends on #57 (the budget reset) landing first; read the budget from the claim record and show it per task."`

## Input validation
- If no title is provided, ask the user for one before proceeding.
- If `--blocked-by` is provided, accept only a positive integer issue number per occurrence;
  reject a non-numeric value, zero, or a negative number, and ask the user for the blocking
  issue's number. A leading `#` is accepted and stripped, and a number given twice counts once.
  Resolving each number against the repository happens in Step 2b, before anything is created.

## Process

### Step 0. Check for an existing task

Before asking anything, search the tasks for a near match, so a duplicate is caught while the
user has spent nothing on prompts. This runs first, straight after input validation, together
with the Step 2b blocker resolution; only then does Step 1 ask its first question.

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

Otherwise, default to **`code-update`** — it is this repository's one editing skill and the daemon's only `always` auto-eligible skill — and confirm with the user, offering:
- `code-update` (recommended) — any code, config, or docs change, run through plan → implement → CI gates → review
- none — the task is executed freely from its description (investigations, questions, non-code chores)

Do not offer `task-run`, `task-create`, `code-review`, or `skill-review`: they are not task skills.

If the user picks a skill, record its name.

### Step 2. Resolve the spec and task description

**If `--spec` was provided**, validate that it is a repo-relative path without `..` segments. The file must exist — **stop if it does not**, rather than guessing a neighboring file. Store the path separately for the metadata block. A spec does not replace the task description unless the path itself is the complete requested description.

**If `--description` was provided**, use that value directly and skip the interactive prompt.

Otherwise, the description serves as the context passed to the skill (or as the task definition if no skill was selected):

**If a skill was selected**: ask for a short description (1-3 sentences) stating what should change and what should stay the same — `code-update`'s non-interactive mode takes scope from this text alone and prefers the narrowest reading, so say what you mean. If the task follows a written plan under `docs/`, pass it as `--spec` rather than restating it.

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
separated by a comma and a space (`blocked-by: 41, 43`). Nothing else about a blocker is copied
into the task. The description should still say, in prose, why the task waits and what
"landed" means for that dependency — a merge, a decision recorded on the issue. The key records
the fact for machines; the prose says why.

### Step 3. Create the issue
Create the issue on the current repository with the `task` label. Write the issue body to a temporary file and use a body-file argument (avoid process substitution to prevent shell permission prompts):

```bash
# gh
gh issue create --title "<title>" --label task --body-file /tmp/task_body.md
# tea
tea issues create --title "<title>" --labels task --description "$(cat /tmp/task_body.md)"
```

Ensure the `task` label exists first: `forge_issue_ensure_label task "0052cc" "Work-ticket for /task-run and the foreman daemon"` (the colour is an arbitrary default for a fresh repository; `--force` semantics mean an existing label is left as configured).

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

**Optional daemon keys:**

The daemon reads additional optional keys from the same block. Every one of them has a `foreman.yml` default, so write a key only when this specific task should override the default. They are instructions to the daemon, not to `/task-run` — interactive `/task-run` ignores them, and its headless mode reads only `headless` from this table. Do not prompt for these keys; write them when the user explicitly provides them.

| Key | Values | Meaning |
|---|---|---|
| `agent` | `claude` \| `codex` \| `cursor` | Which agent CLI implements the task (default: `phase-models.implementation.agent`) |
| `model` | e.g. `fable`, `sonnet` | Model passed to the agent CLI (default: `phase-models.implementation.model`) |
| `platform` | `linux` \| `macos` \| `cloud` \| `any` | Machine qualification, matched case-insensitively against workers' `tags` (`worker.rs`); absent means `any`. A `platform: <value>` issue label is the equivalent human-set routing input and takes precedence over this key |
| `reviewer` | `claude` \| `codex` \| `cursor` | Overrides the configured `reviewers` strategy for this task |
| `max-rounds` | integer | Overrides the review-loop round cap (`max-rounds`, default 5) |
| `headless` | exactly `yes` | Asserts this task's skill pass asks no questions, satisfying `requires-headless-flag` entries in `auto-skills`. Only the literal value `yes` counts — `true`, `1`, and other spellings do not. Written by the `--headless` input flag |

**When to set `headless: yes`:** only when the pass is known to ask no questions — a well-scoped mechanical change, or a pass whose spec already answers everything the skill would otherwise ask. Tasks that intentionally involve judgment calls must never get the flag. In this repository `code-update` is an `always` entry, so the flag changes nothing for it; it exists for a future `requires-headless-flag` skill. The flag does not bypass any security gate — a headless run that still hits a question or a suspicious-content flag aborts to `status: needs-human`.

**Arming for the daemon** is a separate, human step: a ready-applier adds `status: ready` on the forge. This skill never applies `status: ready` and never posts `foreman-*` marker comments.

### Step 4. Output
After the issue is created, display ALL of the following in a summary block:
- **Title** — the task title
- **Description** — the FULL task description as written in the issue body (do NOT omit this)
- **Skill** — the associated skill name (if any)
- **Spec file** — the associated spec file path (if any)
- **Blocked by** — every resolved blocker's number, title, and state; say plainly when one is
  already closed. Omit the line entirely when `--blocked-by` was not used
- **Near matches** — the issues Step 0 surfaced, if any
- **Daemon keys** — any daemon metadata keys written (e.g. `headless: yes`), if any
- **Issue URL** — the issue URL, as a plain URL (no markdown formatting around it)
- **Hint** — "Run `/task-run <number>` to work on it now, or add `status: ready` to arm it for the daemon."

IMPORTANT: Always include the description. The user must be able to review exactly what was written without opening the issue.

## Reference documents
- `.agents/skills/task-run/SKILL.md` — how the body and metadata written here are parsed and verified.
- `crates/foreman/src/metadata.rs` — the daemon's parser for the metadata block.
- `foreman.yml` — the per-repository defaults the optional keys override.
