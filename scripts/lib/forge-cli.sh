#!/usr/bin/env bash
# Shared forge-CLI detection and wrapper functions for gh/tea.
#
# Source this file, then call forge_detect_cli once before using any
# other forge_* function. Override detection with FOREMAN_FORGE_CLI=tea|gh.

forge_detect_cli() {
  if [[ -n "${FOREMAN_FORGE_CLI:-}" ]]; then
    FORGE_CLI="$FOREMAN_FORGE_CLI"
    return 0
  fi

  local origin_url
  origin_url="$(git remote get-url origin 2>/dev/null || true)"

  if [[ "$origin_url" == *"github.com"* ]]; then
    FORGE_CLI="gh"
  else
    FORGE_CLI="tea"
  fi
}

forge_owner_repo() {
  local origin_url
  origin_url="$(git remote get-url origin 2>/dev/null || true)"
  [[ -n "$origin_url" ]] || return 1

  # Strip protocol/host/user and trailing .git, leaving owner/repo.
  # Never name a local `path`: zsh ties the `path` array to PATH, so
  # `local path=...` empties PATH for the rest of the function (every
  # external command then fails with "command not found"). The Claude
  # seat on macOS runs this file under zsh.
  local repo_path="${origin_url#*://*/}"
  repo_path="${repo_path#*@*:}"
  repo_path="${repo_path%.git}"
  printf '%s\n' "$repo_path"
}

# Internal, pure: does an HTTP status line (e.g. "HTTP/2.0 200 OK") indicate
# success? Exit 0 for 2xx, non-zero otherwise (including an empty/malformed
# line). Split out from _forge_tea_api_get so it can be unit-tested without a
# network call - see forge-cli.test.sh.
_forge_http_status_ok() {
  local http_status="$1" code
  read -r _ code _ <<< "$http_status"
  [[ "$code" == 2* ]]
}

# Internal: GET a tea api path. Prints the response body to stdout and
# returns 0 only on a 2xx HTTP status.
#
# `tea api` itself always exits 0 regardless of the actual HTTP status
# (verified live against a real Gitea instance: a 404 error body is printed
# but the command still reports success), so every tea-backed forge_* below
# reads the real status from `tea api --include`'s status line instead of
# trusting the exit code or piping straight into jq.
_forge_tea_api_get() {
  local api_path="$1"   # not `path` - see forge_owner_repo
  local body_file err_file http_status body
  body_file="$(mktemp)"
  err_file="$(mktemp)"
  tea api --include "$api_path" >"$body_file" 2>"$err_file"
  http_status="$(head -1 "$err_file")"
  body="$(cat "$body_file")"
  rm -f "$body_file" "$err_file"
  if ! _forge_http_status_ok "$http_status"; then
    echo "forge-cli: tea api $api_path failed: ${http_status:-no response}" >&2
    return 1
  fi
  printf '%s\n' "$body"
}

# Internal: GET every page of a tea api listing and print the items as one
# JSON array, ascending by id with duplicates removed. Gitea paginates with
# limit/page (an unpaginated request returns only the default page), and
# the server clamps `limit` to its own MAX_RESPONSE_ITEMS, so a short page
# is not a reliable end marker: stop on an empty page or when a page
# repeats the previous page's first id (an endpoint that ignores paging
# returns the same list every time), capped at 20 pages as a backstop.
# Pages are accumulated in a temp file, never on a jq command line, so a
# large page cannot hit ARG_MAX. `api_path` may already carry a query
# string. Non-zero on any failed request or unparsable page.
_forge_tea_api_get_all() {
  local api_path="$1" sep page body first_id prev_first_id pages_file count
  [[ "$api_path" == *\?* ]] && sep='&' || sep='?'
  pages_file="$(mktemp)"
  prev_first_id=''
  for page in {1..20}; do
    body="$(_forge_tea_api_get "${api_path}${sep}limit=50&page=${page}")" || { rm -f "$pages_file"; return 1; }
    count="$(printf '%s' "$body" | jq 'length')" || { rm -f "$pages_file"; return 1; }
    [[ "$count" -eq 0 ]] && break
    first_id="$(printf '%s' "$body" | jq '.[0].id')" || { rm -f "$pages_file"; return 1; }
    [[ "$first_id" == "$prev_first_id" ]] && break
    printf '%s\n' "$body" >>"$pages_file"
    prev_first_id="$first_id"
  done
  jq -c -s 'add // [] | unique_by(.id)' "$pages_file" || { rm -f "$pages_file"; return 1; }
  rm -f "$pages_file"
}

