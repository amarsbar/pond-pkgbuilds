#!/usr/bin/env bash
set -euo pipefail

readonly upstream_repository="CachyOS/CachyOS-PKGBUILDS"
readonly package_map=".github/cachyos-packages.tsv"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

valid_path() {
  [[ "$1" =~ ^[A-Za-z0-9@._+-]+(/[A-Za-z0-9@._+-]+)*$ ]]
}

last_upstream_commit() {
  local pond_path="$1"
  local pond_commit
  local upstream_commit

  while IFS= read -r pond_commit; do
    upstream_commit="$(
      git show -s --format=%B "$pond_commit" |
        git interpret-trailers --parse |
        sed -n 's/^Upstream-Commit: //p' |
        tail -n1
    )"
    if [[ "$upstream_commit" =~ ^[0-9a-f]{40}$ ]]; then
      printf '%s\n' "$upstream_commit"
      return 0
    fi
  done < <(git rev-list "origin/$branch" -- "$pond_path")

  git merge-base "origin/$branch" "$upstream_ref"
}

mapped_tree() {
  local upstream_commit="$1"
  local upstream_path="$2"
  local pond_path="$3"
  local index_file
  local tree

  index_file="$(mktemp)"
  rm -f "$index_file"
  GIT_INDEX_FILE="$index_file" git read-tree HEAD
  GIT_INDEX_FILE="$index_file" git rm -r --cached --ignore-unmatch -- "$pond_path" \
    >/dev/null

  if git cat-file -e "$upstream_commit:$upstream_path" 2>/dev/null; then
    GIT_INDEX_FILE="$index_file" \
      git read-tree --prefix="$pond_path/" "$upstream_commit:$upstream_path"
  fi

  tree="$(GIT_INDEX_FILE="$index_file" git write-tree)"
  rm -f "$index_file"
  printf '%s\n' "$tree"
}

apply_upstream_commit() {
  local upstream_commit="$1"
  local upstream_path="$2"
  local pond_path="$3"
  local parent
  local base_tree
  local incoming_tree
  local base_commit
  local incoming_commit
  local merge_output
  local merged_tree
  local upstream_subject
  local commit_subject
  local commit_body
  local upstream_pr_number
  local merged_by

  parent="$(git rev-parse "$upstream_commit^1")"
  base_tree="$(mapped_tree "$parent" "$upstream_path" "$pond_path")"
  incoming_tree="$(mapped_tree "$upstream_commit" "$upstream_path" "$pond_path")"
  base_commit="$(printf 'base\n' | git commit-tree "$base_tree")"
  incoming_commit="$(printf 'incoming\n' | git commit-tree "$incoming_tree")"

  if ! merge_output="$(
    git merge-tree \
      --write-tree \
      --messages \
      --merge-base="$base_commit" \
      HEAD \
      "$incoming_commit"
  )"; then
    printf '%s\n' "$merge_output" >&2
    return 1
  fi

  merged_tree="${merge_output%%$'\n'*}"
  [[ "$merged_tree" =~ ^[0-9a-f]{40,64}$ ]] || return 1
  git read-tree --reset -u "$merged_tree"

  upstream_subject="$(git show -s --format=%s "$upstream_commit")"
  commit_subject="$(sed -E 's/ \(#[0-9]+\)$//' <<<"$upstream_subject")"
  commit_body="Upstream-Repository: $upstream_repository
