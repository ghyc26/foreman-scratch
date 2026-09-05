#!/usr/bin/env bash
# Offline unit tests for the pure/local logic in forge-cli.sh: CLI detection,
# origin-URL parsing, HTTP-status-line parsing, the timeline and comment
# normalizers (against recorded Gitea 1.27.2 / GitHub responses), and the
# zsh `local path` regression. No network access and no real `gh`/`tea`
# calls (the zsh test uses a stub `tea` on a temp PATH) - this is what
# should have caught the hostname/checksum/pagination bugs found in review,
# before they needed a live Gitea session.
#
# Run: bash scripts/lib/forge-cli.test.sh

set -uo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=forge-cli.sh
source "$script_dir/forge-cli.sh"

pass_count=0
fail_count=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "ok   - $desc"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL - $desc: expected [$expected], got [$actual]"
    fail_count=$((fail_count + 1))
  fi
}

assert_status() {
  local desc="$1" expect_ok="$2" line="$3"
  if _forge_http_status_ok "$line"; then
    actual_ok=1
  else
    actual_ok=0
  fi
  assert_eq "$desc" "$expect_ok" "$actual_ok"
}

# --- _forge_http_status_ok -------------------------------------------------

assert_status "200 OK is success" 1 "HTTP/2.0 200 OK"
assert_status "201 Created is success" 1 "HTTP/1.1 201 Created"
assert_status "204 No Content is success" 1 "HTTP/2 204 No Content"
assert_status "404 Not Found is failure" 0 "HTTP/2.0 404 Not Found"
assert_status "401 Unauthorized is failure" 0 "HTTP/1.1 401 Unauthorized"
assert_status "500 Internal Server Error is failure" 0 "HTTP/2.0 500 Internal Server Error"
assert_status "empty status line is failure" 0 ""
assert_status "malformed status line is failure" 0 "not a status line"

# --- forge_detect_cli / forge_owner_repo -----------------------------------
# Exercised against real scratch git repos (temp dirs with a fake `origin`),
# not the actual project repo, so these run anywhere with no side effects.

tmp_root="$(mktemp -d)"
cleanup() { rm -rf "$tmp_root"; }
trap cleanup EXIT

make_scratch_repo() {
  local dir="$1" origin_url="$2"
  mkdir -p "$dir"
  (cd "$dir" && git init -q && git remote add origin "$origin_url")
}

github_repo="$tmp_root/github-origin"
gitea_repo="$tmp_root/gitea-origin"
ssh_repo="$tmp_root/ssh-origin"
start_dir="$PWD"

make_scratch_repo "$github_repo" "https://github.com/example-org/example-repo.git"
make_scratch_repo "$gitea_repo" "https://gitea.ycastonguay.com/ycastonguay/rce2.git"
make_scratch_repo "$ssh_repo" "git@gitea.ycastonguay.com:ycastonguay/rce2.git"

# NOTE: deliberately NOT run in ( ) subshells - assert_eq's pass_count/
# fail_count increments would otherwise be scoped to the subshell and vanish,
# silently dropping assertions from the final tally. `cd` back to start_dir
# after each block instead.

cd "$github_repo"
unset FOREMAN_FORGE_CLI
forge_detect_cli
assert_eq "github.com origin selects gh" "gh" "$FORGE_CLI"
cd "$start_dir"

cd "$gitea_repo"
unset FOREMAN_FORGE_CLI
forge_detect_cli
assert_eq "non-github origin selects tea" "tea" "$FORGE_CLI"
cd "$start_dir"

cd "$gitea_repo"
FOREMAN_FORGE_CLI="gh"
forge_detect_cli
unset FOREMAN_FORGE_CLI
assert_eq "FOREMAN_FORGE_CLI overrides detection" "gh" "$FORGE_CLI"
cd "$start_dir"

cd "$gitea_repo"
assert_eq "forge_owner_repo parses HTTPS origin" "ycastonguay/rce2" "$(forge_owner_repo)"
cd "$start_dir"

cd "$ssh_repo"
assert_eq "forge_owner_repo parses SSH origin" "ycastonguay/rce2" "$(forge_owner_repo)"
cd "$start_dir"

# --- timeline normalizers (recorded responses) -----------------------------
# Trimmed copies of real responses: Gitea 1.27.2 (scratch repo, foreman #75)
# and GitHub's documented timeline shape. Pure jq, no CLI call.