# Internal, pure: normalizes a Gitea `/issues/<n>/timeline` array (stdin) to
# the ready-event stream forge_issue_ready_events documents. Verified live
# against Gitea 1.27.2 (foreman #75): a label add and a label remove are
# both `type: "label"`; only the body tells them apart - "1" for an add,
# "" for a remove (Gitea's models/issues/issue_label.go). The actor is
# `user.login`, the label name `label.name`, and `created_at` is RFC 3339.
# Unrelated rows (comments, assignments, ...) share the envelope with
# `label: null`, so the select must test the type first.
_forge_tea_ready_events_from_timeline() {
  jq -c '.[]
    | select(.type == "label" and (.label.name // "") == "status: ready")
    | {event: (if .body == "1" then "labeled" else "unlabeled" end),
       actor: (.user.login // null),
       created_at}'
}

# Internal, pure: same normalization for GitHub's timeline array (stdin).
# Also consumes the concatenated per-page arrays `gh api --paginate` emits.
_forge_gh_ready_events_from_timeline() {
  jq -c '.[]
    | select((.event == "labeled" or .event == "unlabeled") and .label.name == "status: ready")
    | {event, actor: (.actor.login // null), created_at}'
}

# Internal, pure: normalizes an issue-comments array (stdin; same shape on
# both forges) to the stream forge_issue_comments_json documents.
_forge_comments_normalize() {
  jq -c '.[] | {id, author: (.user.login // null), body, created_at}'
}

# forge_issue_ready_events <issue_number>
# Streams the issue's `status: ready` label events, oldest first, one JSON
# object per line with identical keys on both forges:
#   {"event":"labeled"|"unlabeled","actor":<login or null>,"created_at":<RFC 3339>}
# Walks every page. Returns non-zero (printing nothing) when the timeline
# cannot be read - callers must treat that, an empty stream, or a null actor
# as a failed authorization check, never as a pass (task-run, headless mode).
forge_issue_ready_events() {
  local n="$1"
  case "$FORGE_CLI" in
    gh)
      # --paginate emits one JSON array per page; the normalizer reads
      # them as a stream, so no --jq filter (and no [...] wrapping) here.
      gh api "repos/$(forge_owner_repo)/issues/$n/timeline" --paginate \
        | _forge_gh_ready_events_from_timeline
      ;;
    tea)
      local events
      events="$(_forge_tea_api_get_all "/repos/$(forge_owner_repo)/issues/$n/timeline")" || return 1
      printf '%s' "$events" | _forge_tea_ready_events_from_timeline
      ;;
    *)
      echo "forge-cli: unknown FORGE_CLI '$FORGE_CLI'" >&2
      return 1
      ;;
  esac
}

# forge_issue_comments_json <issue_number>
# Streams the issue's comments, oldest first, one JSON object per line:
#   {"id":<n>,"author":<login or null>,"body":<text>,"created_at":<RFC 3339>}
# Both forges serve PR conversation comments through the same endpoint, so
# a PR number works too. Non-zero on a read failure.
forge_issue_comments_json() {
  local n="$1"
  case "$FORGE_CLI" in
    gh)
      gh api "repos/$(forge_owner_repo)/issues/$n/comments" --paginate \
        | _forge_comments_normalize
      ;;
    tea)
      # Gitea's per-issue comments endpoint ignores limit/page and returns
      # the whole list in one response (verified live on 1.27.2: limit=3
      # still returned every comment on every page), so this is a single
      # request, sorted by id in case the server's order ever differs.
      local comments
      comments="$(_forge_tea_api_get "/repos/$(forge_owner_repo)/issues/$n/comments")" || return 1
      printf '%s' "$comments" | jq -c 'sort_by(.id)' | _forge_comments_normalize
      ;;
    *)
      echo "forge-cli: unknown FORGE_CLI '$FORGE_CLI'" >&2
      return 1
      ;;
  esac
}

