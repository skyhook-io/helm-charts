#!/usr/bin/env bash
# What the chart accepts and refuses, as an executable check.
#
# Two guards live here and neither is visible from reading a values file:
#   - air-gapped requires a hub image this chart can PROVE is >= 1.5.0
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

echo "air-gapped requires a provable >= 1.5.0 tag"
for tag in 1.5.0 1.5.3 2.0.0; do
  check "airGapped + $tag" render --set hub.airGapped=true --set image.hub.tag="$tag"
done
# Refused because they cannot be CHECKED, not because they are necessarily old.
for tag in 1.4.2 v1.4.2 1.4 0.9.0 latest sha-abc123 1.5.0-rc1; do
  check "airGapped + $tag" refuse --set hub.airGapped=true --set image.hub.tag="$tag"
done
check "old tag with airGapped off" render --set hub.airGapped=false --set image.hub.tag=1.4.2

echo "unknown keys are refused, not ignored"
check "hub.airgapped (lowercase g)"  refuse --set hub.airgapped=true
check "hubb.publicURL (top-level)"   refuse --set hubb.publicURL=x
check "image.hub.tagg"               refuse --set image.hub.tagg=1.5.0
check "auth.breakGlass.emial"        refuse --set auth.breakGlass.emial=a@b.c

echo "legitimate values still render"
check "image.hub.tag"                render --set image.hub.tag=1.5.0
# Helm reserves `global` for umbrella charts and the parent owns its shape,
# so closing the root schema must not close this. It did, briefly.
check "global.imageRegistry"         render --set global.imageRegistry=my.registry.io
check "global.deeply.nested"         render --set global.deeply.nested=1
# A free-form map the operator fills (IRSA and friends).
check "serviceAccount annotation"    render --set 'serviceAccount.annotations.eks\.amazonaws\.com/role-arn=arn:x'

echo
if [ $fails -eq 0 ]; then echo "all checks passed"; else echo "$fails check(s) failed"; fi
exit $fails