gitea_timeline='[
  {"id": 995, "type": "label", "body": "1", "user": {"id": 1, "login": "ycastonguay"},
   "label": {"id": 203, "name": "status: ready"}, "created_at": "2026-09-04T23:04:14Z"},
  {"id": 1017, "type": "comment", "body": "foreman: claimed by `racer-a`", "user": {"id": 1, "login": "ycastonguay"},
   "label": null, "created_at": "2026-09-04T23:16:47Z"},
  {"id": 1019, "type": "label", "body": "", "user": {"id": 1, "login": "ycastonguay"},
   "label": {"id": 203, "name": "status: ready"}, "created_at": "2026-09-04T23:16:55Z"},
  {"id": 1020, "type": "label", "body": "1", "user": {"id": 1, "login": "ycastonguay"},
   "label": {"id": 204, "name": "status: in-progress"}, "created_at": "2026-09-04T23:16:55Z"},
  {"id": 1030, "type": "label", "body": "1", "user": null,
   "label": {"id": 203, "name": "status: ready"}, "created_at": "2026-09-04T23:20:00Z"}
]'
expected_gitea='{"event":"labeled","actor":"ycastonguay","created_at":"2026-09-04T23:04:14Z"}
{"event":"unlabeled","actor":"ycastonguay","created_at":"2026-09-04T23:16:55Z"}
{"event":"labeled","actor":null,"created_at":"2026-09-04T23:20:00Z"}'
assert_eq "gitea timeline: body 1/empty is labeled/unlabeled, other rows skipped, missing user is null" \
  "$expected_gitea" "$(printf '%s' "$gitea_timeline" | _forge_tea_ready_events_from_timeline)"

github_timeline='[
  {"id": 1, "event": "labeled", "actor": {"login": "ghyc26"}, "label": {"name": "status: ready"}, "created_at": "2026-09-01T10:00:00Z"},
  {"id": 2, "event": "commented", "actor": {"login": "ghyc26"}, "created_at": "2026-09-01T10:00:05Z"},
  {"id": 3, "event": "unlabeled", "actor": {"login": "ghyc26"}, "label": {"name": "status: ready"}, "created_at": "2026-09-01T10:00:06Z"},
  {"id": 4, "event": "labeled", "actor": {"login": "ghyc26"}, "label": {"name": "task"}, "created_at": "2026-09-01T10:00:07Z"}
]'
expected_github='{"event":"labeled","actor":"ghyc26","created_at":"2026-09-01T10:00:00Z"}
{"event":"unlabeled","actor":"ghyc26","created_at":"2026-09-01T10:00:06Z"}'
assert_eq "github timeline: labeled/unlabeled for status: ready only" \
  "$expected_github" "$(printf '%s' "$github_timeline" | _forge_gh_ready_events_from_timeline)"

assert_eq "empty timeline normalizes to an empty stream" "" "$(printf '[]' | _forge_tea_ready_events_from_timeline)"

gitea_comments='[
  {"id": 1018, "user": {"id": 1, "login": "ycastonguay"}, "body": "foreman: claim by `racer-b` superseded\n\n<!-- foreman-claim issue: 1 epoch: 0 worker: racer-b -->", "created_at": "2026-09-04T23:16:48Z"},
  {"id": 1017, "user": null, "body": "orphaned", "created_at": "2026-09-04T23:16:47Z"}
]'
expected_comments='{"id":1018,"author":"ycastonguay","body":"foreman: claim by `racer-b` superseded\n\n<!-- foreman-claim issue: 1 epoch: 0 worker: racer-b -->","created_at":"2026-09-04T23:16:48Z"}
{"id":1017,"author":null,"body":"orphaned","created_at":"2026-09-04T23:16:47Z"}'
assert_eq "comments normalize to id/author/body/created_at, missing user is null" \
  "$expected_comments" "$(printf '%s' "$gitea_comments" | _forge_comments_normalize)"

# --- zsh regression: a local named `path` empties PATH under zsh ----------
# zsh ties the `path` array to PATH, so `local path=...` inside a function
# leaves every later external command in that function unfound. Two guards:
# a static one (no local may be named `path`), and a functional one that
# runs _forge_tea_api_get under zsh with a stub `tea` on a temp PATH - the
# function calls mktemp/head/cat/rm after its first local, which is exactly
# where the live macOS seat failed.
assert_eq "no local is named path (zsh ties it to PATH)" "" \
  "$(grep -nE '^\s*local\s+(\S+\s+)*path(=|\s|$)' "$script_dir/forge-cli.sh")"
if command -v zsh >/dev/null 2>&1; then
  stub_bin="$tmp_root/stub-bin"
  mkdir -p "$stub_bin"
  cat >"$stub_bin/tea" <<'STUB'
#!/bin/sh
echo "HTTP/2.0 200 OK" >&2
printf '{"stub":true}\n'
STUB
  chmod 755 "$stub_bin/tea"
  zsh_out="$(zsh -c 'source "$1"; PATH="$2:$PATH"; _forge_tea_api_get /stub' _ "$script_dir/forge-cli.sh" "$stub_bin" 2>&1)"
  assert_eq "_forge_tea_api_get works under zsh (PATH intact after its locals)" '{"stub":true}' "$zsh_out"
fi

echo
echo "$pass_count passed, $fail_count failed"
[[ "$fail_count" -eq 0 ]]
