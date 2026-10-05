#!/usr/bin/env bash
# Shared forge-CLI detection and wrapper functions for gh/tea.
#
# Source this file, then call forge_detect_cli once before using any
# other forge_* function. Override detection with FOREMAN_FORGE_CLI=tea|gh.
# Override forge_owner_repo similarly with FOREMAN_FORGE_OWNER_REPO=owner/repo,
# for a caller with no git checkout at its own cwd to read `origin` from
# (redeploy-linux.sh/redeploy-macos.sh --tag mode: the download runs as
# the foreman user, whose cwd is whatever it inherited from the invoking
# admin shell - not necessarily any checkout of this repo at all - so
# those scripts resolve both overrides once, from their own known-good
# checkout, and pass them through instead of letting the foreman-side
# step guess from an arbitrary cwd).
#
# On the gh side, every call on `/task-run`'s path goes through `gh api`
# against GitHub's REST API, and none through a `gh <noun> view|list --json`
# projection (the two exceptions are named at the end of this comment), because
# those are served by GitHub's GraphQL API and **a Claude Code cloud session
# cannot reach GraphQL at all**: the session's credential proxy answers
# every api.github.com/graphql request with
#   HTTP 403: GitHub GraphQL is not available from Claude Code sessions;
#             use the REST API (gh api repos/{owner}/{repo}/...)
# regardless of the token or the environment's network policy (verified live
# in routine session cse_018VUAzMF7WXJsQaZStjWwyp, where `gh pr list --json
# number` 403'd while `gh api "repos/OWNER/REPO/pulls?state=open"`
# succeeded). A routine-started cloud session runs `/task-run <n>
# --headless` through this file, so a GraphQL-backed helper anywhere on that
# path makes the whole run impossible. REST is equally available on a
# worker, so this is one code path, not a cloud-only fallback.
#
# Two groups are deliberately still GraphQL-backed, and therefore usable
# from a worker or a laptop but not from inside a cloud session: the task
# relationship helpers at the bottom of this file (`gh issue edit --parent`
# / `--add-blocked-by` and their read-back), which only `task-create` and
# `task-breakdown` call, and `forge_release_download_asset`, which only the
# redeploy scripts call. Neither is on `task-run`'s path.

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
  if [[ -n "${FOREMAN_FORGE_OWNER_REPO:-}" ]]; then
    printf '%s\n' "$FOREMAN_FORGE_OWNER_REPO"
    return 0
  fi

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

# Internal, pure: picks the HTTP status line out of `tea api --include`'s
# stderr (stdin). It is the first `HTTP/` line, not stderr's first line:
# when no checkout matches a login (a FOREMAN_FORGE_OWNER_REPO caller with
# no checkout, or any cwd outside one) tea first prints a "NOTE: no login
# matched this repository" line there, which read as the status would fail
# every request. Prints nothing when there is no status line.
_forge_tea_status_line() {
  grep -m1 '^HTTP/' || true
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
  http_status="$(_forge_tea_status_line <"$err_file")"
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

# Internal, pure: percent-encodes one value for a URL path segment or query
# parameter, through jq's @uri. Label names are why this exists: every
# `status:*` label carries a colon and a space, and `gh api` escapes nothing
# for you - an unescaped `status: ready` in a path addresses a different,
# nonexistent label and 404s.
_forge_gh_uri_escape() {
  jq -rn --arg s "$1" '$s | @uri'
}

# Internal, pure: is this a plain positive issue or pull-request number?
#
# The wrappers this guards interpolate their number into a REST URL path,
# where a malformed value is traversal-shaped rather than merely rejected the
# way `gh issue view <n>` used to reject it. (The two relationship writers at
# the foot of this file build such a path on their tea branch and are not
# guarded: they are outside the change that added this, and their body side is
# already type-checked by `jq --argjson`.) Both callers
# validate already - `scripts/task-status.sh` refuses a non-numeric argument
# (pinned in its own tests) and the routine's prompt parses
# `<owner>/<repo>#<number>` - so this is the second line of that defence, not
# the first, and it guards both forges' branches because both build the same
# path shape.
_forge_number_ok() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

# Internal, pure: normalizes a GitHub REST issue object (stdin) to the shape
# forge_issue_fetch_json documents. REST names three things differently from
# the GraphQL projection it replaced: `html_url` for the web URL, `user` for
# the author, and a *null* body where GraphQL returned an empty string - so
# the empty-body case is mapped back to "" rather than passed through as
# null. `state` is already lowercase here; ascii_downcase keeps the
# documented guarantee whatever the endpoint sends.
_forge_gh_issue_normalize() {
  jq '{title, body: (.body // ""), number, url: .html_url,
       labels: [.labels[].name], author: .user.login,
       state: (.state | ascii_downcase)}'
}

