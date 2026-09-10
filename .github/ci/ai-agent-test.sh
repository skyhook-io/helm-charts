#!/usr/bin/env bash
# Render-only regression tests. These do not prove the selected Hub image can
# start a live investigation; that requires a compatible published release.
set -euo pipefail
cd "$(dirname "$0")/../.."
chart=charts/radar-hub
fixture="$chart/ci/ai-agent-anthropic-values.yaml"
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
contains "$enabled" 'HUB_AI_AGENT_ENABLED'
contains "$enabled" 'HUB_AI_AGENT_PROVIDER'
contains "$enabled" 'HUB_AGENT_ANTHROPIC_API_KEY:'
contains "$enabled" 'app: diagnose-turn' # Existing launcher contract, not a public value.
contains "$enabled" 'pod-security.kubernetes.io/enforce: restricted'
contains "$enabled" 'http://review-radar-hub-hub.agent-test.svc.cluster.local:8080'
absent "$enabled" 'HUB_AGENT_BEDROCK_API_KEY:'
absent "$enabled" 'HUB_AI_AGENT_BEDROCK_MODEL'

off=$(render --set hub.aiAgent.enabled=false)
absent "$off" 'HUB_AI_AGENT_'
absent "$off" 'kind: NetworkPolicy'
absent "$off" 'kind: Namespace'
absent "$off" 'kind: RoleBinding'

bedrock=$(render --set hub.aiAgent.provider=bedrock)
contains "$bedrock" 'HUB_AGENT_BEDROCK_API_KEY:'
contains "$bedrock" 'HUB_AI_AGENT_BEDROCK_API_KEY_SECRET'
contains "$bedrock" 'HUB_AI_AGENT_BEDROCK_MODEL'
absent "$bedrock" 'HUB_AGENT_ANTHROPIC_API_KEY:'
absent "$bedrock" 'HUB_AI_AGENT_ANTHROPIC_MODEL'

encoded=$(render --set-string 'postgres.bundled.auth.username=user/name' \
  --set-string 'postgres.bundled.auth.password=a/b#c@d +%' \
  --set-string 'postgres.bundled.auth.database=db/name')
contains "$encoded" 'HUB_AGENT_DB_DSN: "postgres://user%2Fname:a%2Fb%23c%40d%20%2B%25@review-radar-hub-postgres.agent-test.svc.cluster.local:5432/db%2Fname?sslmode=disable"'
contains "$encoded" 'dsn: "postgres://user%2Fname:a%2Fb%23c%40d%20%2B%25@review-radar-hub-postgres:5432/db%2Fname?sslmode=disable"'

secret=customer-managed-investigation-credentials-production-primary-2026-secret
existing=$(render --set-string hub.aiAgent.credentials.apiKey= \
  --set-string "hub.aiAgent.credentials.existingSecret=$secret" \
  --set hub.aiAgent.sandbox.create=false --set hub.aiAgent.sandbox.namespace=custom-sandbox)
contains "$existing" "value: \"$secret\""
contains "$existing" 'namespace: custom-sandbox'
absent "$existing" 'kind: Namespace'
absent "$existing" 'HUB_AGENT_DB_DSN:'
absent "$existing" 'HUB_AGENT_ANTHROPIC_API_KEY:'

dsn='postgres://custom:password@db.example:6432/db?sslmode=require'
explicit=$(render --set-string "hub.aiAgent.credentials.podDSN=$dsn")
contains "$explicit" "HUB_AGENT_DB_DSN: \"$dsn\""
reject 'hub.aiAgent.enabled is true but no model credential' --set-string hub.aiAgent.credentials.apiKey=
reject 'set existingSecret OR' --set-string "hub.aiAgent.credentials.existingSecret=$secret"
reject 'postgres.bundled.auth.password set explicitly' --set-string postgres.bundled.auth.password=
reject 'hub.aiAgent.anthropic.model is required' --set-string hub.aiAgent.anthropic.model=
reject 'hub.aiAgent.bedrock.region is required' --set hub.aiAgent.provider=bedrock --set-string hub.aiAgent.bedrock.region=
reject 'provider' --set hub.aiAgent.provider=invalid
printf 'AI agent chart: %s assertions passed\n' "$checks"
