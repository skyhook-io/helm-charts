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

{{- define "radar-hub.migrateName" -}}
{{- printf "%s-migrate" (include "radar-hub.fullname" .) | trunc 63 | trimSuffix "-" }}
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
Postgres DSN source resolution. Returns the secretName + key the hub
Deployment should pull HUB_DB_DSN from. Used by deployment-hub +
migrate-job to keep the resolution logic in one place.

Resolution order (first match wins):
  1. .Values.postgres.existingSecret  → that Secret, key "dsn"
  2. .Values.postgres.cnpg.cluster    → "<cluster>-app" (CNPG default), key "uri"
  3. .Values.postgres.dsn             → chart-managed Secret, key "dsn"

Validation lives in values.schema.json — at least one must be set.
*/}}
{{- define "radar-hub.postgresSecretRef" -}}
{{- if .Values.postgres.existingSecret -}}
name: {{ .Values.postgres.existingSecret | quote }}
key: dsn
{{- else if .Values.postgres.cnpg.cluster -}}
name: {{ .Values.postgres.cnpg.secretName | default (printf "%s-app" .Values.postgres.cnpg.cluster) | quote }}
key: uri
{{- else -}}
name: {{ include "radar-hub.secretName" . | quote }}
key: postgres-dsn
{{- end -}}
{{- end }}