# Internal, pure: given one or more REST pull-request arrays (stdin) and a
# head branch ($1), prints the first matching PR's html_url, and nothing when
# none matches. `// empty` is what makes "no match" an empty stdout, which
# the caller turns into a non-zero exit.
#
# `-s` slurps into an array of arrays and `.[][]` walks the requests inside,
# which makes this indifferent to whether the caller sent one filtered page
# or the concatenated pages of a `gh api --paginate` read. Its caller sends a
# single page today; the tolerance is kept deliberately, so the filter stays
# the contract and the request shape stays free to change.
_forge_gh_pr_url_for_head() {
  jq -r -s --arg h "$1" '[.[][] | select(.head.ref == $h)][0].html_url // empty'
}

# Internal, pure: normalizes `gh api --paginate`'s concatenated per-page
# arrays of REST issues (stdin) to one human-readable row per issue,
#   #<number><TAB><title><TAB><label,label>
# because only a human ever reads this listing (task-run's "pick one"
# prompt, task-breakdown's survey) - a readable table is the contract, not
# JSON. REST's /issues listing includes pull requests where `gh issue list`
# did not, so rows carrying a `pull_request` key are dropped; without that a
# PR would be offered as a task.
_forge_gh_issue_list_rows() {
  jq -r -s '.[][] | select(.pull_request == null)
    | "#\(.number)\t\(.title)\t\([.labels[].name] | join(","))"'
}

# Internal, pure: the JSON body of a comment write, with the text read from
# a file ($1) by jq itself. jq only, no network.
#
# The body never passes through argv or a `gh api -F body=@path` typed
# field: a comment carries untrusted, arbitrary prose - markdown, quotes,
# newlines, a marker block - and jq's --rawfile makes it exactly one JSON
# string whatever it contains, where a typed field would have gh decide
# whether the file's contents look like a string.
_forge_gh_comment_body() {
  jq -n --rawfile body "$1" '{body: $body}'
}

# Internal: POST the JSON body on stdin to a REST path and print the created
# object's `html_url`. Non-zero, printing nothing, when the request fails or
# the response carries no URL.
#
# The body is written to a temp file and sent with `--input <file>` rather
# than piped through `--input -`: gh sends a piped body with
# `Transfer-Encoding: chunked` and no `Content-Length`, and a cloud session's
# credential proxy is the one hop on this path whose handling of a chunked
# request body nothing here can test. A file body carries a Content-Length,
# which removes the question rather than leaving it to the first real run.
#
# The URL is picked out of a captured response, never with `gh api --jq`: on
# a failed write gh skips the filter and copies the API's error object to
# stdout, so a piped-through call would print `{"message":...}` where a URL
# belongs. A 2xx whose body has no `html_url` is a failure here too, rather
# than the literal `null` jq would otherwise print.
_forge_gh_post_json_url() {
  local api_path="$1" body_json response url
  body_json="$(mktemp)" || return 1
  # A failed write here would otherwise send an empty body and surface as a
  # remote 422, where the fault is local.
  cat >"$body_json" || { rm -f "$body_json"; return 1; }
  if ! response="$(gh api --method POST "$api_path" --input "$body_json")"; then
    rm -f "$body_json"
    return 1
  fi
  rm -f "$body_json"
  url="$(printf '%s' "$response" | jq -r '.html_url // empty')" || return 1
  if [[ -z "$url" ]]; then
    echo "forge-cli: POST $api_path returned no html_url" >&2
    return 1
  fi
  printf '%s\n' "$url"
}

# Internal, pure: the JSON body of a pull-request create. Same rule for the
# description as _forge_gh_comment_body; `draft` is a real JSON boolean
# rather than the string "true".
_forge_gh_pr_body() {
  local title="$1" head="$2" base="$3" body_file="$4" draft="$5"
  jq -n --arg title "$title" --arg head "$head" --arg base "$base" \
    --rawfile body "$body_file" --argjson draft "$draft" \
    '{title: $title, head: $head, base: $base, body: $body, draft: $draft}'
}

# Internal, pure: normalizes an issue-comments array (stdin; same shape on
# both forges) to the stream forge_issue_comments_json documents.
_forge_comments_normalize() {
  jq -c '.[] | {id, author: (.user.login // null), body, created_at}'
}