forge_repo_capability_check() {
  case "$FORGE_CLI" in
    gh)
      gh repo view --json nameWithOwner >/dev/null
      ;;
    tea)
      _forge_tea_api_get "/repos/$(forge_owner_repo)" >/dev/null
      ;;
    *)
      echo "forge-cli: unknown FORGE_CLI '$FORGE_CLI'" >&2
      return 1
      ;;
  esac
}

forge_default_branch() {
  case "$FORGE_CLI" in
    gh)
      gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name'
      ;;
    tea)
      local body
      body="$(_forge_tea_api_get "/repos/$(forge_owner_repo)")" || return 1
      printf '%s' "$body" | jq -r '.default_branch'
      ;;
    *)
      echo "forge-cli: unknown FORGE_CLI '$FORGE_CLI'" >&2
      return 1
      ;;
  esac
}

# forge_pr_url_for_branch <branch>
# Prints the URL of an existing open PR for the branch, if any. Returns
# non-zero (and prints nothing) if no such PR exists.
forge_pr_url_for_branch() {
  local branch="$1"
  case "$FORGE_CLI" in
    gh)
      gh pr view "$branch" --json url --jq '.url' 2>/dev/null
      ;;
    tea)
      # Goes through `tea api` (Gitea's documented REST schema: PRBranchInfo.ref,
      # PullRequest.html_url) rather than tea's own --output json, whose internal
      # field shapes aren't part of any stable contract.
      #
      # Paginated: a single unpaginated request only returns the API's default
      # page (30 items), so a branch's PR could be missed - and silently
      # duplicated by forge_pr_create - once a repo has enough open PRs. Walk
      # pages of 50 until the branch is found or a short page signals the end,
      # capped at 20 pages (1000 open PRs) as a backstop against a runaway loop.
      local page limit body url count
      limit=50
      for page in $(seq 1 20); do
        body="$(_forge_tea_api_get "/repos/$(forge_owner_repo)/pulls?state=open&limit=${limit}&page=${page}")" || return 1
        url="$(printf '%s' "$body" | jq -r --arg h "$branch" '[.[] | select(.head.ref == $h)][0].html_url // empty')"
        if [[ -n "$url" ]]; then
          printf '%s\n' "$url"
          return 0
        fi
        count="$(printf '%s' "$body" | jq 'length')"
        [[ "$count" -lt "$limit" ]] && break
      done
      return 1
      ;;
    *)
      echo "forge-cli: unknown FORGE_CLI '$FORGE_CLI'" >&2
      return 1
      ;;
  esac
}

# forge_pr_create <base> <head> <title> <body_file> <draft:0|1>
forge_pr_create() {
  local base="$1" head="$2" title="$3" body_file="$4" draft="$5"

  case "$FORGE_CLI" in
    gh)
      local args=(--title "$title" --body-file "$body_file")
      [[ -n "$base" ]] && args+=(--base "$base")
      [[ -n "$head" ]] && args+=(--head "$head")
      [[ "$draft" -eq 1 ]] && args+=(--draft)
      gh pr create "${args[@]}"
      ;;
    tea)
      local args=(--title "$title" --description "$(cat "$body_file")")
      [[ -n "$base" ]] && args+=(--base "$base")
      [[ -n "$head" ]] && args+=(--head "$head")
      [[ "$draft" -eq 1 ]] && args+=(--draft)
      # tea's --draft prepends "WIP: " to the title instead of sending a
      # draft flag; Gitea treats that prefix as its draft state, so the PR
      # lands as `draft: true` and unmergeable-until-ready, the same net
      # effect as gh --draft (verified live on Gitea 1.27.2, foreman #75:
      # "WIP: <title>", draft true, and forge_pr_url_for_branch finds it).
      # Base/head fall back to tea's own defaults (repo default branch /
      # current branch) when omitted, same as gh.
      tea pulls create "${args[@]}"
      ;;
    *)
      echo "forge-cli: unknown FORGE_CLI '$FORGE_CLI'" >&2
      return 1
      ;;
  esac
}

