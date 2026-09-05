# CLAUDE.md

## What this is

`foreman-scratch` is a **disposable rehearsal repository** for the foreman
work-ticket dispatcher (`ghyc26/foreman` on GitHub). It exists so the daemon's
Gitea path — claim, implement turn, PR on `task/<n>-…`, review loop,
`status: merge-ready` — can be watched end to end without touching a real
repository (`docs/migrate-to-gitea.md` §6 in the foreman repo). Issues, PRs,
and branches here can be deleted at any time.

There is no code and no build: tasks here are **docs-only** (a README line, a
note under `docs/`), so `code-update` takes its docs-only path and skips the
cargo gates.

## Skills

`.agents/skills/` is a verbatim copy of foreman's skills (`task-run`,
`code-update`, `code-review`, `task-create`, `skill-review`) together with
`scripts/lib/forge-cli.sh`, `docs/standards/coding-standards.md`, and a copy
of the fleet policy `foreman.yml` (which `task-run`'s headless mode reads for
`auto-skills`, `ready-appliers`, and `marker-authors`). `.claude/skills` is a
symlink to `.agents/skills`. Refresh the copy from foreman when those files
change; do not edit them here.

Humans arm tasks as `ycastonguay`; the daemons act as the bot `foreman`.
