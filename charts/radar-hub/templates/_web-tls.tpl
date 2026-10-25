{{/*
The certificate the chart's web-tls Secret holds, as JSON with crt, key and
generated (true when the chart made it). web.tls.certificate and
web.tls.privateKey win over a generated certificate. A generated one is made
for hub.publicURL's host once, then reused from the existing Secret. It is
cached on the root context, so the Secret is rendered from one certificate.
lookup returns nothing under `helm template` and in tools that render without
cluster access; there a new certificate is made on every render, so those
users supply their own.
*/}}
{{- define "radar-hub.webTLSCert" -}}
{{- if not (hasKey . "webTLSCache") -}}
{{- if and .Values.web.tls.certificate .Values.web.tls.privateKey -}}
{{- $_ := set . "webTLSCache" (dict "crt" (b64enc .Values.web.tls.certificate) "key" (b64enc .Values.web.tls.privateKey) "generated" false) -}}
{{- else -}}
{{- $name := include "radar-hub.webTLSSecretName" . -}}
{{- $host := include "radar-hub.webTLSHost" . }}
{{- $crt := "" }}
{{- $key := "" }}
{{- $existing := lookup "v1" "Secret" .Release.Namespace $name }}
{{- if and $existing $existing.data (index $existing.data "tls.crt") (index $existing.data "tls.key") }}
{{- $crt = index $existing.data "tls.crt" }}
{{- $key = index $existing.data "tls.key" }}
{{- else }}
{{- $isIP := or (contains ":" $host) (regexMatch "^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$" $host) }}
{{- $ips := ternary (list $host) (list) $isIP }}
{{- $dns := ternary (list) (list $host) $isIP }}
{{- $cert := genSelfSignedCert $host $ips $dns 3650 }}
{{- $crt = b64enc $cert.Cert }}
{{- $key = b64enc $cert.Key }}
{{- end }}
{{- $_ := set . "webTLSCache" (dict "crt" $crt "key" $key "generated" true) -}}
{{- end -}}
{{- end -}}
{{- toJson (get . "webTLSCache") -}}
{{- end }}