# forge_pr_comment <pr_number> <body_file>
forge_pr_comment() {
  local pr_number="$1" body_file="$2"

  case "$FORGE_CLI" in
    gh)
      gh pr comment "$pr_number" --body-file "$body_file"
      ;;
    tea)
      tea comments add "$pr_number" --description "$(cat "$body_file")"
      ;;
    *)
      echo "forge-cli: unknown FORGE_CLI '$FORGE_CLI'" >&2
      return 1
      ;;
  esac
}

# The functions below back task-run's security-sensitive authorship check.
# The tea branches go through `tea api` against Gitea's documented REST
# schema (verified against gitea.com's published swagger: Issue.user.login,
# Label.name, and GET /orgs/{org} returning 200 for an org / 404 for a user
# - Gitea's User object has no gh-style "type" field to read directly).

# forge_repo_owner_is_org
# Exit 0 if the repo's owner is an organization, non-zero if it's a user.
forge_repo_owner_is_org() {
  case "$FORGE_CLI" in
    gh)
      [[ "$(gh repo view --json owner --jq '.owner.type')" == "Organization" ]]
      ;;
    tea)
      # `tea api` exits 0 regardless of HTTP status (verified live: a 404 body
      # is printed but the command still succeeds), so the org check has to
      # read the actual status line via --include rather than the exit code.
      local owner_repo owner http_status
      owner_repo="$(forge_owner_repo)"
      owner="${owner_repo%%/*}"
      http_status="$(tea api --include "/orgs/$owner" 2>&1 >/dev/null | head -1)"
      _forge_http_status_ok "$http_status"
      ;;
    *)
      echo "forge-cli: unknown FORGE_CLI '$FORGE_CLI'" >&2
      return 1
      ;;
  esac
}

forge_repo_owner_login() {
  case "$FORGE_CLI" in
    gh)
      gh repo view --json owner --jq '.owner.login'
      ;;
    tea)
      local body
      body="$(_forge_tea_api_get "/repos/$(forge_owner_repo)")" || return 1
      printf '%s' "$body" | jq -r '.owner.login'
      ;;
    *)
      echo "forge-cli: unknown FORGE_CLI '$FORGE_CLI'" >&2
      return 1
      ;;
  esac
}

# forge_issue_author_login <issue_number>
forge_issue_author_login() {
  local n="$1"
  case "$FORGE_CLI" in
    gh)
      gh issue view "$n" --json author --jq '.author.login'
      ;;
    tea)
      local body
      body="$(_forge_tea_api_get "/repos/$(forge_owner_repo)/issues/$n")" || return 1
      printf '%s' "$body" | jq -r '.user.login'
      ;;
    *)
      echo "forge-cli: unknown FORGE_CLI '$FORGE_CLI'" >&2
      return 1
      ;;
  esac
}

# forge_issue_labels <issue_number>
# Prints one label name per line.
forge_issue_labels() {
  local n="$1"
  case "$FORGE_CLI" in
    gh)
      gh issue view "$n" --json labels --jq '.labels[].name'
      ;;
    tea)
      local body
      body="$(_forge_tea_api_get "/repos/$(forge_owner_repo)/issues/$n")" || return 1
      printf '%s' "$body" | jq -r '.labels[].name'
      ;;
    *)
      echo "forge-cli: unknown FORGE_CLI '$FORGE_CLI'" >&2
      return 1
      ;;
  esac
}

# forge_issue_list_by_label <label>
forge_issue_list_by_label() {
  local label="$1"
  case "$FORGE_CLI" in
    gh)
      gh issue list --label "$label"
      ;;
    tea)
      tea issues list --labels "$label"
      ;;
    *)
      echo "forge-cli: unknown FORGE_CLI '$FORGE_CLI'" >&2
      return 1
      ;;
  esac
}