Upstream-Commit: $upstream_commit"

  if [[ "$upstream_subject" =~ \(\#([0-9]+)\)$ ]]; then
    upstream_pr_number="${BASH_REMATCH[1]}"
    commit_body+=$'\n'"Upstream-PR: https://redirect.github.com/$upstream_repository/pull/$upstream_pr_number"
    merged_by="$(
      gh api "repos/$upstream_repository/pulls/$upstream_pr_number" \
        --jq '.merged_by.login // empty' 2>/dev/null || true
    )"
    [[ -z "$merged_by" ]] || commit_body+=$'\n'"Upstream-Merged-By: $merged_by"
  fi

  git commit --quiet --allow-empty \
    -m "$commit_subject" -m "$commit_body"

  printf 'Applied %s to %s as %s\n' \
    "$upstream_commit" "$pond_path" "$(git rev-parse HEAD)"
}

sync_package() {
  local upstream_path="$1"
  local pond_path="$2"
  local cursor
  local branch_name
  local upstream_commit
  local pr_number
  local body_file
  local upstream_commits

  cursor="$(last_upstream_commit "$pond_path")"
  git cat-file -e "$cursor^{commit}" 2>/dev/null || {
    printf 'unknown upstream cursor for %s: %s\n' "$pond_path" "$cursor" >&2
    return 1
  }
  git merge-base --is-ancestor "$cursor" "$upstream_ref" || {
    printf 'upstream cursor for %s is no longer reachable: %s\n' \
      "$pond_path" "$cursor" >&2
    return 1
  }

  if git diff --quiet "$cursor" "$upstream_ref" -- "$upstream_path"; then
    printf '%s is current at %s.\n' "$pond_path" "$cursor"
    return 0
  fi

  branch_name="bot/sync/${pond_path//\//-}"
  git check-ref-format --branch "$branch_name" >/dev/null
  git checkout --quiet -B "$branch_name" "origin/$branch"

  mapfile -t upstream_commits < <(
    git rev-list --reverse --first-parent \
      "$cursor..$upstream_ref" -- "$upstream_path"
  )

  for upstream_commit in "${upstream_commits[@]}"; do
    apply_upstream_commit "$upstream_commit" "$upstream_path" "$pond_path" || {
      printf 'unable to merge %s into %s\n' "$upstream_commit" "$pond_path" >&2
      return 1
    }
  done

  if git diff --quiet "origin/$branch" HEAD; then
    printf '%s has no resulting Pond changes.\n' "$pond_path"
    return 0
  fi

  git fetch --no-tags origin \
    "+refs/heads/$branch_name:refs/remotes/origin/$branch_name" \
    2>/dev/null || true
  git push --force-with-lease origin "HEAD:refs/heads/$branch_name"

  body_file="$(mktemp)"
  {
    printf 'Automated CachyOS package synchronization.\n\n'
    printf -- '- Upstream path: `%s`\n' "$upstream_path"
    printf -- '- Pond path: `%s`\n' "$pond_path"
    printf -- '- Previous upstream commit: `%s`\n' "$cursor"
    printf -- '- Current upstream commit: `%s`\n' "$(git rev-parse "$upstream_ref")"
  } >"$body_file"

  pr_number="$(
    gh pr list \
      --base "$branch" \
      --head "$branch_name" \
      --state open \
      --json number \
      --jq '.[0].number // empty'
  )"

  if [[ -n "$pr_number" ]]; then
    gh pr edit "$pr_number" \
      --title "$pond_path: sync CachyOS updates" \
      --body-file "$body_file"
  else
    gh pr create \
      --base "$branch" \
      --head "$branch_name" \
      --title "$pond_path: sync CachyOS updates" \
      --body-file "$body_file"
  fi

  rm -f "$body_file"
}

if (($# != 1)); then
  printf 'usage: sync-upstream.sh <upstream-master-ref>\n' >&2
  exit 2
fi

upstream_ref="$1"
branch="${POND_BRANCH:-main}"

[[ -n "${GH_TOKEN:-}" ]] || die 'GH_TOKEN is required'
[[ -f "$package_map" ]] || die "missing package map: $package_map"
git cat-file -e "$upstream_ref^{commit}" 2>/dev/null || \
  die "unknown upstream ref: $upstream_ref"

git fetch --no-tags origin "$branch"
git checkout --quiet -B "$branch" "origin/$branch"
[[ -z "$(git status --porcelain)" ]] || die 'Pond checkout is not clean'

git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git config commit.gpgSign false

upstream_paths=()
pond_paths=()
declare -A seen_upstream=()
declare -A seen_pond=()

while IFS=$'\t' read -r upstream_path pond_path; do
  [[ -n "$upstream_path" && -n "$pond_path" ]] || \
    die 'package map contains an incomplete row'
  valid_path "$upstream_path" || die "unsafe upstream path: $upstream_path"
  valid_path "$pond_path" || die "unsafe Pond path: $pond_path"
  [[ -z "${seen_upstream[$upstream_path]:-}" ]] || \
    die "duplicate upstream path: $upstream_path"
  [[ -z "${seen_pond[$pond_path]:-}" ]] || \
    die "duplicate Pond path: $pond_path"
  git cat-file -e "$upstream_ref:$upstream_path" 2>/dev/null || \
    die "upstream package path does not exist: $upstream_path"
  [[ -e "$pond_path" ]] || die "Pond package path does not exist: $pond_path"

  seen_upstream["$upstream_path"]=1
  seen_pond["$pond_path"]=1
  upstream_paths+=("$upstream_path")
  pond_paths+=("$pond_path")
done <"$package_map"

failures=()
for index in "${!upstream_paths[@]}"; do
  git checkout --quiet -B "$branch" "origin/$branch"
  if ! sync_package "${upstream_paths[$index]}" "${pond_paths[$index]}"; then
    failures+=("${pond_paths[$index]}")
  fi
done

git checkout --quiet -B "$branch" "origin/$branch"

if (("${#failures[@]}" > 0)); then
  printf 'error: failed to synchronize: %s\n' "${failures[*]}" >&2
  exit 1
fi

printf 'Checked %s CachyOS package group(s).\n' "${#upstream_paths[@]}"
