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

## AI agent

Release prerequisite: this feature requires a Hub release with Anthropic provider
support and a public `radar-hub-ai-agent-sandbox` image at the same version as
Hub. Chart maintainers must select that verified version in `appVersion` before
publishing this chart; merging chart changes publishes immediately, independently
of the Hub image pipeline. Hub `1.5.0` does not support this configuration.

Off by default. When enabled, each investigation turn runs as a short-lived
Kubernetes Job in its own namespace: the pod has no mounted ServiceAccount
token, reads the cluster only through the Hub's MCP tunnel, and reaches the
model through a sidecar broker that attaches the API key — the pod itself never
holds it.

Pick a provider. `anthropic` talks to `api.anthropic.com` with an Anthropic API
key and works from any cloud; `bedrock` talks to `bedrock-runtime.<region>.amazonaws.com`
with an IAM service-specific credential for `bedrock.amazonaws.com`. Only the
selected provider's broker is mounted and only its credential is written, so
the other egress path does not exist in the pod.

```bash
helm upgrade --install radar-hub skyhook/radar-hub \
  --set hub.aiAgent.enabled=true \
  --set hub.aiAgent.provider=anthropic \
  --set hub.aiAgent.credentials.apiKey=sk-ant-… \
  --set hub.aiAgent.credentials.podDSN='postgres://…'
```

`credentials.podDSN` is the DSN the **sandbox pod** resolves, which is not the
one the Hub uses — the pod runs in another namespace, so a bare Service name
will not resolve. It can be omitted only with the bundled evaluation Postgres,
and then only when `postgres.bundled.auth.password` is set explicitly: a
generated password cannot be read back at render time, so the chart refuses to
derive a DSN that would not match the database.

For a sealed-secrets or external-secrets workflow, skip both inline values and
set `hub.aiAgent.credentials.existingSecret` to an object you manage. It must
live in the sandbox namespace and carry `HUB_AGENT_DB_DSN` plus
`HUB_AGENT_ANTHROPIC_API_KEY` or `HUB_AGENT_BEDROCK_API_KEY`, matching the
provider.

### The sandbox namespace

Jobs land in `<release>-radar-hub-sandbox` unless `hub.aiAgent.sandbox.namespace`
says otherwise. The default is release-scoped so two installs in one cluster get
separate sandboxes, and so a bare install cannot adopt an unrelated namespace
that already happens to exist. Helm will not install over a namespace it does
not own, so a name collision fails the install rather than quietly taking it
over — set `hub.aiAgent.sandbox.create=false` to run in a namespace you
already manage, and the Role, RoleBinding, Secret and NetworkPolicy are still
rendered into it.

The NetworkPolicy restricts the turn pods to DNS, the model endpoint over 443,
the Hub, and Postgres. **Enforcement is CNI-dependent** — kindnet ignores
NetworkPolicy entirely, so on such a cluster this is documentation rather than a
control. Use `hub.aiAgent.sandbox.networkPolicy.extraEgress` for a database on
a non-standard port, an egress proxy, or a private model endpoint.

### Private image mirrors

`image.aiAgentSandbox.repository` can select a mirror, but the chart's top-level
`imagePullSecrets` applies only to its static workloads, **not** the sandbox Jobs.
Those Jobs use the `default` ServiceAccount in the sandbox namespace. For a
private mirror, pre-provision that namespace and its registry pull Secret, attach
the pull Secret to its `default` ServiceAccount, and set
`hub.aiAgent.sandbox.create=false`. The pull Secret must exist in the sandbox
namespace; a Secret in the Hub namespace cannot be referenced across namespaces.
Node-level registry authentication is another option. No Kubernetes API token is
mounted in the sandbox pods.