# forge_issue_ensure_label <name> <color> <description>
# Idempotent: creates the label if missing, updates it (color/description)
# if it already exists. Equivalent to `gh label create --force`.
forge_issue_ensure_label() {
  local name="$1" color="$2" description="$3"
  case "$FORGE_CLI" in
    gh)
      gh label create "$name" --color "$color" --description "$description" --force
      ;;
    tea)
      # Goes through `tea api` rather than `tea labels list --output json`:
      # verified live that tea's own JSON uses "index" (a string) for this,
      # not "id" - only the raw Gitea API's Label object has a numeric "id".
      local body id
      body="$(_forge_tea_api_get "/repos/$(forge_owner_repo)/labels")" || return 1
      id="$(printf '%s' "$body" | jq -r --arg n "$name" '.[] | select(.name == $n) | .id' | head -n1)"
      if [[ -n "$id" ]]; then
        tea labels update --id "$id" --name "$name" --color "$color" --description "$description"
      else
        tea labels create --name "$name" --color "$color" --description "$description"
      fi
      ;;
    *)
      echo "forge-cli: unknown FORGE_CLI '$FORGE_CLI'" >&2
      return 1
      ;;
  esac
}

# forge_issue_add_label <issue_number> <label>
forge_issue_add_label() {
  local n="$1" label="$2"
  case "$FORGE_CLI" in
    gh)
      gh issue edit "$n" --add-label "$label"
      ;;
    tea)
      tea issues edit "$n" --add-labels "$label"
      ;;
    *)
      echo "forge-cli: unknown FORGE_CLI '$FORGE_CLI'" >&2
      return 1
      ;;
  esac
}

# forge_issue_remove_label <issue_number> <label>
forge_issue_remove_label() {
  local n="$1" label="$2"
  case "$FORGE_CLI" in
    gh)
      gh issue edit "$n" --remove-label "$label"
      ;;
    tea)
      tea issues edit "$n" --remove-labels "$label"
      ;;
    *)
      echo "forge-cli: unknown FORGE_CLI '$FORGE_CLI'" >&2
      return 1
      ;;
  esac
}

# forge_issue_comment <issue_number> <body_file>
forge_issue_comment() {
  local n="$1" body_file="$2"
  case "$FORGE_CLI" in
    gh)
      gh issue comment "$n" --body-file "$body_file"
      ;;
    tea)
      tea comments add "$n" --description "$(cat "$body_file")"
      ;;
    *)
      echo "forge-cli: unknown FORGE_CLI '$FORGE_CLI'" >&2
      return 1
      ;;
  esac
}

# forge_issue_close <issue_number>
forge_issue_close() {
  local n="$1"
  case "$FORGE_CLI" in
    gh)
      gh issue close "$n"
      ;;
    tea)
      tea issues close "$n"
      ;;
    *)
      echo "forge-cli: unknown FORGE_CLI '$FORGE_CLI'" >&2
      return 1
      ;;
  esac
}

# forge_issue_fetch_json <issue_number>
# Prints a normalized JSON object with consistent keys regardless of which
# CLI is active: {title, body, number, url, labels: [name, ...], author, state}.
# `state` is normalized to lowercase `open` / `closed` on both forges.
forge_issue_fetch_json() {
  local n="$1"
  case "$FORGE_CLI" in
    gh)
      gh issue view "$n" --json title,body,number,url,labels,author,state \
        | jq '{title, body, number, url, labels: [.labels[].name], author: .author.login, state: (.state | ascii_downcase)}'
      ;;
    tea)
      local body
      body="$(_forge_tea_api_get "/repos/$(forge_owner_repo)/issues/$n")" || return 1
      printf '%s' "$body" | jq '{title, body, number, url: .html_url, labels: [.labels[].name], author: .user.login, state}'
      ;;
    *)
      echo "forge-cli: unknown FORGE_CLI '$FORGE_CLI'" >&2
      return 1
      ;;
  esac
}
