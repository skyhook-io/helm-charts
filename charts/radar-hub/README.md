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

## Joining clusters with enrollment keys

Radar agents join the hub with an enrollment key.

- **Create keys in the hub.** An owner opens Settings > Enrollment keys, creates a key, and gives it to the cluster installs that should use it.
- **Set a key in config for automation.** On a self-hosted hub you can also set an install key when you install the chart, for automation that installs Radar before anyone has signed in. Put it in `enrollment.key` (`rhe_` followed by 43 characters), or keep it in a Secret you manage and name it in `enrollment.existingSecret` (the Secret key defaults to `key`, change it with `enrollment.existingSecretKey`). Set only one of the two. Set `enrollment.trustByDefault=true` if a cluster that joins with this key should start out trusted (default `false`). The hub reads it from its config each time a cluster joins. Keys created in the hub have their own setting. Set `enrollment.approval=manual` if an owner should approve each new cluster that joins with this key on the Clusters page (default `auto`: clusters join right away). The hub reads the key at startup, so restart the hub Deployment after you change it.
- **A key is a password.** Every cluster that uses it can join. Keep it out of shared chats and public repos.
- **If a key leaks**, delete or replace it in the hub (or change the value in config and restart the hub), set the new key on every cluster that uses it, and restart Radar there.
- **Removed clusters stay out.** A cluster an owner removes does not come back by enrolling again, even with a valid key. An owner has to let it back in.

### Customer-owned public keys

Public-key enrollment lets you generate the enrollment credential yourself. Hub
receives only an Ed25519 public key. Each Radar keeps the private key in a
Kubernetes Secret and signs a fresh enrollment challenge. The private key is
never sent to Hub. Customer keys remain valid until revoked; a signed proof is
single-use and expires after 60 seconds.

Use Hub, web and Radar builds that include public-key enrollment. This chart's
default image version is not a statement that it supports the feature. Set
`image.hub.tag` and `image.web.tag` explicitly to supporting builds. The chart
requires an explicit Hub tag before activation, but cannot verify the contents
of an arbitrary image tag.

The Radar agent chart and image must also include signing support. The planned
first candidate is **1.20.3**, which is not published yet. Wait for a supporting
release before using the published Radar chart for this mode, or use a tested
development chart and image that include the implementation.

Keep `enrollment.publicKeyEnabled: false` while upgrading Hub replicas. After
every replica runs the supporting build, set it to `true` and complete that
rollout before configuring agents. This also makes **Register public key**
available under Settings > Enrollment keys. Shared-secret enrollment keeps
working during the upgrade. Public-key enrollment uses the existing shared
`hub.cookiePassword`; it adds no operator secret. All replicas need the same
cookie password. Rotating it invalidates outstanding challenges, which agents
retry automatically.

For an organization that already exists, register the public key in Settings >
Enrollment keys and follow its install instructions. Those instructions include
the intended organization ID. Radar signs that ID with the request, so
registering the same public key in a different organization cannot redirect
enrollment.

#### Configure an install public key before first sign-in

1. Generate the pair locally with a supporting Radar CLI:

   ```sh
   radar cloud enrollment-keygen --out radar-enrollment.key
   ```

   This writes the private file and `radar-enrollment.key.pub`. The command
   refuses to overwrite an existing file. Keep the private file out of Git,
   Helm values and workspace configuration. OpenSSL 3 can generate the same
   PKCS#8/SPKI PEM pair; the OpenSSL bundled with some operating systems cannot
   generate Ed25519 keys.

2. Put the required Hub settings and explicit supporting image tags in
   `hub-values.yaml`. Enable public-key enrollment and choose the policy for
   this install key:

   ```yaml
   enrollment:
     publicKeyEnabled: true
     approval: manual
     trustByDefault: false
   ```

   Install with the public file only:

   ```sh
   helm upgrade --install radar-hub skyhook/radar-hub \
     -n radar-hub --create-namespace -f hub-values.yaml \
     --set-file enrollment.publicKey=radar-enrollment.key.pub
   ```

   `enrollment.publicKey` accepts one Ed25519 `PUBLIC KEY` PEM block. It
   conflicts with `enrollment.key` and `enrollment.existingSecret`. The Hub
   receives it as public configuration; the private file is never mounted in
   the Hub. Changing the install public key requires a Hub rollout.

