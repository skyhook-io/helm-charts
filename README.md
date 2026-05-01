# Skyhook Helm Charts

Official Helm charts for [Radar](https://radarhq.io) and [Skyhook](https://skyhook.io).

## Charts

| Chart | Description |
|-------|-------------|
| [`radar`](charts/radar) | Modern Kubernetes visibility tool. Multi-cluster topology, image filesystem viewer, Helm and GitOps management, built-in MCP server. |
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
