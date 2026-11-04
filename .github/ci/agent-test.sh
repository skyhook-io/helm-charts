#!/usr/bin/env bash
# Render-only regression tests. These do not prove the selected Hub image can
# start a live investigation; that requires a compatible published release.
set -euo pipefail
cd "$(dirname "$0")/../.."
chart=charts/radar-hub
fixture="$chart/ci/agent-anthropic-values.yaml"
checks=0

render() { helm template review "$chart" --namespace agent-test -f "$fixture" "$@"; }
contains() {
  if ! grep -Fq -- "$2" <<< "$1"; then
    printf 'FAIL: expected %s\n' "$2" >&2
    exit 1
  fi
  checks=$((checks + 1))
}
absent() {
  if grep -Fq -- "$2" <<< "$1"; then
    printf 'FAIL: unexpected %s\n' "$2" >&2
    exit 1
  fi
  checks=$((checks + 1))
}
reject() {
  local message=$1 output
  shift
  if output=$(render "$@" 2>&1); then
    printf 'FAIL: expected rejection: %s\n' "$message" >&2
    exit 1
  fi
  contains "$output" "$message"
}

enabled=$(render)
version=$(awk '/^appVersion:/ {gsub(/"/, "", $2); print $2}' "$chart/Chart.yaml")
contains "$enabled" "ghcr.io/skyhook-dev/radar-hub-ai-agent-sandbox:$version"
contains "$enabled" "ghcr.io/skyhook-dev/radar-hub:$version"
contains "$enabled" 'HUB_AGENT_ENABLED'
contains "$enabled" 'HUB_AGENT_PROVIDER'
contains "$enabled" 'HUB_AGENT_ANTHROPIC_API_KEY:'
contains "$enabled" 'app: diagnose-turn' # Existing launcher contract, not a public value.
contains "$enabled" 'pod-security.kubernetes.io/enforce: restricted'
contains "$enabled" 'verbs: ["create", "deletecollection"]'
contains "$enabled" 'verbs: ["list"]'
absent "$enabled" 'verbs: ["create", "delete", "deletecollection", "get", "list", "watch"]'
absent "$enabled" 'verbs: ["get", "list"]'
contains "$enabled" 'http://review-radar-hub-hub.agent-test.svc.cluster.local:8080'
absent "$enabled" 'HUB_AGENT_BEDROCK_API_KEY:'
absent "$enabled" 'HUB_AGENT_BEDROCK_MODEL'
absent "$enabled" 'HUB_AGENT_BACKGROUND_ENABLED' # Engine on does not imply alert analysis.

alerts=$(render --set hub.agent.alertAnalysis=true)
contains "$alerts" 'HUB_AGENT_BACKGROUND_ENABLED'
reject 'hub.agent.alertAnalysis=true requires hub.agent.enabled=true' \
  --set hub.agent.enabled=false --set hub.agent.alertAnalysis=true

off=$(render --set hub.agent.enabled=false)
absent "$off" 'HUB_AGENT_'
absent "$off" 'kind: NetworkPolicy'
absent "$off" 'kind: Namespace'
absent "$off" 'kind: RoleBinding'

bedrock=$(render --set hub.agent.provider=bedrock)
contains "$bedrock" 'HUB_AGENT_BEDROCK_API_KEY:'
contains "$bedrock" 'HUB_AGENT_BEDROCK_API_KEY_SECRET'
contains "$bedrock" 'HUB_AGENT_BEDROCK_MODEL'
absent "$bedrock" 'HUB_AGENT_ANTHROPIC_API_KEY:'
absent "$bedrock" 'HUB_AGENT_ANTHROPIC_MODEL'

vertex() { render --set hub.agent.provider=vertex --set-string hub.agent.credentials.apiKey= \
  --set-string hub.agent.vertex.project=test-project \
  --set-json 'hub.agent.credentials.serviceAccountJSON="{\"type\":\"service_account\"}"' "$@"; }
vx=$(vertex)
contains "$vx" 'HUB_AGENT_VERTEX_CREDENTIALS: "{\"type\":\"service_account\"}"'
contains "$vx" 'HUB_AGENT_VERTEX_CREDENTIALS_SECRET'
contains "$vx" 'HUB_AGENT_VERTEX_PROJECT'
contains "$vx" 'value: "test-project"'
contains "$vx" 'HUB_AGENT_VERTEX_LOCATION'
contains "$vx" 'HUB_AGENT_VERTEX_MODEL'
absent "$vx" 'HUB_AGENT_ANTHROPIC_'
absent "$vx" 'HUB_AGENT_BEDROCK_'
absent "$bedrock" 'HUB_AGENT_VERTEX_'
absent "$enabled" 'HUB_AGENT_VERTEX_'
vx_existing=$(vertex --set-string hub.agent.credentials.serviceAccountJSON= \
  --set-string hub.agent.credentials.existingSecret=vertex-creds)