# Internal, pure: given a Gitea release object (stdin) and an asset name
# ($1), prints that asset's browser_download_url - empty if no asset by
# that name is on the release. jq only, no network.
_forge_tea_release_asset_url() {
  jq -r --arg n "$1" '.assets[] | select(.name == $n) | .browser_download_url' | head -n1
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
  _forge_number_ok "$n" || { echo "forge-cli: not an issue number: '$n'" >&2; return 1; }
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
  _forge_number_ok "$n" || { echo "forge-cli: not an issue number: '$n'" >&2; return 1; }
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
      gh api "repos/$(forge_owner_repo)" >/dev/null
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
      gh api "repos/$(forge_owner_repo)" --jq '.default_branch'
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
      # `gh api` + a pure filter rather than `gh pr view --json url`, which
      # is GraphQL-backed and unreachable from a cloud session (see the
      # header).
      #
      # Filtered server-side by head ref, so this is one request that
      # returns at most one PR - no pagination, and none of the
      # walk-every-open-PR cost the tea branch below has to pay because
      # Gitea's listing has no equivalent filter. `head` is
      # `<owner>:<branch>`, and the owner is this repository's: every branch
      # the fleet opens a PR from is pushed to the repository itself, never
      # to a fork.
      #
      # The head-ref match is applied again locally, cheaply, rather than
      # trusted from the query - the filter is the optimization, the
      # normalizer is the contract, and it is what the offline tests pin.
      #
      # Captured rather than piped: on a failed request `gh api` prints the
      # API's error object to stdout, and the normalizer's `.[][]` would
      # then die with jq's "Cannot iterate over object" instead of the
      # API's own message - and on an empty capture it would answer "no
      # PR", which is not the same thing as a read that failed.
      # The head value is escaped like every other caller-supplied value that
      # reaches a query: git allows `&`, `%` and `#` in a ref name, and an
      # unescaped one would corrupt the query rather than fail it. The
      # endpoint accepts the fully escaped form, colon included.
      local owner_repo pulls gh_url
      owner_repo="$(forge_owner_repo)" || return 1
      pulls="$(gh api \
        "repos/$owner_repo/pulls?state=open&head=$(_forge_gh_uri_escape "${owner_repo%%/*}:$branch")")" \
        || return 1
      gh_url="$(printf '%s' "$pulls" | _forge_gh_pr_url_for_head "$branch")" || return 1
      [[ -n "$gh_url" ]] || return 1
      printf '%s\n' "$gh_url"
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
      # POST to the REST endpoint rather than `gh pr create`, which reaches
      # for GraphQL and so cannot run in a cloud session (see the header).
      # Prints the new PR's URL on stdout, exactly as `gh pr create` did.
      #
      # `gh pr create` filled an omitted --base/--head in from the checkout
      # (repo default branch / current branch); REST requires both, so the
      # empty cases resolve those same two defaults explicitly here.
      local pr_base="$base" pr_head="$head" draft_flag=false
      if [[ -z "$pr_base" ]]; then
        pr_base="$(forge_default_branch)" || return 1
      fi
      if [[ -z "$pr_head" ]]; then
        # `git rev-parse --abbrev-ref HEAD` answers the literal `HEAD` on a
        # detached checkout, which would be POSTed as a branch name and
        # answered with a 422; `gh pr create` refused up front instead, so
        # refuse here too rather than send a request that cannot work. Every
        # caller passes head explicitly today, so this is the unused half of
        # the fallback either way.
        pr_head="$(git rev-parse --abbrev-ref HEAD)" || return 1
        if [[ "$pr_head" == "HEAD" ]]; then
          echo "forge-cli: cannot infer a head branch from a detached HEAD" >&2
          return 1
        fi
      fi
      if [[ "$draft" -eq 1 ]]; then
        draft_flag=true
      fi
      _forge_gh_pr_body "$title" "$pr_head" "$pr_base" "$body_file" "$draft_flag" \
        | _forge_gh_post_json_url "repos/$(forge_owner_repo)/pulls"
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
      tea pulls create --repo "$(forge_owner_repo)" "${args[@]}"
      ;;
    *)
      echo "forge-cli: unknown FORGE_CLI '$FORGE_CLI'" >&2
      return 1
      ;;
  esac
}

