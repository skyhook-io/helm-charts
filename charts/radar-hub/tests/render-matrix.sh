#!/usr/bin/env bash
# What the chart accepts and refuses, as an executable check.
#
# Two guards live here and neither is visible from reading a values file:
#   - air-gapped requires a hub image this chart can PROVE is >= 1.7.0
#   - unknown keys are rejected rather than ignored
#
# Both were shipped broken. The air-gapped guard was a denylist that waved
# through "v1.4.2" and "latest"; the schema accepted "hub.airgapped" with a
# lowercase g and rendered a deployment that called home while the values file
# said it was sealed. Ad-hoc shell in a terminal found both and then vanished
# with the scrollback, so it lives here now.
#
# Usage: charts/radar-hub/tests/render-matrix.sh
set -uo pipefail
cd "$(dirname "$0")/.."

BASE=(--set hub.publicURL=https://x.example
      --set hub.cookiePassword=0123456789012345678901234567890123
      --set auth.breakGlass.email=a@b.c
      --set auth.breakGlass.password=xxxxxxxxxxxx)

fails=0
check() { # check <description> <expect: render|refuse> <extra args...>
  local desc="$1" expect="$2"; shift 2
  local out rc
  out=$(helm template t . "${BASE[@]}" "$@" 2>&1); rc=$?
  local got; [ $rc -eq 0 ] && got=render || got=refuse
  if [ "$got" = "$expect" ]; then
    printf '  ok    %-46s %s\n' "$desc" "$got"
  else
    printf '  FAIL  %-46s got %s, want %s\n' "$desc" "$got" "$expect"
    [ "$got" = refuse ] && printf '        %s\n' "$(echo "$out" | head -1)"
    fails=$((fails+1))
  fi
}

echo "air-gapped requires a provable >= 1.7.0 tag"
for tag in 1.7.0 1.7.3 2.0.0; do
  check "airGapped + $tag" render --set hub.airGapped=true --set image.hub.tag="$tag"
done
# Refused because they cannot be CHECKED, not because they are necessarily old.
for tag in 1.4.2 v1.4.2 1.4 0.9.0 latest sha-abc123 1.5.0 1.6.0 1.7.0-rc1; do
  check "airGapped + $tag" refuse --set hub.airGapped=true --set image.hub.tag="$tag"
done
check "old tag with airGapped off" render --set hub.airGapped=false --set image.hub.tag=1.4.2
# The chart's own appVersion is trusted even as a pre-release (an rc chart on
# an rc Hub). The same pre-release set by hand is not.
APP=$(awk -F'"' '/^appVersion:/{print $2}' Chart.yaml)
case "$APP" in
  *-*) check "airGapped + default tag ($APP)" render --set hub.airGapped=true
       check "airGapped + ${APP%%-*}-rc.999 by hand" refuse --set hub.airGapped=true --set image.hub.tag="${APP%%-*}-rc.999" ;;
esac

echo "unknown keys are refused, not ignored"
check "hub.airgapped (lowercase g)"  refuse --set hub.airgapped=true
check "hubb.publicURL (top-level)"   refuse --set hubb.publicURL=x
check "image.hub.tagg"               refuse --set image.hub.tagg=1.5.0
check "auth.breakGlass.emial"        refuse --set auth.breakGlass.emial=a@b.c
# The two blocks that stayed open after the first pass. Both sit deep enough
# that closing a parent does nothing for them, and a typo in either renders a
# working-looking release with the setting silently dropped — a misspelled OIDC
# issuer signs nobody in, a misspelled Vertex project sends the agent nowhere.
check "auth.oidc.issuerr"           refuse --set auth.oidc.issuerr=https://idp.example
check "hub.agent.vertex.projct"     refuse --set hub.agent.vertex.projct=p

