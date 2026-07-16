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

For configuration options and in-cluster deployment guidance, see the [Radar Helm chart README](charts/radar/README.md) and the [in-cluster deployment docs](https://radarhq.io/docs/configuration/in-cluster).

### Install self-hosted Radar Cloud

The `radar-hub` chart deploys the self-hosted control plane and web app. It requires a public URL, Postgres, TLS, a cookie-sealing secret, and an authentication method. Follow the [self-hosted install guide](https://radarhq.io/docs/cloud/self-hosted/install) for the complete values and first-cluster flow.

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
