# Radar Hub Helm Chart

Self-hosted Radar Cloud control plane — Go API, React web app, and Postgres
(bundled evaluation database, or bring your own).

> **Maintainers**: this directory is the canonical source for the `radar-hub`
> chart. Edit it here. The release job in
> [`skyhook-dev/radar-hub`](https://github.com/skyhook-dev/radar-hub) only
> rewrites `version` and `appVersion` in `Chart.yaml`; everything else is owned
> by this repository. This is the opposite of the sibling `radar` chart, whose
> directory here is overwritten wholesale on every Radar release.

## Installation

```bash
helm repo add skyhook https://skyhook-io.github.io/helm-charts
helm repo update skyhook
helm upgrade --install radar-hub skyhook/radar-hub -n radar-hub --create-namespace
```

Full setup, configuration and upgrade guides:
<https://radarhq.io/docs/cloud/self-hosted>

## Versioning

This chart carries **two independent version numbers**. They are not the same
number and they are not expected to match.

| Field | Means | Set by |
|---|---|---|
| `appVersion` | The Hub release installed — the image tag for both `radar-hub` and `radar-hub-web` | The release job, from the Hub's git tag |
| `version` | The chart's own version — templates, values, defaults | Patch: the release job. Minor and major: by hand, in a pull request here |

**Why they differ.** A chart-only fix — a template change, a new value, a
corrected default — ships without any new Hub images. It still needs a new chart
version, so the chart advances while `appVersion` stays put. Over time the two
numbers drift apart. This is the normal arrangement for Helm charts; Argo CD,
Bitnami and most large chart repositories work the same way.

How the numbers move:

| Change | `version` | `appVersion` |
|---|---|---|
| New Hub release | patch +1 | the new Hub version |
| Chart fix, no new images | patch +1, by hand | unchanged |
| New or renamed values | minor +1, by hand | unchanged |
| Removed or breaking values | major +1, by hand | unchanged |

**To find out which Hub version a chart installs**, read its `appVersion`:

```bash
helm show chart skyhook/radar-hub --version 1.5.1 | grep appVersion
```

**Pinning.** `image.hub.tag` and `image.web.tag` default to `appVersion` when
left empty. Set them only to stage a specific release, and always set both to
the same tag — a mismatched Hub and Web pair is not a tested combination.

## Values

See [`values.yaml`](values.yaml) for the full set, and
[`values.schema.json`](values.schema.json) for the enforced schema. Invalid
values are rejected at install time rather than surfacing as a broken pod.
