#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

if (($# != 2)); then
  printf 'usage: build-package.sh <package-directory> <artifact-directory>\n' >&2
  exit 2
fi

package_path="$1"
artifact_path="$2"
repo_root="$(git rev-parse --show-toplevel)"

[[ "$package_path" =~ ^[A-Za-z0-9@._+-]+$ ]] || die "unsafe package directory: $package_path"
[[ -f "$repo_root/$package_path/PKGBUILD" ]] || die "missing PKGBUILD: $package_path"

package_dir="$(realpath "$repo_root/$package_path")"
artifact_dir="$(realpath -m "$artifact_path")"
[[ "$package_dir" == "$repo_root/"* ]] || die 'package directory escaped the repository'

install -d "$artifact_dir"
find "$artifact_dir" -maxdepth 1 -type f \
  \( -name '*.pkg.tar.*' -o -name 'manifest-*.json' \) -delete

cd "$package_dir"

mapfile -t valid_pgp_keys < <(
  makepkg --printsrcinfo |
    awk '$1 == "validpgpkeys" && $2 == "=" { print $3 }' |
    LC_ALL=C sort -u
)

for fingerprint in "${valid_pgp_keys[@]}"; do
  [[ "$fingerprint" =~ ^[0-9A-F]{40}$ ]] ||
    die "invalid PGP fingerprint in PKGBUILD: $fingerprint"
  bundled_key="keys/pgp/$fingerprint.asc"
  if [[ -f "$bundled_key" ]]; then
    gpg --batch --import "$bundled_key"
  fi
  if ! gpg --batch --list-keys "$fingerprint" >/dev/null 2>&1; then
    gpg --batch --keyserver hkps://keyserver.ubuntu.com --recv-keys "$fingerprint"
  fi
done

export PKGDEST="$artifact_dir"
makepkg --syncdeps --noconfirm --cleanbuild

mapfile -t expected_files < <(
  while IFS= read -r package_file; do
    basename "$package_file"
  done < <(makepkg --packagelist) | LC_ALL=C sort -u
)
((${#expected_files[@]} > 0)) || die 'makepkg did not declare any package outputs'

mapfile -t actual_files < <(
  find "$artifact_dir" -maxdepth 1 -type f -name '*.pkg.tar.*' ! -name '*.sig' -printf '%f\n' |
    LC_ALL=C sort -u
)

((${#actual_files[@]} > 0)) || die 'makepkg produced no package archives'

if [[ "$(printf '%s\n' "${expected_files[@]}")" != "$(printf '%s\n' "${actual_files[@]}")" ]]; then
  {
    printf 'error: package outputs did not match makepkg --packagelist\n'
    printf 'expected:\n'
    printf '  %s\n' "${expected_files[@]}"
    printf 'actual:\n'
    printf '  %s\n' "${actual_files[@]}"
  } >&2
  exit 1
fi

# GitHub artifacts reject ':'. The package epoch remains intact in .PKGINFO.
normalized_files=()
for filename in "${actual_files[@]}"; do
  normalized_filename="${filename/:/_}"
  if [[ "$normalized_filename" != "$filename" ]]; then
    [[ ! -e "$artifact_dir/$normalized_filename" ]] ||
      die "normalized package filename already exists: $normalized_filename"
    mv -- "$artifact_dir/$filename" "$artifact_dir/$normalized_filename"
  fi
  normalized_files+=("$normalized_filename")
done
actual_files=("${normalized_files[@]}")

manifest="$artifact_dir/manifest-$package_path.json"
filenames="$(jq -cn --args '$ARGS.positional' "${actual_files[@]}")"
jq -n \
  --arg package_base "$package_path" \
  --argjson filenames "$filenames" \
  '{
    schema: 1,
    package_base: $package_base,
    filenames: $filenames
  }' >"$manifest"

jq -e '.filenames | length > 0' "$manifest" >/dev/null
printf 'Built and validated %s (%s output file(s)).\n' "$package_path" "${#actual_files[@]}"