3. Provision the private file in the namespace of each Radar agent. For an
   agent installed in namespace `radar`, use a separate private-key Secret.
   When migrating, keep the old enrollment Secret until the new agents
   and their access are verified:

   ```sh
   kubectl -n radar create secret generic radar-hub-enrollment-private \
     --from-file=private-key=radar-enrollment.key \
     --dry-run=client -o yaml | kubectl apply -f -
   ```

   Configure that agent with the Hub's reachable HTTPS address and:

   ```yaml
   cloud:
     enabled: true
     hubURL: https://hub.example.com
     enrollment:
       organization: self-hosted
       publicKey:
         existingSecret: radar-hub-enrollment-private
         existingSecretKey: private-key
   ```

   The reserved `self-hosted` target works only with this Hub's configured
   install public key. App-created keys use the actual organization ID from
   their install instructions. Do not set a cloud token or bearer enrollment
   key alongside public-key settings.

Agents may start before anyone signs in. They wait while Hub has no
organization, then join its singleton organization after first sign-in. With
`approval: manual`, new clusters wait for an owner to approve them. Approval
also marks the cluster trusted. `trustByDefault` applies to new clusters
admitted automatically.

#### TLS, aliases and GitOps

The agent verifies Hub's TLS certificate. For a private or self-signed Hub,
give Radar the certificate through `cloud.caBundle`; do not disable TLS
verification. The existing setup page supplies the public CA bundle when the
Hub chart manages that certificate.

The Hub's public origin is accepted by default. If agents dial an additional
address, add its exact origin to `enrollment.allowedOrigins`:

```yaml
enrollment:
  allowedOrigins:
    - https://radar.internal.example
```

Each address needs a matching trusted certificate. Origins cannot contain
credentials, paths, queries, fragments or wildcards. Plain HTTP is accepted
only for loopback development addresses. A browser-only port-forward address
does not make Hub reachable from remote clusters.

For Argo CD, Flux and NKP, provision the private-key Secret through your secret
manager in every target namespace before enabling the referenced settings.
Commit only the Secret reference and public configuration. NKP's workspace
values cannot create that Secret in every cluster; pre-provisioning is a
required step. Never paste the private key into NKP workspace values or a
ConfigMap.

#### Migrate or rotate without changing cluster trust

For an existing fleet, register an app public key in the UI and select
**Replace existing key**, including when replacing an install secret. Confirm
the affected clusters. That explicit replacement preserves each cluster's
existing trust value as it rejoins; new clusters use the new key's policy.
Check that the replacement's cluster maximum accommodates the fleet.

Keep the old install secret configured while moving agents to the new private
Secret and organization settings. Restart agents deliberately, verify their
cluster IDs, history and access, then revoke the old enrollment credential and
remove its install config. Switching `enrollment.key` directly to
`enrollment.publicKey` is a hard cutover: Hub retires the previous install key
as its replicas start.

Revocation stops future enrollment. It does not disconnect active tunnels or
revoke already issued cluster tokens. Compromise response may require separate
cluster actions; removing a cluster registration can remove its history. Do
not treat key revocation as immediate fleet isolation.

## Self-signed certificate

With `web.tls.selfSigned=true`, or whenever the web pod keeps its https listener for a Radar agent in the same cluster (`web.tls.inCluster`, a localhost `hub.publicURL`, or `localCluster`), the chart creates a Secret named `<fullname>-web-tls` (`radar-hub-web-tls` for a release named `radar-hub`; `<fullname>` is the release name if it contains `radar-hub`, else `<release>-radar-hub`, or `fullnameOverride` if set) holding a self-signed certificate for the host in `hub.publicURL`. The chart makes it once and reuses that Secret on every upgrade, so the certificate stays the same and clusters that trust it keep working. The chart marks the Secret `helm.sh/resource-policy: keep`, so `helm uninstall` leaves it in place. To replace it, delete the Secret and restart the web pods, then run `helm upgrade`:

