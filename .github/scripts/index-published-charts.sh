#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_REPOSITORY:?}"
: "${GITHUB_SHA:?}"

shopt -s nullglob
packages=(.cr-release-packages/*.tgz)
[[ ${#packages[@]} -gt 0 ]] || exit 0

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
for pkg in "${packages[@]}"; do
  tag=$(basename "$pkg" .tgz)
  tag_sha=$(gh api "repos/${GITHUB_REPOSITORY}/commits/refs/tags/${tag}" --jq .sha)
  if [[ "$tag_sha" != "$GITHUB_SHA" ]]; then
    echo "::error::${tag} already belongs to a different commit; bump the chart version before publishing"
    exit 1
  fi
  # Retries can repackage the same chart with different tar/gzip timestamps.
  # Index the original uploaded archive, rather than the new local package.
  gh release download "$tag" --repo "$GITHUB_REPOSITORY" \
    --pattern "$(basename "$pkg")" --dir "$work_dir"
  mv "$work_dir/$(basename "$pkg")" "$pkg"
done

cr index --owner "${GITHUB_REPOSITORY%/*}" \
  --git-repo "${GITHUB_REPOSITORY#*/}" --push
