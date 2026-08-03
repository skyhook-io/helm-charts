# Radar Hub Helm chart

This chart installs the Radar Cloud control plane for a self-hosted deployment.
See the [self-hosted install guide](https://radarhq.io/docs/cloud/self-hosted/install)
for the required values, production Postgres and TLS setup, and first-cluster
enrollment flow.

## Upgrading to 1.4.0

Chart 1.4.0 retains the Hub and Web 1.3.0 images introduced by chart 1.3.1 and
removes the `kubernetes.io/arch: amd64` scheduling default. The official images
support both `linux/amd64` and `linux/arm64`, so an unmodified installation can
now schedule on either architecture. An upgrade directly from chart 1.3.0 or
earlier also moves the default images from 1.2.2 to 1.3.0.

To pin an architecture, add only the architecture key under the component you
want to constrain. Helm deep-merges values maps, so the default Linux selector
is retained:

```yaml
hub:
  nodeSelector:
    kubernetes.io/arch: arm64
web:
  nodeSelector:
    kubernetes.io/arch: arm64
```

The migration init container uses the same Hub image as the application and
runs before each upgraded Hub pod starts. Database schema migration therefore
remains part of the normal rolling upgrade.