```sh
kubectl delete secret <fullname>-web-tls -n <namespace>
helm upgrade ...
kubectl rollout restart deployment/<fullname>-web -n <namespace>
```

 Clusters that trusted the old certificate need to trust the new one.

With `web.tls.selfSigned=true`, the cluster install steps show the hub's certificate (public part only) so clusters trust it. If you use Argo CD with the chart-generated certificate, supply your own (values or Secret, below): otherwise the steps can show a certificate the hub isn't serving.

**Your own certificate.** Two ways to give the web pod a certificate you made. If both are set, `web.tls.existingSecret` wins over the values.

*Option 1: values.* Set `web.tls.certificate` and `web.tls.privateKey` to PEM text (both are required together). The chart stores them in the Secret `<fullname>-web-tls`.

```yaml
web:
  tls:
    certificate: |
      -----BEGIN CERTIFICATE-----
      ...
    privateKey: |
      -----BEGIN PRIVATE KEY-----
      ...
```

*Option 2: a Secret you create.* On GitOps (Argo CD, Flux), keep the private key out of Git and use this one. Argo CD renders the chart without looking at the cluster, so the chart cannot see its own Secret and would make a new certificate on every sync. Create the Secret yourself and point the chart at it. The chart then renders no certificate Secret and mounts yours. The certificate must name the host in `hub.publicURL`. For a DNS host (for an IP host use `IP:` instead of `DNS:`):

```sh
HOST=radar.example.com
NS=radar-hub

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout tls.key -out tls.crt -subj "/CN=$HOST" \
  -addext "subjectAltName=DNS:$HOST"

kubectl create secret tls radar-hub-web-tls-own -n "$NS" --cert=tls.crt --key=tls.key \
  --dry-run=client -o yaml | kubectl apply -f -
```

Then set it in your values and sync:

```yaml
web:
  tls:
    existingSecret: radar-hub-web-tls-own
```

Use a name other than `<fullname>-web-tls`, which the chart's own Secret would use. Keep `tls.key` out of Git. The `kubectl create ... | kubectl apply` form is safe to run again. To renew, run the steps again, then restart the web Deployment. With `web.tls.selfSigned=true`, the web pod's certificate serves the hub's public address, so the hub pod also gets its public half (never the key) at `/etc/radar-hub/web-tls/tls.crt` and can hand it to clusters that must trust it. Behind an Ingress, Gateway or load balancer with its own certificate, the hub gets no such file. Other tools that render without cluster access, such as `helm template` piped to `kubectl apply`, have the same limit.

## Values

See [`values.yaml`](values.yaml) for the full set, and
[`values.schema.json`](values.schema.json) for the enforced schema. Invalid
values are rejected at install time rather than surfacing as a broken pod.

## AI agent

