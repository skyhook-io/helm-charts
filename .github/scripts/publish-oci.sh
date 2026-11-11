#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_REPOSITORY:?}"
: "${GITHUB_SHA:?}"
: "${GITHUB_ACTOR:?}"
: "${GITHUB_TOKEN:?}"

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
mkdir -p "$work_dir/packages" "$work_dir/pulled" "$work_dir/registry" "$work_dir/source"

# Helm and Cosign both read Docker-compatible registry credentials.
export DOCKER_CONFIG="$work_dir/registry"
export HELM_REGISTRY_CONFIG="$DOCKER_CONFIG/config.json"

# Release assets survive a failed job; chart-releaser's local packages and
# changed_charts output do not. Reuse the published bytes on every attempt.
gh api --paginate "repos/${GITHUB_REPOSITORY}/releases?per_page=100" \
  --jq '.[] | select(.draft == false) | [.tag_name, .target_commitish] | @tsv' \
  > "$work_dir/releases.tsv"

while IFS=$'\t' read -r tag release_sha; do
  [[ "$release_sha" == "$GITHUB_SHA" ]] || continue
  [[ "$tag" =~ ^(radar-hub|radar|skyhook-connector)-[0-9][0-9A-Za-z.+-]*$ ]] || continue

  # target_commitish is only metadata when a tag already exists. Resolve the
  # actual tag, including annotated tags, before admitting its release asset.
  tag_sha=$(gh api "repos/${GITHUB_REPOSITORY}/commits/refs/tags/${tag}" --jq .sha)
  if [[ "$tag_sha" != "$GITHUB_SHA" ]]; then
    echo "::error::${tag} points to ${tag_sha}, not this run's commit ${GITHUB_SHA}"
    exit 1
  fi
  gh release download "$tag" --repo "$GITHUB_REPOSITORY" \
    --pattern "${tag}.tgz" --dir "$work_dir/packages"
done < "$work_dir/releases.tsv"

shopt -s nullglob
packages=("$work_dir/packages/"*.tgz)
if [[ ${#packages[@]} == 0 ]]; then
  echo "No published chart releases at ${GITHUB_SHA} to mirror."
  exit 0
fi

printf '%s' "$GITHUB_TOKEN" | helm registry login ghcr.io \
  --username "$GITHUB_ACTOR" --password-stdin

for pkg in "${packages[@]}"; do
  metadata=$(helm show chart "$pkg")
  name=$(awk '/^name:/ {print $2; exit}' <<< "$metadata")
  version=$(awk '/^version:/ {print $2; exit}' <<< "$metadata")
  case "$name" in
    radar-hub|radar|skyhook-connector) ;;
    *) echo "::error::Unsupported chart in $(basename "$pkg"): ${name}"; exit 1 ;;
  esac
  if [[ "$(basename "$pkg")" != "${name}-${version}.tgz" ]]; then
    echo "::error::Release asset $(basename "$pkg") does not match chart ${name}-${version}"
    exit 1
  fi

  if [[ "$name" == radar-hub ]]; then
    # A release asset can be replaced independently of its tag. Compare its
    # content with the checked-out chart; ignore only tar/gzip packaging metadata.
    # The original published archive remains the input to the OCI push.
    helm package charts/radar-hub --destination "$work_dir/source"
    python3 - "$pkg" "$work_dir/source/${name}-${version}.tgz" <<'PY'
import sys
import tarfile
from pathlib import PurePosixPath


def contents(path: str) -> dict[str, bytes]:
    result: dict[str, bytes] = {}
    with tarfile.open(path) as archive:
        for member in archive:
            name = PurePosixPath(member.name)
            if (not member.isfile() or member.name in result or name.is_absolute()
                    or ".." in name.parts or str(name) != member.name):
                raise ValueError("unsupported or duplicate archive member")
            stream = archive.extractfile(member)
            if stream is None:
                raise ValueError("unreadable archive member")
            with stream:
                result[member.name] = stream.read()
    return result


try:
    if contents(sys.argv[1]) != contents(sys.argv[2]):
        raise ValueError("archive content differs")
except (OSError, tarfile.TarError, ValueError):
    sys.exit("::error::Radar Hub release archive does not match the chart at this run's commit; refusing to sign")
PY
  fi

  image="ghcr.io/skyhook-io/charts/${name}"
  # Helm replaces SemVer build metadata's '+' with '_' in OCI tags.
  oci_tag=${version//+/_}
  output="$work_dir/helm-output.txt"
  if helm pull "oci://${image}" --version "$version" \
    --destination "$work_dir/pulled" > "$output" 2>&1; then
    cat "$output"
    echo "::notice::${name}-${version} already in GHCR OCI; keeping its digest"
    if [[ "$name" == radar-hub ]] && ! cmp -s "$pkg" "$work_dir/pulled/${name}-${version}.tgz"; then
      echo "::error::Existing ${name}-${version} OCI chart differs from its GitHub Release archive; refusing to sign"
      exit 1
    fi
  else
    # This is Helm 3.14's missing-manifest response. Auth, transport and other
    # lookup failures must not turn into a push over an existing version.
    if ! grep -Fxq "Error: ${image}:${oci_tag}: not found" "$output"; then
      cat "$output" >&2
      exit 1
    fi
    helm push "$pkg" oci://ghcr.io/skyhook-io/charts > "$output" 2>&1 || {
      cat "$output" >&2
      exit 1
    }
    cat "$output"
  fi

  digest=$(sed -n 's/^Digest: //p' "$output")
  if [[ ! "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "::error::Helm did not report exactly one valid digest for ${name}-${version}"
    exit 1
  fi

  if [[ "$name" == radar-hub ]]; then
    reference="${image}@${digest}"
    cosign sign --yes --oidc-provider=github-actions "$reference"
    cosign verify \
      --certificate-oidc-issuer https://token.actions.githubusercontent.com \
      --certificate-identity https://github.com/skyhook-io/helm-charts/.github/workflows/release.yml@refs/heads/main \
      "$reference"
  fi
done