echo "hub.cloudAppURL must be a bare http(s) origin"
check "cloudAppURL https origin"         render --set hub.cloudAppURL=https://app.example
check "cloudAppURL with port"            render --set hub.cloudAppURL=http://localhost:3000
check "cloudAppURL without scheme"       refuse --set hub.cloudAppURL=app.radarhq.io
check "cloudAppURL with trailing slash"   render --set hub.cloudAppURL=https://app.radarhq.io/
check "cloudAppURL max port"             render --set hub.cloudAppURL=https://app.example:65535
check "cloudAppURL IPv6 literal"         render --set 'hub.cloudAppURL=http://[::1]:8080'
check "cloudAppURL with a path"          refuse --set hub.cloudAppURL=https://app.example/org
check "cloudAppURL empty host and port"  refuse --set hub.cloudAppURL=https://:
check "cloudAppURL non-numeric port"     refuse --set hub.cloudAppURL=https://app.example:abc
check "cloudAppURL port out of range"    refuse --set hub.cloudAppURL=https://app.example:99999
check "cloudAppURL port zero"            refuse --set hub.cloudAppURL=https://app.example:0
check "cloudAppURL with userinfo"        refuse --set hub.cloudAppURL=https://u@app.example
check "cloudAppURL with a query"         refuse --set 'hub.cloudAppURL=https://app.example?x'
check "cloudAppURL with a fragment"      refuse --set 'hub.cloudAppURL=https://app.example#x'
check "cloudAppURL with a backslash"     refuse --set 'hub.cloudAppURL=https://app.example\\evil'   # --set unescapes \\ to one backslash

echo "legitimate values still render"
check "image.hub.tag"                render --set image.hub.tag=1.5.0
# Helm reserves `global` for umbrella charts and the parent owns its shape,
# so closing the root schema must not close this.
check "global.imageRegistry"         render --set global.imageRegistry=my.registry.io
check "global.deeply.nested"         render --set global.deeply.nested=1
# A free-form map the operator fills (IRSA and friends).
check "serviceAccount annotation"    render --set 'serviceAccount.annotations.eks\.amazonaws\.com/role-arn=arn:x'

# What the render CONTAINS. Exit status proves the chart accepted the values;
# it does not prove the Deployment got the setting. Every wiring line a values
# key is supposed to produce is asserted here, so deleting the line from the
# template fails this script rather than shipping a chart that renders cleanly
# and does nothing.
render() { helm template t . "${BASE[@]}" "$@" 2>/dev/null; }
envis() { # envis <description> <ENV_NAME> <value> <extra args...>
  local desc="$1" name="$2" val="$3"; shift 3
  if render "$@" | grep -A1 -E "^\s+- name: $name\$" | grep -qE "^\s+value: \"?$val\"?\$"; then
    printf '  ok    %-46s %s=%s\n' "$desc" "$name" "$val"
  else
    printf '  FAIL  %-46s %s is not %s in the render\n' "$desc" "$name" "$val"; fails=$((fails+1))
  fi
}
has() { # has <description> <regex> <extra args...>
  local desc="$1" pat="$2"; shift 2
  if render "$@" | grep -qE -- "$pat"; then printf '  ok    %-46s present\n' "$desc"
  else printf '  FAIL  %-46s missing: %s\n' "$desc" "$pat"; fails=$((fails+1)); fi
}
lacks() { # lacks <description> <regex> <extra args...>
  local desc="$1" pat="$2"; shift 2
  if render "$@" | grep -qE -- "$pat"; then printf '  FAIL  %-46s present but must not be: %s\n' "$desc" "$pat"; fails=$((fails+1))
  else printf '  ok    %-46s absent\n' "$desc"; fi
}