# forge_release_download_asset <tag> <asset_name> <dest_dir>
# Downloads one named asset from the release tagged <tag> into
# <dest_dir>/<asset_name>. Non-zero (nothing written) if the release, the
# asset, or the download fails.
#
# The gh branch is the one read here that still goes through `gh` rather
# than `gh api`, so it is usable from a worker or a laptop but not from
# inside a cloud session (see the header). Only the redeploy scripts call
# it, and a cloud session never redeploys anything.
forge_release_download_asset() {
  local tag="$1" asset_name="$2" dest_dir="$3"
  mkdir -p "$dest_dir"
  case "$FORGE_CLI" in
    gh)
      gh release download "$tag" --repo "$(forge_owner_repo)" --pattern "$asset_name" --dir "$dest_dir" --clobber
      ;;
    tea)
      # Gitea's API describes each asset with a `browser_download_url`
      # (a repo web route, not under /api/v1, so `tea api` can't reach it
      # directly) - fetch the release JSON via tea api, pick the matching
      # asset's URL out of it, then curl the actual bytes. A private
      # instance's download route accepts the same token as the API
      # (Gitea's "token <T>" scheme - forge_wiring.rs reads it as
      # FOREMAN_GITEA_TOKEN for the daemon); when set here, it's piped
      # into curl's config reader (-K -) rather than ever written to a
      # file - docs/setup-linux.md is explicit that the token lives only
      # in tea's own config and foreman.env, nowhere else, and a `-K
      # <tempfile>` version of this briefly put it in a third place.
      local body url
      body="$(_forge_tea_api_get "/repos/$(forge_owner_repo)/releases/tags/$tag")" || return 1
      url="$(printf '%s' "$body" | _forge_tea_release_asset_url "$asset_name")"
      if [[ -z "$url" ]]; then
        echo "forge-cli: asset $asset_name not found in release $tag" >&2
        return 1
      fi
      if [[ -n "${FOREMAN_GITEA_TOKEN:-}" ]]; then
        printf 'header = "Authorization: token %s"\n' "$FOREMAN_GITEA_TOKEN" \
          | curl -fsSL -K - -o "$dest_dir/$asset_name" "$url"
        return $?
      fi
      curl -fsSL -o "$dest_dir/$asset_name" "$url"
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
  _forge_number_ok "$pr_number" || { echo "forge-cli: not a PR number: '$pr_number'" >&2; return 1; }

  case "$FORGE_CLI" in
    gh)
      # A PR's conversation comments are the issue's comments on both forges
      # (the same endpoint forge_issue_comments_json reads), so this is the
      # issues route with the PR's number.
      _forge_gh_comment_body "$body_file" \
        | _forge_gh_post_json_url "repos/$(forge_owner_repo)/issues/$pr_number/comments"
      ;;
    tea)
      tea comments add "$pr_number" --repo "$(forge_owner_repo)" --description "$(cat "$body_file")"
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
      [[ "$(gh api "repos/$(forge_owner_repo)" --jq '.owner.type')" == "Organization" ]]
      ;;
    tea)
      # `tea api` exits 0 regardless of HTTP status (verified live: a 404 body
      # is printed but the command still succeeds), so the org check has to
      # read the actual status line via --include rather than the exit code.
      local owner_repo owner http_status
      owner_repo="$(forge_owner_repo)"
      owner="${owner_repo%%/*}"
      http_status="$(tea api --include "/orgs/$owner" 2>&1 >/dev/null | _forge_tea_status_line)"
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
      gh api "repos/$(forge_owner_repo)" --jq '.owner.login'
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
  _forge_number_ok "$n" || { echo "forge-cli: not an issue number: '$n'" >&2; return 1; }
  case "$FORGE_CLI" in
    gh)
      gh api "repos/$(forge_owner_repo)/issues/$n" --jq '.user.login'
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
  _forge_number_ok "$n" || { echo "forge-cli: not an issue number: '$n'" >&2; return 1; }
  case "$FORGE_CLI" in
    gh)
      gh api "repos/$(forge_owner_repo)/issues/$n" --jq '.labels[].name'
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
# Lists the repository's open issues carrying <label>, for a human to read
# and pick from - never for a caller to parse.
#
# The two forges print different shapes, and neither is a contract: the gh
# branch prints `#<number><TAB><title><TAB><label,label>` per issue (this
# file's own format, since the REST listing has none), while the tea branch
# prints `tea issues list`'s own multi-column table. Both are one page, not
# every matching issue: a listing nobody parses does not earn the requests.
# A caller that needs structured issue data wants forge_issue_fetch_json
# instead.
forge_issue_list_by_label() {
  local label="$1"
  case "$FORGE_CLI" in
    gh)
      # `gh issue list` is GraphQL-backed (see the header). The REST listing
      # needs the label percent-encoded (`status: ready` has a colon and a
      # space) and returns pull requests alongside issues, both of which
      # _forge_gh_issue_list_rows handles; it prints the human-readable rows
      # this function has always been read as. Captured before filtering for
      # the same reason as forge_pr_url_for_branch above.
      #
      # One page of 50, not `--paginate`: the only consumer is a human (or an
      # agent) picking one number out of the list, so walking every labelled
      # issue in the repository would spend requests and context on rows
      # nobody reads. `gh issue list` showed 30 by default, so this is still
      # the larger listing of the two.
      #
      # `labels` is a comma-separated parameter, so escaping makes a label
      # safe to send but cannot make one containing a comma addressable - the
      # server splits it either way. No label in this fleet's palette has
      # one (`docs/standards` and task-status.sh's own list).
      local issues
      issues="$(gh api \
        "repos/$(forge_owner_repo)/issues?state=open&per_page=50&labels=$(_forge_gh_uri_escape "$label")")" \
        || return 1
      printf '%s' "$issues" | _forge_gh_issue_list_rows
      ;;
    tea)
      tea issues list --repo "$(forge_owner_repo)" --labels "$label"
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
      # `gh label create --force` resolved an existing label through
      # `gh label list`, which is GraphQL-backed (see the header), so the
      # create-or-update decision is made from a REST read here instead -
      # the same shape as the tea branch below.
      #
      # The decision is a read, never a parse of the failed write's message:
      # `gh api` puts the API's JSON error body on *stdout* and only its own
      # one-line summary ("gh: Validation Failed (HTTP 422)") on stderr, so
      # classifying a duplicate by matching `already_exists` against stderr
      # silently matches nothing and fails every label that already exists.
      # Re-reading the label is also what task-status.sh does for its own
      # writes, rather than trusting an error string.
      local label_path existing post_err
      label_path="repos/$(forge_owner_repo)/labels/$(_forge_gh_uri_escape "$name")"
      if ! existing="$(gh api "$label_path" 2>/dev/null)"; then
        # The create's own stderr is held back rather than printed: on the
        # concurrent-create path below the call succeeds, and gh's
        # "Validation Failed (HTTP 422)" line would otherwise reach the
        # caller as if something had gone wrong.
        post_err="$(mktemp)" || return 1
        if gh api --method POST "repos/$(forge_owner_repo)/labels" \
          -f "name=$name" -f "color=$color" -f "description=$description" \
          >/dev/null 2>"$post_err"; then
          rm -f "$post_err"
          return 0
        fi
        # A concurrent run can create the label between that read and this
        # write, which is a 422 rather than a failure: if it is there now,
        # fall through to the update the read-first path would have made.
        # Anything else - no permission, an invalid colour - leaves the
        # label absent, and this read fails the call, reporting what the
        # create actually said.
        if ! existing="$(gh api "$label_path" 2>/dev/null)"; then
          cat "$post_err" >&2
          rm -f "$post_err"
          return 1
        fi
        rm -f "$post_err"
      fi
      # Already exactly as asked for: the read was the whole cost of the
      # call, which keeps the steady state at one request per label rather
      # than a read and a write (scripts/task-status.sh records that cost).
      if printf '%s' "$existing" | jq -e --arg c "$color" --arg d "$description" \
        '.color == $c and (.description // "") == $d' >/dev/null; then
        return 0
      fi
      gh api --method PATCH "$label_path" \
        -f "color=$color" -f "description=$description" >/dev/null
      ;;
    tea)
      # Goes through `tea api` rather than `tea labels list --output json`:
      # verified live that tea's own JSON uses "index" (a string) for this,
      # not "id" - only the raw Gitea API's Label object has a numeric "id".
      local body id
      body="$(_forge_tea_api_get "/repos/$(forge_owner_repo)/labels")" || return 1
      id="$(printf '%s' "$body" | jq -r --arg n "$name" '.[] | select(.name == $n) | .id' | head -n1)"
      if [[ -n "$id" ]]; then
        tea labels update --repo "$(forge_owner_repo)" --id "$id" --name "$name" --color "$color" --description "$description"
      else
        tea labels create --repo "$(forge_owner_repo)" --name "$name" --color "$color" --description "$description"
      fi
      ;;
    *)
      echo "forge-cli: unknown FORGE_CLI '$FORGE_CLI'" >&2
      return 1
      ;;
  esac
}

