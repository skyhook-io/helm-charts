# Skyhook Helm Charts

Official Helm charts for [Radar](https://radarhq.io) and [Skyhook](https://skyhook.io).

## Charts

| Chart | Description |
|-------|-------------|
| [`radar`](charts/radar) | Modern Kubernetes visibility tool. Multi-cluster topology, image filesystem viewer, Helm and GitOps management, built-in MCP server. |
| [`radar-hub`](charts/radar-hub) | Radar Cloud control plane for self-hosted deployments. |
| [`skyhook-connector`](charts/skyhook-connector) | In-cluster agent for the Skyhook platform. |

## Usage

[Helm](https://helm.sh) must be installed to use these charts. See Helm's [documentation](https://helm.sh/docs) to get started.

Add the repo:

```bash
helm repo add skyhook https://skyhook-io.github.io/helm-charts
```

If you've already added the repo, refresh it to pick up new versions:

```bash
helm repo update
helm search repo skyhook
```

### Install Radar

```bash
helm install radar skyhook/radar
```

For configuration options and in-cluster deployment guidance, see the [Radar Helm chart README](charts/radar/README.md) and the [in-cluster deployment docs](https://radarhq.io/docs/configuration/in-cluster). For the self-hosted control plane, including how its chart version and `appVersion` relate, see the [Radar Hub Helm chart README](charts/radar-hub/README.md).

### Install self-hosted Radar Cloud

The `radar-hub` chart deploys the self-hosted control plane and web app. It requires a public URL, Postgres, TLS, a cookie-sealing secret, and an authentication method. Follow the [self-hosted install guide](https://radarhq.io/docs/cloud/self-hosted/install) for the complete values and first-cluster flow.

### Verify a Radar or Radar Hub OCI chart

New Radar and Radar Hub OCI releases use [Cosign](https://docs.sigstore.dev/cosign/system_config/installation/) keyless signatures from this repository's release workflow. Chart signing is supported for OCI only. Older versions may be unsigned; the classic Helm repository and `skyhook-connector` remain unsigned. Helm's `--verify` checks Helm provenance files, not these Cosign signatures.

Install Cosign v3.1.4 or later. Set `chart` to `radar` or `radar-hub` and `version` to the chart version you want, then pull and verify it:

```bash
chart=radar
version='<chart-version>'
(
set -euo pipefail
helm pull "oci://ghcr.io/skyhook-io/charts/${chart}" --version "$version" 2>&1 | tee "${chart}-pull.log"
digest="$(sed -n 's/^Digest: //p' "${chart}-pull.log")"
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity https://github.com/skyhook-io/helm-charts/.github/workflows/release.yml@refs/heads/main \
  "ghcr.io/skyhook-io/charts/${chart}@${digest}"
)
```

Continue only if verification succeeds. Install the exact archive you pulled. For Radar:

```bash
helm upgrade --install radar "./radar-${version}.tgz" -n radar --create-namespace
```

For Radar Hub, use the `values.yaml` prepared in the [self-hosted install guide](https://radarhq.io/docs/cloud/self-hosted/install):

```bash
helm install radar-hub "./radar-hub-${version}.tgz" --values values.yaml
```

An unsigned version or a signature from a different workflow or issuer fails verification.

### Install skyhook-connector

```bash
helm install skyhook-connector skyhook/skyhook-connector
```

### Uninstall

```bash
helm delete radar
helm delete skyhook-connector
```

## Links

- [Radar on GitHub](https://github.com/skyhook-io/radar)
- [Radar docs](https://radarhq.io/docs)
- [Discord community](https://radarhq.io/community/chat)
