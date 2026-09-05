# Agent Skills

A collection of reusable skills for AI coding agents such as Claude Code. Each skill is a structured prompt (a `SKILL.md` file) that teaches an agent how to perform a specific task through a defined process, with interactive user collaboration.

## Skills

### ✏️ Making Changes

| Skill | Command | Description |
|---|---|---|
| [code-update](#code-update) | `/code-update` | Make any code, config, or docs change: plan, implement, verify, review, commit |

### 🔍 Code Quality

| Skill | Command | Description |
|---|---|---|
| [code-review](#code-review) | `/code-review` | Review staged files, the current branch, or a PR (GitHub or Gitea) against coding standards |

### 🎫 Tasks

| Skill | Command | Description |
|---|---|---|
| [task-create](#task-create) | `/task-create` | Create a forge issue (GitHub or Gitea) as a structured task |
| [task-run](#task-run) | `/task-run` | Execute a task issue by invoking its skill; headless mode for the daemon |

### 🛠️ Tooling

| Skill | Command | Description |
|---|---|---|
| [skill-review](#skill-review) | `/skill-review` | Review and improve a custom AI agent skill |

---

## Skill Details

### ✏️ Making Changes

#### code-update

The one editing path in this repository — there is no separate feature skill. Clarifies scope, stops for explicit confirmation on protected changes (marker formats, the claim protocol, the `foreman.yml` schema, exit-condition tests), produces an approved plan, implements against `docs/standards/coding-standards.md`, runs the CI gates, invokes `code-review`, commits on a branch, then pushes and opens a PR (via `forge-cli.sh`) without asking — once review Blockers and Warnings are fixed or dispositioned, the PR is the deliverable. Has a non-interactive mode for `task-run`.

```
/code-update fix the sweep so a retry release resets the requeue budget
```

### 🔍 Code Quality

#### code-review

Reviews local staged files, the current branch against the default branch, or a specific PR (GitHub or Gitea) against `docs/standards/coding-standards.md` and the invariants in `CLAUDE.md`. Reads full files when changes touch trait boundaries or the claim/pipeline/review/sweep path, runs the CI trio (`cargo fmt --check`, `cargo clippy -D warnings`, `cargo test --workspace`), and classifies findings by severity (Blocker / Warning / Suggestion) with a PASS/FAIL verdict.

```
/code-review
/code-review 42
```

Forge detection for the PR form comes from `scripts/lib/forge-cli.sh` (`gh` for GitHub origins, `tea` otherwise; override with `FOREMAN_FORGE_CLI=gh|tea`). Its offline tests run with `bash scripts/lib/forge-cli.test.sh`.

### 🎫 Tasks

#### task-create

Creates an issue labeled `task` with a `## Description` and the `<!-- task-metadata -->` block the daemon parses (`skill`, `spec`, the optional `blocked-by` list of prerequisite issues, and the optional `agent` / `model` / `platform` / `reviewer` / `max-rounds` / `headless` overrides). Defaults the skill to `code-update`. Never applies `status: ready` — arming is a human step.

```
/task-create Reset the sweep requeue budget on an explicit retry
/task-create "Log the poll backoff at info" --description "..." --skill code-update
```

#### task-run

Fetches a task issue, runs the security gates (authorship, `task` label, skill allowlist, spec path, suspicious content), creates the `task/<n>-<slug>` branch, invokes the task's skill, commits, opens the PR, and moves the `status:` label. `--headless` is the contract the foreman daemon invokes (`vendors.rs`): every human prompt maps to a deterministic rule or an abort to `status: needs-human`, with eligibility and ready-appliers read from `foreman.yml`.

```
/task-run 36
/task-run 36 --headless
```

### 🛠️ Tooling

#### skill-review

Interactively reviews a `SKILL.md` from the perspective of an agent that has to follow it: checks it against `CLAUDE.md`, the coding standards, and the other skills for clarity, completeness, dangling references, and leftover conventions from other repositories, then applies approved fixes in batches of up to four questions.

```
/skill-review code-review
```

## Layout

`.agents/skills/` is the single source of truth for skills; agent-specific directories link to it rather than holding copies:

```text
.agents/skills/<name>/SKILL.md   # the skill
.claude/skills -> ../.agents/skills   # committed symlink for Claude Code
```

Add a new skill as a directory here with a `SKILL.md`, then list it in the tables above. Do not create skills under `.claude/skills` directly.

## Usage

Claude Code discovers every `SKILL.md` under `.claude/skills` (the symlink above) automatically; invoke one in a conversation with the `/` command (e.g. `/code-review`).