# Internal: resolve a label name to its numeric id via the REST API.
#
# `tea issues edit --add-labels`/`--remove-labels` collapse whitespace out of
# the label spec before matching it against the repo's label names (verified
# live against Gitea 1.27.2 / tea 0.15.1, the fleet's own pinned version):
# "status: in-review" (the fleet's own naming - a colon then a space) never
# matches "status: in-review" the label, so the flag silently sends an empty
# `{"labels":[]}` write instead of failing - the exact shape of foreman#712's
# discovery. `tea labels ls`/`tea api` are unaffected, so every tea-backed
# label write below goes through the REST API by id instead of trusting that
# flag. Prints nothing and fails when the repo has no label of that name.
_forge_tea_label_id() {
  local name="$1" body id
  body="$(_forge_tea_api_get "/repos/$(forge_owner_repo)/labels")" || return 1
  id="$(printf '%s' "$body" | jq -r --arg n "$name" '.[] | select(.name == $n) | .id' | head -n1)"
  if [[ -z "$id" ]]; then
    echo "forge-cli: no label named '$name' on $(forge_owner_repo)" >&2
    return 1
  fi
  printf '%s\n' "$id"
}

# forge_issue_add_label <issue_number> <label>
forge_issue_add_label() {
  local n="$1" label="$2"
  _forge_number_ok "$n" || { echo "forge-cli: not an issue number: '$n'" >&2; return 1; }
  case "$FORGE_CLI" in
    gh)
      # The additive labels endpoint, never a set-labels write: POST adds the
      # one named label and leaves every other label on the issue untouched,
      # which is the claim protocol's requirement (CLAUDE.md, invariant 2).
      # `gh issue edit --add-label`, which this replaces, was GraphQL-backed.
      gh api --method POST "repos/$(forge_owner_repo)/issues/$n/labels" \
        -f "labels[]=$label" >/dev/null
      ;;
    tea)
      local id
      id="$(_forge_tea_label_id "$label")" || return 1
      _forge_tea_api_send POST "/repos/$(forge_owner_repo)/issues/$n/labels" \
        "{\"labels\":[$id]}" >/dev/null
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
  _forge_number_ok "$n" || { echo "forge-cli: not an issue number: '$n'" >&2; return 1; }
  case "$FORGE_CLI" in
    gh)
      # Deletes the one named label, the mirror of the additive add above.
      # The name is a path segment here, so it must be percent-encoded -
      # every `status:*` label carries a colon and a space. Removing a label
      # the issue does not carry is a 404, hence non-zero, the same failure
      # `gh issue edit --remove-label` gave (task-status.sh guards for it).
      gh api --method DELETE \
        "repos/$(forge_owner_repo)/issues/$n/labels/$(_forge_gh_uri_escape "$label")" >/dev/null
      ;;
    tea)
      local id
      id="$(_forge_tea_label_id "$label")" || return 1
      # Gitea's DELETE needs no body, and - unlike GitHub's - is idempotent:
      # removing a label the issue does not carry still answers 204, not
      # 404 (verified live), so this never needs task-status.sh's
      # already_settled rescue the way the gh branch above sometimes does.
      _forge_tea_api_send DELETE "/repos/$(forge_owner_repo)/issues/$n/labels/$id" "" >/dev/null
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
  _forge_number_ok "$n" || { echo "forge-cli: not an issue number: '$n'" >&2; return 1; }
  case "$FORGE_CLI" in
    gh)
      _forge_gh_comment_body "$body_file" \
        | _forge_gh_post_json_url "repos/$(forge_owner_repo)/issues/$n/comments"
      ;;
    tea)
      tea comments add "$n" --repo "$(forge_owner_repo)" --description "$(cat "$body_file")"
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
  _forge_number_ok "$n" || { echo "forge-cli: not an issue number: '$n'" >&2; return 1; }
  case "$FORGE_CLI" in
    gh)
      # `gh issue close` was GraphQL-backed; the REST state write is the same
      # act. Its only stdout was gh's own "closed issue #n" confirmation,
      # which nothing parses, so this prints nothing and reports through the
      # exit status alone.
      gh api --method PATCH "repos/$(forge_owner_repo)/issues/$n" \
        -f state=closed >/dev/null
      ;;
    tea)
      tea issues close "$n" --repo "$(forge_owner_repo)"
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
  _forge_number_ok "$n" || { echo "forge-cli: not an issue number: '$n'" >&2; return 1; }
  case "$FORGE_CLI" in
    gh)
      # Captured first rather than piped: a failed `gh api` would otherwise
      # hand the normalizer empty stdin, and jq would answer `null` and exit
      # 0 - the opposite of failing closed.
      local body
      body="$(gh api "repos/$(forge_owner_repo)/issues/$n")" || return 1
      printf '%s' "$body" | _forge_gh_issue_normalize
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