echo "the values reach the hub Deployment"
AG=(--set hub.airGapped=true --set image.hub.tag=1.7.0)
envis "airGapped sets the variable"        RADAR_HUB_AIR_GAPPED true "${AG[@]}"
lacks "airGapped suppresses licenseServer" 'name: RADAR_HUB_LICENSE_SERVER' "${AG[@]}" --set hub.licenseServer=https://l.example
lacks "default install is not air-gapped" 'name: RADAR_HUB_AIR_GAPPED'
envis "licenseServer is wired when set"    RADAR_HUB_LICENSE_SERVER https://l.example --set hub.licenseServer=https://l.example
lacks "licenseServer absent when empty"    'name: RADAR_HUB_LICENSE_SERVER'
envis "latestRadarVersion is wired"        HUB_LATEST_RADAR_VERSION 1.10.0 --set hub.latestRadarVersion=1.10.0
lacks "latestRadarVersion absent by default" 'name: HUB_LATEST_RADAR_VERSION'
envis "cloudAppURL is wired when set"      RADAR_HUB_CLOUD_APP_URL https://app.example --set hub.cloudAppURL=https://app.example
lacks "cloudAppURL absent when empty"      'name: RADAR_HUB_CLOUD_APP_URL'
envis "airGapped keeps cloudAppURL"        RADAR_HUB_CLOUD_APP_URL https://app.example "${AG[@]}" --set hub.cloudAppURL=https://app.example

echo "the self-signed certificate is told the public host"
envis "selfSigned passes the host, without the port" WEB_TLS_SELF_SIGNED_HOST radar.acme.example --set web.tls.selfSigned=true --set hub.publicURL=https://radar.acme.example:8443
envis "selfSigned passes a bare host"               WEB_TLS_SELF_SIGNED_HOST x.example         --set web.tls.selfSigned=true
lacks "no host env without selfSigned"            'name: WEB_TLS_SELF_SIGNED_HOST'

