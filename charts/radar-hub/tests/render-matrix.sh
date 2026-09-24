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

echo "the self-signed certificate is told the public host"
envis "selfSigned passes the host, without the port" WEB_TLS_SELF_SIGNED_HOST radar.acme.example --set web.tls.selfSigned=true --set hub.publicURL=https://radar.acme.example:8443
envis "selfSigned passes a bare host"               WEB_TLS_SELF_SIGNED_HOST x.example         --set web.tls.selfSigned=true
lacks "no host env without selfSigned"            'name: WEB_TLS_SELF_SIGNED_HOST'

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
rm -rf "$scratch"

echo
if [ $fails -eq 0 ]; then echo "all checks passed"; else echo "$fails check(s) failed"; fi
exit $fails