# ---------------------------------------------------------------------------
# Task relationships: the forge's native "parent" and "blocked by" links.
#
# task-create writes the authoritative record into the issue body's
# <!-- task-metadata --> block (`epic:` and `blocked-by:`) and then creates
# the forge's native link as a second write, on both forges, through the
# helpers below. The link is display state derived from the key - the
# daemon's board reads GitHub's native sub-issue parent (WorkTicket::parent)
# to group tasks under their epic, and a missing link is re-derivable from
# the key at any time - so a failed link must never cost the issue, and
# these helpers never create one.
#
# GitHub: sub-issues (`gh issue edit --parent`) and issue dependencies
# (`gh issue edit --add-blocked-by`); both flags shipped in gh 2.94.0.
# These three helpers are the gh calls in this file that still go through
# GraphQL, so they work from a worker or a laptop and not from inside a cloud
# session (see the header). Their capability check is not one of them: it
# reads `gh issue edit --help`, which is local text and no request at all.
# Only `task-create`
# and `task-breakdown` call them, and both are by-hand skills; nothing on
# `task-run`'s path reaches them. REST equivalents do exist
# (`POST/GET /issues/{n}/sub_issues`, `/issues/{n}/dependencies/blocked_by`,
# `GET /issues/{n}/parent`), but the write endpoints address issues by
# numeric id rather than number, so converting these means an extra read per
# write and a changed meaning for the capability check - deliberately left
# for its own change.
# Gitea: no sub-issue endpoint at any released version; both relationships
# are emulated with the one dependency endpoint,
#   POST /repos/{owner}/{repo}/issues/<n>/dependencies  {owner, repo, index}
# where "the issue in the URL depends on the issue in the body". For a
# blocker the task is the URL and the blocker the body; for the epic the
# epic is the URL and the task the body (so the epic cannot close while a
# task is open - the intended reading, and the one task-breakdown has
# always made). Read back, a task's `dependencies` are its blockers and its
# `blocks` holds its epic. `owner` and `repo` are required in the body even
# for a same-repository pair. The endpoint answers HTTP 423 when the
# repository has dependencies disabled (`internal_tracker.
# enable_issue_dependencies`), which forge_issue_relationships_supported
# reads first.
#
# Verified live on ycastonguay/foreman-scratch (2026-09-18, Gitea 1.27.2):
# both writes return 201; the child's read-back is
# {"parent":<epic>,"blocked_by":[<blocker>]}, the epic's `dependencies` are
# its tasks, and `/blocks` returns full Issue objects with `number` and
# `labels[].name` as _forge_tea_relationships_normalize reads them. The
# close gate is real: PATCH state=closed on a blocked task or on an epic
# with an open task answers HTTP 412, and closing in order (blocker, task,
# epic) succeeds.
# ---------------------------------------------------------------------------

