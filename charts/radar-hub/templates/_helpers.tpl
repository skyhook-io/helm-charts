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