Release prerequisite: this feature requires a Hub release with Anthropic provider
support (for `provider: vertex`, Vertex provider support; for
`provider: openai-compatible` and `anthropic.baseUrl`, Hub 1.15.0) and a public `radar-hub-ai-agent-sandbox` image at the same version as
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
talks to Claude on Google Cloud Vertex AI with a service-account key;
`openai-compatible` talks to any model behind an OpenAI-compatible API (see
[Any model](#any-model-openai-compatible) below). Only the selected provider's
broker is mounted and only its credential is written, so the other egress path
does not exist in the pod.

With the bundled evaluation Postgres, set its password explicitly and the
chart derives the DSN the sandbox pod uses:

```bash
helm upgrade --install radar-hub skyhook/radar-hub \
  --set hub.agent.enabled=true \
  --set hub.agent.provider=anthropic \
  --set hub.agent.credentials.apiKey=sk-ant-… \
  --set postgres.bundled.auth.password='<password>'
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
  --set postgres.bundled.auth.password='<password>'
```

For a sealed-secrets or external-secrets workflow, skip the inline values and
set `hub.agent.credentials.existingSecret` to an object you manage. It must
live in the sandbox namespace and carry `HUB_AGENT_DB_DSN` plus
`HUB_AGENT_ANTHROPIC_API_KEY`, `HUB_AGENT_BEDROCK_API_KEY`,
`HUB_AGENT_VERTEX_CREDENTIALS` (the service-account key JSON) or
`HUB_AGENT_OPENAI_COMPAT_API_KEY` (empty for a keyless model server), matching
the provider.

To reach Claude through a company gateway (LiteLLM, a proxy) instead of
`api.anthropic.com`, keep `provider: anthropic` and set
`hub.agent.anthropic.baseUrl` (needs Hub 1.15.0). The key is sent as both
`x-api-key` and a bearer token.

### Any model (openai-compatible)

`provider: openai-compatible` runs investigations on any model behind an
OpenAI-compatible API: GPT on OpenAI or Azure, Kimi, DeepSeek or gpt-oss on
Amazon Bedrock, Gemini, a company AI gateway, or vLLM and Ollama in your
cluster. It needs Hub 1.15.0. Claude stays the recommended choice; these models
run on a different agent loop, and the Hub's `docs/self-hosted-models.md` lists
which were tested and how they scored.

```bash
helm upgrade --install radar-hub skyhook/radar-hub \
  --set hub.agent.enabled=true \
  --set hub.agent.provider=openai-compatible \
  --set hub.agent.openaiCompatible.baseUrl=https://bedrock-mantle.us-east-1.api.aws/v1 \
  --set hub.agent.openaiCompatible.model=moonshotai.kimi-k2.5 \
  --set hub.agent.credentials.apiKey=<key> \
  --set postgres.bundled.auth.password='<password>'
```

- `openaiCompatible.baseUrl` is the API root **including its version path**
  (`https://api.openai.com/v1`, `https://<resource>.openai.azure.com/openai/v1`,
  `http://vllm.models.svc:8000/v1`). Required, with `openaiCompatible.model`.
- `openaiCompatible.api` is `chat` (default, every compatible server) or
  `responses` (OpenAI's Responses API, for OpenAI reasoning models).
- `openaiCompatible.authHeader` is `bearer` (default) or `api-key` (Azure).
- `openaiCompatible.reasoningEffort` is `low`, `medium` or `high`, for models
  that reason; empty leaves the provider's default.
- `openaiCompatible.maxOutputTokens` caps each model reply; empty is 32000.
  Lower it for a model with a smaller output limit (GPT-4o: 16384), which
  otherwise refuses every request.
- `credentials.apiKey` may be empty for a model server that takes no key.

A model endpoint off port 443 (vLLM, Ollama, a gateway on its own port) needs a
sandbox egress rule:

```yaml
hub:
  agent:
    sandbox:
      networkPolicy:
        extraEgress:
          - to:
              - namespaceSelector:
                  matchLabels:
                    kubernetes.io/metadata.name: models
            ports:
              - { protocol: TCP, port: 11434 }
```

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
  --set postgres.bundled.auth.password='<password>'
```

Analyses draw on the same model account as the investigations you start by
hand, so turning it on adds provider spend that follows how often your rules
fire.

### The sandbox namespace

Jobs land in `<fullname>-sandbox` unless `hub.agent.sandbox.namespace` says
otherwise. `<fullname>` is the release name when it already contains
`radar-hub`, otherwise `<release>-radar-hub`: a release named `radar-hub` uses
`radar-hub-sandbox`, and a release named `rh` uses `rh-radar-hub-sandbox`.
`fullnameOverride` replaces `<fullname>` outright, and `nameOverride` replaces
`radar-hub` in that rule; this also applies to the `<fullname>-postgres`
Secret above. The default is release-scoped so two installs in one cluster get
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