# Internal: send a tea api request with a JSON body. Prints the response
# body and returns 0 only on a 2xx status - `tea api` exits 0 regardless
# (see _forge_tea_api_get).
_forge_tea_api_send() {
  local method="$1" api_path="$2" json="$3"
  local body_file err_file http_status body
  body_file="$(mktemp)"
  err_file="$(mktemp)"
  tea api --include -X "$method" -d "$json" "$api_path" >"$body_file" 2>"$err_file"
  http_status="$(_forge_tea_status_line <"$err_file")"
  body="$(cat "$body_file")"
  rm -f "$body_file" "$err_file"
  if ! _forge_http_status_ok "$http_status"; then
    echo "forge-cli: tea api $method $api_path failed: ${http_status:-no response}" >&2
    return 1
  fi
  printf '%s\n' "$body"
}

# Internal, pure: the JSON body of a Gitea dependency write for
# <owner/repo> naming issue <index>. jq only, no network.
_forge_tea_dependency_body() {
  local owner_repo="$1" index="$2"
  jq -c -n --arg o "${owner_repo%%/*}" --arg r "${owner_repo#*/}" --argjson i "$index" \
    '{owner: $o, repo: $r, index: $i}'
}

# Internal, pure: normalizes `gh issue view --json parent,blockedBy` (stdin)
# to the shape forge_issue_relationships documents. Recorded live on gh
# 2.100.0: `parent` is an object with `number` or null; `blockedBy` is a
# connection with `nodes[].number`.
_forge_gh_relationships_normalize() {
  jq -c '{parent: (.parent.number // null), blocked_by: ([.blockedBy.nodes[]?.number] | sort)}'
}

# Internal, pure: same normalization for Gitea, from one object (stdin)
# holding the two dependency listings, `{dependencies: [...], blocks: [...]}`
# (each an array of Gitea Issue objects, per the endpoint's swagger schema).
# A task's `dependencies` are its blockers; its epic is the `epic`-labelled
# issue among the ones it `blocks`. Anything else a task blocks (a task that
# named it as a blocker) is not its parent and is left out.
_forge_tea_relationships_normalize() {
  jq -c '{
    parent: ([.blocks[]? | select(any(.labels[]?; .name == "epic")) | .number] | sort | .[0] // null),
    blocked_by: ([.dependencies[]? | .number] | sort)
  }'
}

# forge_issue_relationships_supported
# Exit 0 when the forge can record native task relationships here: on
# GitHub, the installed `gh` has the `--parent` and `--add-blocked-by`
# flags on `gh issue edit` - the command the writers below actually run
# (they shipped in 2.94.0; checked by presence, never by comparing version
# strings, which do not sort as numbers); on Gitea, the repository has
# issue dependencies enabled. Non-zero means the links are *unavailable* -
# tooling absence, not a failed call - and a caller keeps the metadata keys
# and skips the writes.
forge_issue_relationships_supported() {
  case "$FORGE_CLI" in
    gh)
      local help
      help="$(gh issue edit --help 2>&1)" || return 1
      [[ "$help" == *"--parent"* && "$help" == *"--add-blocked-by"* ]]
      ;;
    tea)
      local body
      body="$(_forge_tea_api_get "/repos/$(forge_owner_repo)")" || return 1
      printf '%s' "$body" | jq -e '.internal_tracker.enable_issue_dependencies == true' >/dev/null
      ;;
    *)
      echo "forge-cli: unknown FORGE_CLI '$FORGE_CLI'" >&2
      return 1
      ;;
  esac
}

# forge_issue_add_blocker <task> <blocker>
# Records that <task> cannot start before <blocker>: GitHub's "blocked by"
# dependency, or the Gitea dependency with the task in the URL. One call
# per blocker. Non-zero when the link was not made; never touches the issue
# itself.
forge_issue_add_blocker() {
  local task="$1" blocker="$2"
  case "$FORGE_CLI" in
    gh)
      gh issue edit "$task" --add-blocked-by "$blocker" >/dev/null
      ;;
    tea)
      local owner_repo
      owner_repo="$(forge_owner_repo)" || return 1
      _forge_tea_api_send POST "/repos/$owner_repo/issues/$task/dependencies" \
        "$(_forge_tea_dependency_body "$owner_repo" "$blocker")" >/dev/null
      ;;
    *)
      echo "forge-cli: unknown FORGE_CLI '$FORGE_CLI'" >&2
      return 1
      ;;
  esac
}