echo "a localhost publicURL means port-forward, no public address"
SS=(--set web.tls.selfSigned=true)
LH=(--set hub.publicURL=https://localhost:8443)
check "oneCluster.enabled is no longer a value"  refuse --set oneCluster.enabled=true "${SS[@]}"
check "empty publicURL is refused"               refuse --set hub.publicURL=
check "empty publicURL + selfSigned is refused"  refuse --set hub.publicURL= "${SS[@]}"
for url in https://localhost:8443 https://LOCALHOST https://radar.localhost:9443 https://127.0.0.1:8443 https://127.1.2.3 'https://[::1]:8443' https://0.0.0.0:8443 'https://[::]:8443'; do
  check "$url + selfSigned"                      render --set "hub.publicURL=$url" "${SS[@]}"
  check "$url without selfSigned"                refuse --set "hub.publicURL=$url"
  envis "$url is browser-only"                   RADAR_HUB_BROWSER_ONLY_URL true --set "hub.publicURL=$url" "${SS[@]}"
done
ING=(--set ingress.enabled=true --set 'ingress.hosts[0].host=x.example'
     --set 'ingress.hosts[0].paths[0].path=/' --set 'ingress.hosts[0].paths[0].pathType=Prefix')
check "http localhost is refused"               refuse --set hub.publicURL=http://localhost:8080 "${SS[@]}"
check "http 127.0.0.1 is refused"               refuse --set hub.publicURL=http://127.0.0.1:8443 "${SS[@]}"
check "http localhost + Ingress is allowed"     render --set hub.publicURL=http://localhost "${ING[@]}"
check "localhost + Ingress skips the guard"      render "${LH[@]}" "${ING[@]}"
check "localhost + HTTPRoute skips the guard"    render "${LH[@]}" --set httpRoute.enabled=true --set 'httpRoute.parentRefs[0].name=gw'
check "localhost + LoadBalancer skips the guard" render "${LH[@]}" --set service.web.type=LoadBalancer
lacks "localhost + Ingress is not browser-only"  'name: RADAR_HUB_BROWSER_ONLY_URL' "${LH[@]}" "${ING[@]}"
lacks "localhost + HTTPRoute is not browser-only" 'name: RADAR_HUB_BROWSER_ONLY_URL' "${LH[@]}" --set httpRoute.enabled=true --set 'httpRoute.parentRefs[0].name=gw'
lacks "localhost + LoadBalancer is not browser-only" 'name: RADAR_HUB_BROWSER_ONLY_URL' "${LH[@]}" --set service.web.type=LoadBalancer
envis "localhost + LoadBalancer keeps the in-cluster URL" RADAR_HUB_IN_CLUSTER_AGENT_URL wss://t-radar-hub-web.default.svc.cluster.local/agent "${LH[@]}" --set service.web.type=LoadBalancer
envis "cert host for [::1] has no brackets"     WEB_TLS_SELF_SIGNED_HOST ::1 --set 'hub.publicURL=https://[::1]:8443' "${SS[@]}"
envis "cert host for [::] has no brackets"      WEB_TLS_SELF_SIGNED_HOST :: --set 'hub.publicURL=https://[::]:8443' "${SS[@]}"
envis "cert host for [::1] with no port"        WEB_TLS_SELF_SIGNED_HOST ::1 --set 'hub.publicURL=https://[::1]' "${SS[@]}"
envis "cert host for a public IPv6"             WEB_TLS_SELF_SIGNED_HOST 2001:db8::5 --set 'hub.publicURL=https://[2001:db8::5]:8443' "${SS[@]}"
envis "cert host for 127.0.0.1"                 WEB_TLS_SELF_SIGNED_HOST 127\.0\.0\.1 --set hub.publicURL=https://127.0.0.1:8443 "${SS[@]}"
has   "localhost + Ingress keeps the https port" 'name: https' "${LH[@]}" "${ING[@]}" --show-only templates/service.yaml
envis "localhost + Ingress has the in-cluster URL" RADAR_HUB_IN_CLUSTER_AGENT_URL wss://t-radar-hub-web.default.svc.cluster.local/agent "${LH[@]}" "${ING[@]}"
envis "localhost origins are the URL alone"      HUB_ALLOWED_ORIGINS https://localhost:8443 "${LH[@]}" "${SS[@]}"
envis "localhost is the public URL"              RADAR_HUB_PUBLIC_URL https://localhost:8443 "${LH[@]}" "${SS[@]}"
envis "localhost cert names localhost"           WEB_TLS_SELF_SIGNED_HOST localhost "${LH[@]}" "${SS[@]}"
# Names that only look local. Each must render the way a public address
# always has: no browser-only flag, no https listener, origins = the URL.
for url in https://x.example https://localhost.example.com https://127.0.0.1.nip.io https://mylocalhost 'https://[::2]' https://0.0.0.1 https://10.0.0.0; do
  lacks "$url is not browser-only"               'name: RADAR_HUB_BROWSER_ONLY_URL' --set "hub.publicURL=$url"
  lacks "$url adds no https port"                'name: https' --set "hub.publicURL=$url" --show-only templates/service.yaml
  lacks "$url adds no in-cluster URL"            'name: RADAR_HUB_IN_CLUSTER_AGENT_URL' --set "hub.publicURL=$url"
  envis "$url origins are the URL alone"         HUB_ALLOWED_ORIGINS "$(printf '%s' "$url" | sed 's/[].[]/\\&/g')" --set "hub.publicURL=$url"
done
lacks "no browser-only flag with selfSigned alone" 'name: RADAR_HUB_BROWSER_ONLY_URL' "${SS[@]}"
envis "in-cluster agent URL on 443"             RADAR_HUB_IN_CLUSTER_AGENT_URL wss://t-radar-hub-web.default.svc.cluster.local/agent --set web.tls.selfSigned=true
envis "in-cluster agent URL on a custom port"   RADAR_HUB_IN_CLUSTER_AGENT_URL wss://t-radar-hub-web.default.svc.cluster.local:9443/agent --set web.tls.selfSigned=true --set service.web.tlsPort=9443
envis "in-cluster agent URL uses clusterDomain" RADAR_HUB_IN_CLUSTER_AGENT_URL wss://t-radar-hub-web.default.svc.corp.internal/agent --set web.tls.selfSigned=true --set clusterDomain=corp.internal
envis "in-cluster agent URL uses the release name" RADAR_HUB_IN_CLUSTER_AGENT_URL wss://radar-hub-web.default.svc.cluster.local/agent --set web.tls.selfSigned=true --set fullnameOverride=radar-hub
lacks "no in-cluster agent URL without selfSigned" 'name: RADAR_HUB_IN_CLUSTER_AGENT_URL'

echo "the local cluster"
LC_ID=k3Fg-9pA_x1
LC_TOK=rhc_0123456789abcdefghijABCDEFGHIJ-_0123456789a
secretref() { # secretref <description> <ENV_NAME> <secret> <key> <extra args...>
  local desc="$1" name="$2" sec="$3" key="$4"; shift 4
  if render "$@" | grep -A5 -E "^\s+- name: $name\$" | tr -d '\n' | grep -qE "secretKeyRef:\s+name: \"$sec\"\s+key: \"?$key\"?"; then
    printf '  ok    %-46s %s <- %s/%s\n' "$desc" "$name" "$sec" "$key"
  else
    printf '  FAIL  %-46s %s is not read from %s/%s\n' "$desc" "$name" "$sec" "$key"; fails=$((fails+1))
  fi
}
check "id + token"                              render --set localCluster.id=$LC_ID --set localCluster.token=$LC_TOK
check "id + existingSecret"                     render --set localCluster.id=$LC_ID --set localCluster.existingSecret=lc
check "token and existingSecret together"       refuse --set localCluster.id=$LC_ID --set localCluster.token=$LC_TOK --set localCluster.existingSecret=lc
check "id without a token"                      refuse --set localCluster.id=$LC_ID
check "token without an id"                     refuse --set localCluster.token=$LC_TOK
check "existingSecret without an id"            refuse --set localCluster.existingSecret=lc
check "id of 10 characters"                     refuse --set localCluster.id=k3Fg-9pA_x --set localCluster.token=$LC_TOK
check "id of 12 characters"                     refuse --set localCluster.id=k3Fg-9pA_x12 --set localCluster.token=$LC_TOK
check "id with a dot"                           refuse --set localCluster.id=k3Fg.9pA_x1 --set localCluster.token=$LC_TOK
check "token without the rhc_ prefix"         refuse --set localCluster.id=$LC_ID --set localCluster.token=${LC_TOK#rhc_}xxxx
check "token of 42 characters after rhc_"       refuse --set localCluster.id=$LC_ID --set localCluster.token=${LC_TOK%?}
check "token of 44 characters after rhc_"       refuse --set localCluster.id=$LC_ID --set localCluster.token=${LC_TOK}x
check "token with a dot"                        refuse --set localCluster.id=$LC_ID --set localCluster.token=${LC_TOK%?}.
envis "id is wired"                             HUB_LOCAL_CLUSTER_ID $LC_ID --set localCluster.id=$LC_ID --set localCluster.token=$LC_TOK
envis "name is local"                           HUB_LOCAL_CLUSTER_NAME local --set localCluster.id=$LC_ID --set localCluster.token=$LC_TOK
has   "token lands in the chart Secret"         "local-cluster-token: \"$LC_TOK\"" --set localCluster.id=$LC_ID --set localCluster.token=$LC_TOK
secretref "token is read from the chart Secret" HUB_LOCAL_CLUSTER_TOKEN t-radar-hub-config local-cluster-token --set localCluster.id=$LC_ID --set localCluster.token=$LC_TOK
secretref "existingSecret defaults to key token" HUB_LOCAL_CLUSTER_TOKEN lc token --set localCluster.id=$LC_ID --set localCluster.existingSecret=lc
secretref "existingSecretKey is honoured"       HUB_LOCAL_CLUSTER_TOKEN lc agent-token --set localCluster.id=$LC_ID --set localCluster.existingSecret=lc --set localCluster.existingSecretKey=agent-token
lacks "existingSecret writes no token"          'local-cluster-token:' --set localCluster.id=$LC_ID --set localCluster.existingSecret=lc
lacks "no local cluster by default"             'name: HUB_LOCAL_CLUSTER_'
# A new token must restart the hub, or it keeps authenticating the old one.
# The pod checksum covers the chart Secret the inline token is written to.
sum_for() { render --set localCluster.id=$LC_ID "$@" --show-only templates/deployment-hub.yaml | awk '/checksum\/secret:/{print $2}'; }
if [ "$(sum_for --set localCluster.token=$LC_TOK)" != "$(sum_for --set localCluster.token=${LC_TOK%?}b)" ]; then
  printf '  ok    %-46s %s\n' "new inline token rolls the hub pod" "checksum changes"
else printf '  FAIL  %-46s checksum unchanged\n' "new inline token rolls the hub pod"; fails=$((fails+1)); fi

echo "the local cluster keeps its in-cluster listener behind an Ingress"
ING=(--set ingress.enabled=true --set 'ingress.hosts[0].host=x.example'
     --set 'ingress.hosts[0].paths[0].path=/' --set 'ingress.hosts[0].paths[0].pathType=Prefix')
INGLC=("${ING[@]}" --set localCluster.id=$LC_ID --set localCluster.token=$LC_TOK)
has   "Ingress + localCluster: web Service https" 'name: https' "${INGLC[@]}" --show-only templates/service.yaml
has   "Ingress + localCluster: pod listens on 8443" 'containerPort: 8443' "${INGLC[@]}" --show-only templates/deployment-web.yaml
envis "Ingress + localCluster: web serves TLS"   WEB_TLS_SELF_SIGNED true "${INGLC[@]}"
envis "Ingress + localCluster: in-cluster URL"   RADAR_HUB_IN_CLUSTER_AGENT_URL wss://t-radar-hub-web.default.svc.cluster.local/agent "${INGLC[@]}"
envis "existingSecret alone keeps the URL too"   RADAR_HUB_IN_CLUSTER_AGENT_URL wss://t-radar-hub-web.default.svc.cluster.local/agent "${ING[@]}" --set localCluster.id=$LC_ID --set localCluster.existingSecret=lc
lacks "Ingress + localCluster: public cert not skipped" 'name: RADAR_HUB_INSECURE_SKIP_VERIFY' "${INGLC[@]}"
lacks "Ingress + localCluster: readiness stays http" 'scheme: HTTPS' "${INGLC[@]}" --show-only templates/deployment-web.yaml
has   "Ingress + localCluster: Ingress targets http" 'number: 80$' "${INGLC[@]}" --show-only templates/ingress.yaml
lacks "Ingress + localCluster: not browser-only" 'name: RADAR_HUB_BROWSER_ONLY_URL' "${INGLC[@]}"
envis "Ingress + localCluster: origins are publicURL" HUB_ALLOWED_ORIGINS https://x.example "${INGLC[@]}"
INGIC=("${ING[@]}" --set web.tls.inCluster=true)
has   "Ingress + inCluster: web Service https"   'name: https' "${INGIC[@]}" --show-only templates/service.yaml
has   "Ingress + inCluster: pod listens on 8443" 'containerPort: 8443' "${INGIC[@]}" --show-only templates/deployment-web.yaml
envis "Ingress + inCluster: web serves TLS"      WEB_TLS_SELF_SIGNED true "${INGIC[@]}"
envis "Ingress + inCluster: in-cluster URL"      RADAR_HUB_IN_CLUSTER_AGENT_URL wss://t-radar-hub-web.default.svc.cluster.local/agent "${INGIC[@]}"
lacks "Ingress + inCluster: public cert not skipped" 'name: RADAR_HUB_INSECURE_SKIP_VERIFY' "${INGIC[@]}"
lacks "Ingress + inCluster: readiness stays http" 'scheme: HTTPS' "${INGIC[@]}" --show-only templates/deployment-web.yaml
has   "Ingress + inCluster: Ingress targets http" 'number: 80$' "${INGIC[@]}" --show-only templates/ingress.yaml
check "web.tls.inClusterr (typo)"               refuse --set web.tls.inClusterr=true
ING=("${ING[@]}" --set web.tls.inCluster=false)
lacks "Ingress alone: no web Service https"      'name: https' "${ING[@]}" --show-only templates/service.yaml
lacks "Ingress alone: no 8443 listener"          'containerPort: 8443' "${ING[@]}" --show-only templates/deployment-web.yaml
lacks "Ingress alone: web serves no TLS"         'name: WEB_TLS_SELF_SIGNED' "${ING[@]}"
lacks "Ingress alone: no in-cluster URL"         'name: RADAR_HUB_IN_CLUSTER_AGENT_URL' "${ING[@]}"


echo "the licence reaches /etc/radar-hub either way"
has   "license.key lands in the chart Secret"   'license-key: "eyJtest"'       --set license.key=eyJtest
has   "license.key is mounted"                  'mountPath: /etc/radar-hub'    --set license.key=eyJtest
has   "license.key volume uses the chart Secret" 'secretName: "t-radar-hub-config"'   --set license.key=eyJtest
has   "existingSecret is mounted"               'mountPath: /etc/radar-hub'    --set license.existingSecret=my-lic
has   "existingSecret volume names that Secret" 'secretName: "my-lic"'         --set license.existingSecret=my-lic
lacks "existingSecret writes no key to the chart Secret" 'license-key:'        --set license.existingSecret=my-lic
lacks "no licence, no mount"                    'mountPath: /etc/radar-hub'

# The restart command in the install notes must name the Deployment that
# exists. The Deployment name is truncated to Kubernetes' limit; a notes line
# that rebuilds it from parts is not, and diverges exactly when names get long.
#
# `helm template` never renders NOTES.txt and `helm install --dry-run` prints
# it differently across Helm versions, so the notes are rendered through `tpl`
# from a scratch copy of the chart, inside a template shaped as YAML because
# Helm validates every rendered template as a manifest.
echo "install notes name the real hub Deployment"
scratch="$(mktemp -d)"; cp -R . "$scratch/chart"; cp templates/NOTES.txt "$scratch/chart/notes-copy.txt"
printf 'kind: NotesCheck\nnotes: |\n{{ tpl (.Files.Get "notes-copy.txt") . | indent 2 }}\n' > "$scratch/chart/templates/notes-rendered.yaml"
for rel in t a-release-name-long-enough-to-force-truncation-x50; do
  want="$(helm template "$rel" . "${BASE[@]}" --show-only templates/deployment-hub.yaml 2>/dev/null | awk '/^  name:/{print $2; exit}')"
  got="$(helm template "$rel" "$scratch/chart" "${BASE[@]}" --set license.existingSecret=x --show-only templates/notes-rendered.yaml 2>/dev/null | grep -oE 'rollout restart deploy/[^ ]+' | sed 's#.*deploy/##' | head -1)"
  if [ -n "$want" ] && [ "$want" = "$got" ]; then printf '  ok    %-46s %s\n' "release $rel" "$got"
  else printf '  FAIL  %-46s notes say %s, Deployment is %s\n' "release $rel" "${got:-nothing}" "${want:-nothing}"; fails=$((fails+1)); fi
done
echo "install notes for a localhost publicURL"
notes() { helm template t "$scratch/chart" "${BASE[@]}" "$@" --show-only templates/notes-rendered.yaml 2>/dev/null; }
note_has() { # note_has <description> <fixed string> <extra args...>
  local desc="$1" want="$2"; shift 2
  if notes "$@" | grep -qF -- "$want"; then printf '  ok    %-46s %s\n' "$desc" "$want"
  else printf '  FAIL  %-46s missing: %s\n' "$desc" "$want"; fails=$((fails+1)); fi
}
note_lacks() { # note_lacks <description> <fixed string> <extra args...>
  local desc="$1" bad="$2"; shift 2
  if notes "$@" | grep -qiF -- "$bad"; then printf '  FAIL  %-46s present but must not be: %s\n' "$desc" "$bad"; fails=$((fails+1))
  else printf '  ok    %-46s absent\n' "$desc"; fi
}
note_has   "port-forward on the URL's port"       'port-forward svc/t-radar-hub-web 8443:443' "${LH[@]}" "${SS[@]}"
note_has   "port-forward follows tlsPort"         'port-forward svc/t-radar-hub-web 8443:9443' "${LH[@]}" "${SS[@]}" --set service.web.tlsPort=9443
note_has   "port-forward on a custom URL port"    'port-forward svc/t-radar-hub-web 9443:443' --set hub.publicURL=https://localhost:9443 "${SS[@]}"
# kubectl binds 127.0.0.1 and ::1 by default; any other IP must be named.
note_has   "port-forward binds 0.0.0.0"           'port-forward --address 0.0.0.0 svc/t-radar-hub-web 8443:443' --set hub.publicURL=https://0.0.0.0:8443 "${SS[@]}"
note_has   "port-forward binds ::"                'port-forward --address :: svc/t-radar-hub-web 8443:443' --set 'hub.publicURL=https://[::]:8443' "${SS[@]}"
note_has   "port-forward binds 127.0.0.2"         'port-forward --address 127.0.0.2 svc/t-radar-hub-web 8443:443' --set hub.publicURL=https://127.0.0.2:8443 "${SS[@]}"
note_lacks "no --address for localhost"           '--address' "${LH[@]}" "${SS[@]}"
note_lacks "no --address for *.localhost"         '--address' --set hub.publicURL=https://radar.localhost:8443 "${SS[@]}"
note_lacks "no --address for 127.0.0.1"           '--address' --set hub.publicURL=https://127.0.0.1:8443 "${SS[@]}"
note_lacks "no --address for [::1]"               '--address' --set 'hub.publicURL=https://[::1]:8443' "${SS[@]}"
note_has   "port-forward for [::1]"               'port-forward svc/t-radar-hub-web 8443:443' --set 'hub.publicURL=https://[::1]:8443' "${SS[@]}"
note_has   "port-forward defaults to 443"         'port-forward svc/t-radar-hub-web 443:443' --set hub.publicURL=https://127.0.0.1 "${SS[@]}"
note_has   "open the exact URL"                   'Then open https://localhost:9443.' --set hub.publicURL=https://localhost:9443 "${SS[@]}"
note_lacks "no port-forward for a public URL"     'port-forward' "${SS[@]}"
note_lacks "no port-forward behind an Ingress"    'port-forward' "${LH[@]}" "${ING[@]}"
note_lacks "notes never say one cluster"          'one cluster' "${LH[@]}" "${SS[@]}"
note_lacks "notes never say one cluster (local)"  'one cluster' "${LH[@]}" "${SS[@]}" --set localCluster.id=k3Fg-9pA_x1 --set localCluster.existingSecret=lc
echo "install notes print the in-cluster agent address"
note_has "selfSigned"                    'wss://t-radar-hub-web.default.svc.cluster.local/agent' --set web.tls.selfSigned=true
note_has "Ingress + inCluster"           'wss://t-radar-hub-web.default.svc.cluster.local/agent' "${INGIC[@]}"
note_has "Ingress + localCluster"        'wss://t-radar-hub-web.default.svc.cluster.local/agent' "${INGLC[@]}"
note_has "fullnameOverride, tlsPort, clusterDomain" 'wss://rh-web.default.svc.c.internal:9443/agent' "${INGLC[@]}" --set fullnameOverride=rh --set service.web.tlsPort=9443 --set clusterDomain=c.internal
if notes "${ING[@]}" | grep -qF "In-cluster agent address"; then printf '  FAIL  %-46s present but must not be\n' "no in-cluster address without a listener"; fails=$((fails+1))
else printf '  ok    %-46s absent\n' "no in-cluster address without a listener"; fi
rm -rf "$scratch"

echo
if [ $fails -eq 0 ]; then echo "all checks passed"; else echo "$fails check(s) failed"; fi
exit $fails