contains "$vx_existing" 'value: "vertex-creds"'
absent "$vx_existing" 'HUB_AGENT_VERTEX_CREDENTIALS:'
reject_vertex() {
  local message=$1 output
  shift
  if output=$(vertex "$@" 2>&1); then
    printf 'FAIL: expected rejection: %s\n' "$message" >&2
    exit 1
  fi
  contains "$output" "$message"
}
reject_vertex 'hub.agent.vertex.project is required' --set-string hub.agent.vertex.project=
reject_vertex 'hub.agent.vertex.location is required' --set-string hub.agent.vertex.location=
reject_vertex 'hub.agent.vertex.model is required' --set-string hub.agent.vertex.model=
reject_vertex 'hub.agent.credentials.apiKey is not read under provider: vertex' --set-string hub.agent.credentials.apiKey=sk-ant-x
reject_vertex 'hub.agent.enabled is true but no model credential' --set-string hub.agent.credentials.serviceAccountJSON=
reject 'serviceAccountJSON is only read under provider: vertex' --set-string hub.agent.credentials.serviceAccountJSON=stale

encoded=$(render --set-string 'postgres.bundled.auth.username=user/name' \
  --set-string 'postgres.bundled.auth.password=a/b#c@d +%' \
  --set-string 'postgres.bundled.auth.database=db/name')
contains "$encoded" 'HUB_AGENT_DB_DSN: "postgres://user%2Fname:a%2Fb%23c%40d%20%2B%25@review-radar-hub-postgres.agent-test.svc.cluster.local:5432/db%2Fname?sslmode=disable"'
contains "$encoded" 'dsn: "postgres://user%2Fname:a%2Fb%23c%40d%20%2B%25@review-radar-hub-postgres:5432/db%2Fname?sslmode=disable"'

secret=customer-managed-investigation-credentials-production-primary-2026-secret
existing=$(render --set-string hub.agent.credentials.apiKey= \
  --set-string "hub.agent.credentials.existingSecret=$secret" \
  --set hub.agent.sandbox.create=false --set hub.agent.sandbox.namespace=custom-sandbox)
contains "$existing" "value: \"$secret\""
contains "$existing" 'namespace: custom-sandbox'
absent "$existing" 'kind: Namespace'
absent "$existing" 'HUB_AGENT_DB_DSN:'
absent "$existing" 'HUB_AGENT_ANTHROPIC_API_KEY:'

dsn='postgres://custom:password@db.example:6432/db?sslmode=require'
explicit=$(render --set-string "hub.agent.credentials.podDSN=$dsn")
contains "$explicit" "HUB_AGENT_DB_DSN: \"$dsn\""
reject 'hub.agent.enabled is true but no model credential' --set-string hub.agent.credentials.apiKey=
reject 'set existingSecret OR' --set-string "hub.agent.credentials.existingSecret=$secret"
reject 'postgres.bundled.auth.password set explicitly' --set-string postgres.bundled.auth.password=
reject 'hub.agent.anthropic.model is required' --set-string hub.agent.anthropic.model=
reject 'hub.agent.bedrock.region is required' --set hub.agent.provider=bedrock --set-string hub.agent.bedrock.region=
reject 'provider' --set hub.agent.provider=invalid
# openai-compatible: any model behind an OpenAI-compatible API. Rendered with
# a 1.15.0 hub, the first release that has the provider.
compat() { render --set image.hub.tag=1.15.0 --set hub.agent.provider=openai-compatible \
  --set-string hub.agent.credentials.apiKey=sk-test \
  --set-string hub.agent.openaiCompatible.baseUrl=https://bedrock-mantle.us-east-1.api.aws/v1 \
  --set-string hub.agent.openaiCompatible.model=moonshotai.kimi-k2.5 "$@"; }
oc=$(compat)
contains "$oc" 'HUB_AGENT_OPENAI_COMPAT_API_KEY: "sk-test"'
contains "$oc" 'HUB_AGENT_OPENAI_COMPAT_API_KEY_SECRET'
contains "$oc" 'value: "https://bedrock-mantle.us-east-1.api.aws/v1"'
contains "$oc" 'value: "moonshotai.kimi-k2.5"'
contains "$oc" 'HUB_AGENT_OPENAI_COMPAT_API'
contains "$oc" 'value: "chat"'
contains "$oc" 'value: "bearer"'
absent "$oc" 'HUB_AGENT_REASONING_EFFORT'
absent "$oc" 'HUB_AGENT_PRICE_'
absent "$oc" 'HUB_AGENT_ANTHROPIC_'
absent "$oc" 'HUB_AGENT_BEDROCK_'
absent "$oc" 'HUB_AGENT_VERTEX_'
# The Claude providers get none of the new settings.
for out in "$enabled" "$bedrock" "$vx"; do
  absent "$out" 'HUB_AGENT_OPENAI_COMPAT_'
  absent "$out" 'HUB_AGENT_PRICE_'
  absent "$out" 'HUB_AGENT_REASONING_EFFORT'
  absent "$out" 'HUB_AGENT_ANTHROPIC_BASE_URL'