# forge_issue_set_parent <task> <epic>
# Records <task> as a child of <epic>: GitHub's native sub-issue, or the
# Gitea dependency with the epic in the URL. Non-zero when the link was not
# made; never touches the issue itself.
forge_issue_set_parent() {
  local task="$1" epic="$2"
  case "$FORGE_CLI" in
    gh)
      gh issue edit "$task" --parent "$epic" >/dev/null
      ;;
    tea)
      local owner_repo
      owner_repo="$(forge_owner_repo)" || return 1
      _forge_tea_api_send POST "/repos/$owner_repo/issues/$epic/dependencies" \
        "$(_forge_tea_dependency_body "$owner_repo" "$task")" >/dev/null
      ;;
    *)
      echo "forge-cli: unknown FORGE_CLI '$FORGE_CLI'" >&2
      return 1
      ;;
  esac
}

# forge_issue_relationships <issue_number>
# Prints what the forge actually holds for the issue, one JSON object with
# identical keys on both forges:
#   {"parent": <epic number or null>, "blocked_by": [<n>, ...]}   (ascending)
# Non-zero (printing nothing) when it cannot be read - callers report the
# links as missing then, the conservative reading, rather than assuming
# a write that returned 0 took.
forge_issue_relationships() {
  local n="$1"
  _forge_number_ok "$n" || { echo "forge-cli: not an issue number: '$n'" >&2; return 1; }
  case "$FORGE_CLI" in
    gh)
      # Captured first rather than piped: with no pipefail a failed `gh`
      # would hand the normalizer empty stdin, which jq turns into a clean
      # "no relationships" object and exit 0 - the opposite of failing closed.
      local body
      body="$(gh issue view "$n" --json parent,blockedBy)" || return 1
      printf '%s' "$body" | _forge_gh_relationships_normalize
      ;;
    tea)
      local owner_repo deps blocks combined
      owner_repo="$(forge_owner_repo)" || return 1
      deps="$(_forge_tea_api_get_all "/repos/$owner_repo/issues/$n/dependencies")" || return 1
      blocks="$(_forge_tea_api_get_all "/repos/$owner_repo/issues/$n/blocks")" || return 1
      combined="$(jq -c -n --argjson d "$deps" --argjson b "$blocks" '{dependencies: $d, blocks: $b}')" || return 1
      printf '%s' "$combined" | _forge_tea_relationships_normalize
      ;;
    *)
      echo "forge-cli: unknown FORGE_CLI '$FORGE_CLI'" >&2
      return 1
      ;;
  esac
}

# Executed rather than sourced: `scripts/lib/forge-cli.sh <helper> [args...]`
# runs forge_detect_cli and then that one helper, exiting with its status.
# A daemon Claude turn (`claude -p`) cannot source this file - Claude Code
# refuses `source` as evaluating shell code, and no --allowedTools entry can
# grant it - so it calls the helpers this way instead, under foreman.yml's
# `Bash(scripts/lib/forge-cli.sh:*)` grant (foreman#680, foreman#682). Only
# the names below dispatch: forge_detect_cli runs implicitly, the
# underscore-prefixed internals are not an interface, and
# forge_release_download_asset belongs to the redeploy scripts alone.
_forge_cli_main() {
  local helper="${1:-}"
  case "$helper" in
    forge_owner_repo | forge_issue_ready_events | forge_issue_comments_json | \
      forge_repo_capability_check | forge_default_branch | forge_pr_url_for_branch | \
      forge_pr_create | forge_pr_comment | forge_repo_owner_is_org | \
      forge_repo_owner_login | forge_issue_author_login | forge_issue_labels | \
      forge_issue_list_by_label | forge_issue_ensure_label | forge_issue_add_label | \
      forge_issue_remove_label | forge_issue_comment | forge_issue_close | \
      forge_issue_fetch_json | forge_issue_relationships_supported | \
      forge_issue_add_blocker | forge_issue_set_parent | forge_issue_relationships)
      shift
      forge_detect_cli
      "$helper" "$@"
      ;;
    *)
      echo "forge-cli: usage: forge-cli.sh <forge_* helper> [args...]; '$helper' is not one" >&2
      return 2
      ;;
  esac
}

# Only a direct run dispatches; a sourcing shell (task-status.sh, the
# skills, the test file) just gets the functions. BASH_SOURCE is read
# through a default because zsh, which sources this file on the macOS
# seat, does not set it.
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  _forge_cli_main "$@"
  exit $?
fi
