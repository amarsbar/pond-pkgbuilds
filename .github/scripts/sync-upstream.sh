#!/usr/bin/env bash
set -euo pipefail

readonly upstream_repository="CachyOS/cachyos-aur-derived"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

if (($# != 1)); then
  printf 'usage: sync-upstream.sh <upstream-master-ref>\n' >&2
  exit 2
fi

upstream_ref="$1"
branch="${POND_BRANCH:-main}"

[[ -n "${GH_TOKEN:-}" ]] || die 'GH_TOKEN is required'
git cat-file -e "$upstream_ref^{commit}" 2>/dev/null || die "unknown upstream ref: $upstream_ref"

last_upstream_commit() {
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
  done < <(git rev-list HEAD)

  die 'no Upstream-Commit trailer found in Pond history'
}

dispatch_build() {
  local package_path="$1"
  local attempt

  for attempt in 1 2 3 4 5; do
    if gh workflow run build.yml \
      --ref "$branch" \
      -f package_path="$package_path"; then
      return 0
    fi
    sleep "$((attempt * 2))"
  done

  die "unable to dispatch the build for $package_path"
}

git fetch --no-tags origin "$branch"
git checkout -B "$branch" "origin/$branch"
[[ -z "$(git status --porcelain)" ]] || die 'Pond checkout is not clean'

mapfile -t pond_packages <.github/pond-packages.txt
pond_excludes=()
for package_path in "${pond_packages[@]}"; do
  pond_excludes+=(":(exclude)$package_path" ":(exclude)$package_path/**")
done

cursor="$(last_upstream_commit)"
git cat-file -e "$cursor^{commit}" 2>/dev/null || die "unknown recorded upstream commit: $cursor"
git merge-base --is-ancestor "$cursor" "$upstream_ref" ||
  die 'recorded upstream commit is no longer reachable from CachyOS master'

git diff --quiet HEAD "$cursor" -- . \
  ':(exclude).github' ':(exclude).github/**' \
  "${pond_excludes[@]}" ||
  die 'Pond content has drifted from its recorded CachyOS commit'

git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git config commit.gpgSign false

declare -A changed_packages=()
mapfile -t upstream_commits < <(git rev-list --reverse --first-parent "$cursor..$upstream_ref")

for upstream_commit in "${upstream_commits[@]}"; do
  parent="$(git rev-parse "$upstream_commit^1")"
  patch_file="$(mktemp)"
  trap 'rm -f "$patch_file"' EXIT

  git diff --binary --full-index "$parent" "$upstream_commit" -- . \
    ':(exclude).github' ':(exclude).github/**' \
    "${pond_excludes[@]}" >"$patch_file"

  if [[ ! -s "$patch_file" ]]; then
    rm -f "$patch_file"
    trap - EXIT
    continue
  fi

  while IFS= read -r -d '' changed_file; do
    [[ "$changed_file" == ".github" || "$changed_file" == .github/* ]] && continue
    top_path="${changed_file%%/*}"

    if [[ ! "$top_path" =~ ^[A-Za-z0-9@._+-]+$ ]]; then
      printf 'warning: not dispatching a build for unsupported top-level path: %q\n' \
        "$top_path" >&2
      continue
    fi

    if git cat-file -e "$upstream_commit:$top_path/PKGBUILD" 2>/dev/null; then
      changed_packages["$top_path"]=1
    fi
  done < <(git diff --name-only -z "$parent" "$upstream_commit" -- . \
    ':(exclude).github' ':(exclude).github/**' \
    "${pond_excludes[@]}")

  git apply --index "$patch_file"
  git diff --cached --quiet -- .github || die 'upstream patch changed Pond-owned .github content'

  upstream_subject="$(git show -s --format=%s "$upstream_commit")"
  commit_subject="$(sed -E 's/ \(#[0-9]+\)$//' <<<"$upstream_subject")"
  commit_body="Upstream-Repository: $upstream_repository
Upstream-Commit: $upstream_commit"

  if [[ "$upstream_subject" =~ \(\#([0-9]+)\)$ ]]; then
    upstream_pr_number="${BASH_REMATCH[1]}"
    commit_body+=$'\n'"Upstream-PR: https://redirect.github.com/$upstream_repository/pull/$upstream_pr_number"
    merged_by="$(gh api "repos/$upstream_repository/pulls/$upstream_pr_number" --jq '.merged_by.login // empty' 2>/dev/null || true)"
    [[ -z "$merged_by" ]] || commit_body+=$'\n'"Upstream-Merged-By: $merged_by"
  fi

  git commit --quiet -m "$commit_subject" -m "$commit_body"
  printf 'Copied %s as %s\n' "$upstream_commit" "$(git rev-parse HEAD)"

  rm -f "$patch_file"
  trap - EXIT
done

git diff --quiet HEAD "$upstream_ref" -- . \
  ':(exclude).github' ':(exclude).github/**' \
  "${pond_excludes[@]}" ||
  die 'local Pond main does not match CachyOS after synchronization'

if [[ "$(git rev-parse HEAD)" != "$(git rev-parse "origin/$branch")" ]]; then
  git push origin "HEAD:refs/heads/$branch"
fi

while IFS= read -r package_path; do
  [[ -f "$package_path/PKGBUILD" ]] || continue
  dispatch_build "$package_path"
done < <(printf '%s\n' "${!changed_packages[@]}" | LC_ALL=C sort)

printf 'Pond is synchronized with CachyOS at %s.\n' "$(git rev-parse "$upstream_ref")"