done
oc_full=$(compat --set hub.agent.openaiCompatible.api=responses --set hub.agent.openaiCompatible.authHeader=api-key \
  --set hub.agent.openaiCompatible.reasoningEffort=high \
  --set-string hub.agent.prices.inputPerMTok=0.60 --set-string hub.agent.prices.outputPerMTok=2.5 \
  --set-string hub.agent.prices.cacheReadPerMTok=0.15)
contains "$oc_full" 'value: "responses"'
contains "$oc_full" 'value: "api-key"'
contains "$oc_full" 'HUB_AGENT_REASONING_EFFORT'
contains "$oc_full" 'value: "high"'
contains "$oc_full" 'HUB_AGENT_PRICE_INPUT_PER_MTOK'
contains "$oc_full" 'value: "0.60"'
contains "$oc_full" 'HUB_AGENT_PRICE_CACHE_READ_PER_MTOK'
absent "$oc_full" 'HUB_AGENT_PRICE_CACHE_WRITE_PER_MTOK'
# An upgrade with --reuse-values from a chart without hub.agent.prices: no
# prices map at all still renders, with no price env.
no_prices=$(compat --set hub.agent.prices=null)
contains "$no_prices" 'HUB_AGENT_OPENAI_COMPAT_MODEL'
absent "$no_prices" 'HUB_AGENT_PRICE_'
# Keyless model server: the key is written empty, and the hub sends none.
keyless=$(compat --set-string hub.agent.credentials.apiKey=)
contains "$keyless" 'HUB_AGENT_OPENAI_COMPAT_API_KEY: ""'
oc_existing=$(compat --set-string hub.agent.credentials.apiKey= --set-string hub.agent.credentials.existingSecret=model-creds)
contains "$oc_existing" 'value: "model-creds"'
absent "$oc_existing" 'HUB_AGENT_OPENAI_COMPAT_API_KEY:'
reject_compat() {
  local message=$1 output
  shift
  if output=$(compat "$@" 2>&1); then
    printf 'FAIL: expected rejection: %s\n' "$message" >&2
    exit 1
  fi
  contains "$output" "$message"
}
reject_compat 'hub.agent.openaiCompatible.baseUrl is required' --set-string hub.agent.openaiCompatible.baseUrl=
reject_compat 'hub.agent.openaiCompatible.model is required' --set-string hub.agent.openaiCompatible.model=
reject_compat 'needs radar-hub 1.15.0 or later' --set image.hub.tag=1.14.1
# The sandbox follows the hub's tag, so raising the hub alone raises it too;
# a sandbox pinned below 1.15.0 on its own is refused.
oc_default=$(compat)
contains "$oc_default" 'radar-hub-ai-agent-sandbox:1.15.0"'
reject_compat 'needs the radar-hub sandbox 1.15.0 or later' --set image.agentSandbox.tag=1.14.1
oc_pinned=$(compat --set image.agentSandbox.tag=1.15.1)
contains "$oc_pinned" 'radar-hub-ai-agent-sandbox:1.15.1"'
reject_compat 'set inputPerMTok and outputPerMTok together' --set-string hub.agent.prices.inputPerMTok=1
reject_compat 'hub.agent.anthropic.baseUrl is only read under provider: anthropic' --set-string hub.agent.anthropic.baseUrl=https://gw.example
reject_compat 'serviceAccountJSON is only read under provider: vertex' --set-string hub.agent.credentials.serviceAccountJSON=x
reject_compat 'baseUrl' --set-string hub.agent.openaiCompatible.baseUrl='https://x/v1?api-version=1'
reject_compat 'api' --set hub.agent.openaiCompatible.api=completions
reject_compat 'reasoningEffort' --set hub.agent.openaiCompatible.reasoningEffort=max
reject_compat 'inputPerMTok' --set-string 'hub.agent.prices.inputPerMTok=$3' --set-string hub.agent.prices.outputPerMTok=1
reject 'hub.agent.prices is only read under provider: openai-compatible' \
  --set-string hub.agent.prices.inputPerMTok=1 --set-string hub.agent.prices.outputPerMTok=1

# The Anthropic gateway: Claude through a company proxy.
gw=$(render --set image.hub.tag=1.15.0 --set-string hub.agent.anthropic.baseUrl=https://litellm.internal/anthropic)
contains "$gw" 'HUB_AGENT_ANTHROPIC_BASE_URL'
contains "$gw" 'value: "https://litellm.internal/anthropic"'
reject 'hub.agent.anthropic.baseUrl needs radar-hub 1.15.0 or later' --set image.hub.tag=1.14.1 --set-string hub.agent.anthropic.baseUrl=https://gw.example

printf 'AI agent chart: %s assertions passed\n' "$checks"
