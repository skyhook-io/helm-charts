{{/*
Expand the name of the chart.
*/}}
{{- define "radar-hub.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified app name. <release>-radar-hub unless overridden.
*/}}
{{- define "radar-hub.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "radar-hub.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "radar-hub.labels" -}}
helm.sh/chart: {{ include "radar-hub.chart" . }}
{{ include "radar-hub.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "radar-hub.selectorLabels" -}}
app.kubernetes.io/name: {{ include "radar-hub.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "radar-hub.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "radar-hub.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Component-specific names.
*/}}
{{- define "radar-hub.hubName" -}}
{{- printf "%s-hub" (include "radar-hub.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "radar-hub.webName" -}}
{{- printf "%s-web" (include "radar-hub.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "radar-hub.secretName" -}}
{{- printf "%s-config" (include "radar-hub.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Image tags default to the chart appVersion when not pinned.
*/}}
{{- define "radar-hub.hubImage" -}}
{{- $tag := default .Chart.AppVersion .Values.image.hub.tag -}}
{{- printf "%s:%s" .Values.image.hub.repository $tag -}}
{{- end }}

{{- define "radar-hub.webImage" -}}
{{- $tag := default .Chart.AppVersion .Values.image.web.tag -}}
{{- printf "%s:%s" .Values.image.web.repository $tag -}}
{{- end }}

{{/*
Name of the bundled (eval) Postgres — its Secret, headless Service, and
StatefulSet all share this name.
*/}}
{{- define "radar-hub.bundledPostgresName" -}}
{{- printf "%s-postgres" (include "radar-hub.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Postgres DSN source resolution. Returns the secretName + key the hub
Deployment (main container + migrate initContainer) pulls HUB_DB_DSN from.
Kept in one place so both stay in sync.

Resolution (exactly one is valid — enforced by the guard in secret.yaml):
  1. bundled.enabled           → chart-managed bundled Secret, key "dsn"
  2. external.existingSecret   → that Secret, key = external.secretKey | "dsn"
  3. external.cnpgCluster      → "<cluster>-app" (CNPG default), key = external.secretKey | "uri"
*/}}
{{- define "radar-hub.postgresSecretRef" -}}
{{- if .Values.postgres.bundled.enabled -}}
name: {{ include "radar-hub.bundledPostgresName" . | quote }}
key: dsn
{{- else if .Values.postgres.external.existingSecret -}}
name: {{ .Values.postgres.external.existingSecret | quote }}
key: {{ .Values.postgres.external.secretKey | default "dsn" | quote }}
{{- else if .Values.postgres.external.cnpgCluster -}}
name: {{ printf "%s-app" .Values.postgres.external.cnpgCluster | quote }}
key: {{ .Values.postgres.external.secretKey | default "uri" | quote }}
{{- end -}}
{{- end }}

{{- define "radar-hub.agentSandboxImage" -}}
{{- $tag := default .Chart.AppVersion .Values.image.agentSandbox.tag -}}
{{- printf "%s:%s" .Values.image.agentSandbox.repository $tag -}}
{{- end }}

{{/*
Namespace the per-turn AI agent Jobs run in. Release-scoped by default so two
installs in one cluster get separate sandboxes and neither adopts a namespace
that happens to already exist under a generic name.
*/}}
{{- define "radar-hub.agentNamespace" -}}
{{- default (printf "%s-sandbox" (include "radar-hub.fullname" .) | trunc 63 | trimSuffix "-") .Values.hub.agent.sandbox.namespace }}
{{- end }}

{{- define "radar-hub.agentSecretName" -}}
{{- default (printf "%s-agent" (include "radar-hub.fullname" .) | trunc 63 | trimSuffix "-") .Values.hub.agent.credentials.existingSecret }}
{{- end }}

{{/*
Hub URL as resolved from OUTSIDE the release namespace. HUB_SELF_URL is the
back-channel the sandbox pod dials for the MCP tunnel, so unlike publicURL it
must be an in-cluster FQDN, and unlike the bundled Postgres DSN it cannot be a
bare Service name.
*/}}
{{- define "radar-hub.hubSelfURL" -}}
{{- printf "http://%s.%s.svc.%s:%d" (include "radar-hub.hubName" .) .Release.Namespace .Values.clusterDomain (int .Values.service.hub.port) -}}
{{- end }}

{{/*
Key the model credential is written under, inside the sandbox Secret. Named by
provider (jobengine/launcher.go), so flipping hub.agent.provider moves the
key rather than needing a second Secret — and the unselected provider's key
never exists in the cluster.
*/}}
{{- define "radar-hub.agentKeyName" -}}
{{- if eq .Values.hub.agent.provider "anthropic" -}}
HUB_AGENT_ANTHROPIC_API_KEY
{{- else -}}
HUB_AGENT_BEDROCK_API_KEY
{{- end -}}
{{- end }}

{{/*
DSN the SANDBOX POD resolves. Explicit value wins. Otherwise derived for the
bundled eval Postgres, whose own `dsn` key is a bare Service name and therefore
unresolvable from another namespace.

The bundled password is deliberately NOT re-derived here: postgres-bundled.yaml
generates one with randAlphaNum when it cannot look up the existing Secret, and
a second generate call would produce a different string. The guard in
secret.yaml requires an explicit postgres.bundled.auth.password before this
path is reachable.
*/}}
{{- define "radar-hub.agentPodDSN" -}}
{{- if .Values.hub.agent.credentials.podDSN -}}
{{- .Values.hub.agent.credentials.podDSN -}}
{{- else -}}
{{- $auth := .Values.postgres.bundled.auth -}}
{{- $host := printf "%s.%s.svc.%s" (include "radar-hub.bundledPostgresName" .) .Release.Namespace .Values.clusterDomain -}}
{{- /* Match postgres-bundled.yaml: URI components, not form encoding. */ -}}
{{- $u := $auth.username | urlquery | replace "+" "%20" -}}
{{- $p := $auth.password | urlquery | replace "+" "%20" -}}
{{- $d := $auth.database | urlquery | replace "+" "%20" -}}
{{- printf "postgres://%s:%s@%s:5432/%s?sslmode=disable" $u $p $host $d -}}
{{- end -}}
{{- end }}
