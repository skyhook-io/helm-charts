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

### Staging a chart change before the Hub release exists

Merging to `main` publishes: chart-releaser packages any chart whose version has
no matching tag. That is a problem when a chart change depends on a Hub build
that has not shipped yet — a published chart would offer a value its default
image ignores.

Give the chart a **prerelease version** instead:

```yaml
version: 1.7.0-rc.1     # staged, not offered to users
appVersion: "1.5.0"     # unchanged until the Hub release exists
```

Helm excludes prerelease versions from `helm install`, `helm upgrade` and
`helm search` unless `--devel` is passed or the exact version is named. So the
chart is published and reviewable, and an ordinary install still resolves to the
newest stable version:

```bash
helm search repo skyhook/radar-hub            # newest stable
helm search repo skyhook/radar-hub --devel    # includes staged versions
helm install radar-hub skyhook/radar-hub --version 1.7.0-rc.1   # opt in
```

The release job marks such versions as **Pre-release** on GitHub, so the Latest
badge stays on the newest stable release. That step must be on `main` before a
prerelease chart is merged; without it chart-releaser publishes the rc as an
ordinary release marked Latest.

**Promoting it.** When the Hub release lands, bump `version` to the stable
number and `appVersion` to that Hub version in the same change. Do not promote a
staged chart without moving `appVersion` — `image.hub.tag` defaults to it, so the
published chart would install a Hub that predates the feature the chart
configures.

## Values

See [`values.yaml`](values.yaml) for the full set, and
[`values.schema.json`](values.schema.json) for the enforced schema. Invalid
values are rejected at install time rather than surfacing as a broken pod.

## AI agent

Release prerequisite: this feature requires a Hub release with Anthropic provider
support (and, for `provider: vertex`, Vertex provider support) and a public `radar-hub-ai-agent-sandbox` image at the same version as
Hub. Chart maintainers must select that verified version in `appVersion` before
publishing this chart; merging chart changes publishes immediately, independently
of the Hub image pipeline. Hub `1.5.0` does not support this configuration.

Off by default. When enabled, each investigation turn runs as a short-lived
Kubernetes Job in its own namespace: the pod has no mounted ServiceAccount
token, reads the cluster only through the Hub's MCP tunnel, and reaches the
model through a sidecar broker that attaches the API key. The key is injected
only into the sidecar container, not the agent container in the same pod.

Pick a provider. `anthropic` talks to `api.anthropic.com` with an Anthropic API
key and works from any cloud; `bedrock` talks to `bedrock-runtime.<region>.amazonaws.com`
with an IAM service-specific credential for `bedrock.amazonaws.com`; `vertex`
talks to Claude on Google Cloud Vertex AI with a service-account key. Only the
selected provider's broker is mounted and only its credential is written, so
the other egress path does not exist in the pod.

With the bundled evaluation Postgres, set its password explicitly and the
chart derives the DSN the sandbox pod uses:

```bash
helm upgrade --install radar-hub skyhook/radar-hub \
  --set hub.agent.enabled=true \
  --set hub.agent.provider=anthropic \
  --set hub.agent.credentials.apiKey=sk-ant-… \
  --set postgres.bundled.auth.password=<password>
```

The explicit password is required because a generated one cannot be read back
at render time, so the chart refuses to derive a DSN that would not match the
database. On an existing install that already generated a password, pass that
same value back in from the `<fullname>-postgres` Secret (key `password`);
changing it does not rotate the password inside the database.

With an external database, set `credentials.podDSN` instead
(`--set hub.agent.credentials.podDSN='postgres://…'`). It is the DSN the
**sandbox pod** resolves, which is not the one the Hub uses — the pod runs in
another namespace, so a bare Service name will not resolve, and the chart
cannot read your Postgres Secret to rewrite the host.

For Vertex, the credential is a GCP service-account key in JSON rather than an
API key, so it goes in `credentials.serviceAccountJSON` (`apiKey` is refused
under this provider). `vertex.project` is required and has no default; the
account needs `roles/aiplatform.user` (or equivalent) on that project.

```bash
helm upgrade --install radar-hub skyhook/radar-hub \
  --set hub.agent.enabled=true \
  --set hub.agent.provider=vertex \
  --set hub.agent.vertex.project=my-gcp-project \
  --set hub.agent.vertex.location=global \
  --set-file hub.agent.credentials.serviceAccountJSON=./sa-key.json \
  --set postgres.bundled.auth.password=<password>
```

For a sealed-secrets or external-secrets workflow, skip the inline values and
set `hub.agent.credentials.existingSecret` to an object you manage. It must
live in the sandbox namespace and carry `HUB_AGENT_DB_DSN` plus
`HUB_AGENT_ANTHROPIC_API_KEY`, `HUB_AGENT_BEDROCK_API_KEY` or
`HUB_AGENT_VERTEX_CREDENTIALS` (the service-account key JSON), matching the
provider.

### AI analysis in alerts

`hub.agent.alertAnalysis=true` lets alert rules attach an AI analysis to the
issues they match. It is the fleet-wide kill switch only, and it needs the
engine above: setting it with `hub.agent.enabled=false` is refused at render
time rather than ignored. Three further gates live outside the chart — the
organization's owner must consent, an alert rule must opt in, and the process
must be running the alerts worker (on by default; a web-only replica running
with it disabled does no analysis).

```bash
helm upgrade --install radar-hub skyhook/radar-hub \
  --set hub.agent.enabled=true \
  --set hub.agent.alertAnalysis=true \
  --set hub.agent.provider=anthropic \
  --set hub.agent.credentials.apiKey=sk-ant-… \
  --set postgres.bundled.auth.password=<password>
```

Analyses draw on the same model account as the investigations you start by
hand, so turning it on adds provider spend that follows how often your rules
fire.

### The sandbox namespace

Jobs land in `<fullname>-sandbox` unless `hub.agent.sandbox.namespace` says
otherwise. `<fullname>` is the release name when it already contains
`radar-hub`, otherwise `<release>-radar-hub`: a release named `radar-hub` uses
`radar-hub-sandbox`, and a release named `rh` uses `rh-radar-hub-sandbox`. The default is release-scoped so two installs in one cluster get
separate sandboxes, and so a bare install cannot adopt an unrelated namespace
that already happens to exist. Helm will not install over a namespace it does
not own, so a name collision fails the install rather than quietly taking it
over — set `hub.agent.sandbox.create=false` to run in a namespace you
already manage, and the Role, RoleBinding, Secret and NetworkPolicy are still
rendered into it.

The NetworkPolicy allows DNS, outbound HTTPS on port 443, the Hub, and Postgres.
The HTTPS rule is not restricted to model-provider destinations; tighter
destination control requires an egress proxy or CNI-specific policy.
**Enforcement is CNI-dependent** — kindnet ignores
NetworkPolicy entirely, so on such a cluster this is documentation rather than a
control. Use `hub.agent.sandbox.networkPolicy.extraEgress` for a database on
a non-standard port, an egress proxy, or a private model endpoint.

### Private image mirrors

`image.agentSandbox.repository` can select a mirror, but the chart's top-level
`imagePullSecrets` applies only to its static workloads, **not** the sandbox Jobs.
Those Jobs use the `default` ServiceAccount in the sandbox namespace. For a
private mirror, pre-provision that namespace and its registry pull Secret, attach
the pull Secret to its `default` ServiceAccount, and set
`hub.agent.sandbox.create=false`. The pull Secret must exist in the sandbox
namespace; a Secret in the Hub namespace cannot be referenced across namespaces.
Node-level registry authentication is another option. No Kubernetes API token is
mounted in the sandbox pods.
