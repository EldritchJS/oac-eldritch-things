#!/bin/bash
# Render the compliance charts with jetty's values and compare them with
# the live cluster.
#
#   scripts/validate.sh <oac-apps checkout> [--diff-jetty]
#
# The checkout is a clone of the fork with the charts in it (the
# compliance-charts branch). It is copied to a scratch directory and not
# touched. Steps:
#
# 1. Apply patches/*.patch to the copy (the on-hold cluster-certificates
#    change).
# 2. Upstream's own CI steps: helm-update-deps.sh, helm-lint-all.sh and,
#    if the helm-unittest plugin is installed, helm-unittest-all.sh.
# 3. helm template each chart with values/oac-dev-infra/jetty/<chart>.yaml.
# 4. --diff-jetty: `oc diff` each render against $KUBECONFIG. oc diff is a
#    server-side dry run; it changes nothing.
#
# Needs helm 3 and, for --diff-jetty, oc logged in to jetty.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
src=${1:?usage: $0 <oac-apps checkout> [--diff-jetty]}
diff_jetty=${2:-}
work=$(mktemp -d "${TMPDIR:-/tmp}/oac-apps-validate.XXXXXX")
trap 'rm -rf "$work"' EXIT

cp -R "$src"/. "$work"/
for p in "$here"/patches/*.patch; do
  [[ -e $p ]] || continue
  git -C "$work" apply "$p"
  echo "applied $(basename "$p")"
done

cd "$work"
fail=0
bash scripts/helm-update-deps.sh
if bash scripts/helm-lint-all.sh >/dev/null; then echo "lint ok (all charts)"; else bash scripts/helm-lint-all.sh || true; fail=1; fi
if helm plugin list 2>/dev/null | grep -q unittest; then
  bash scripts/helm-unittest-all.sh | grep -E '^(Charts|Test Suites|Tests):' || fail=1
fi

mkdir -p "$here/.render"
for f in "$here"/values/oac-dev-infra/jetty/*.yaml; do
  chart=$(basename "$f" .yaml)
  out="$here/.render/jetty-$chart.yaml"
  if [[ ! -d charts/$chart ]]; then
    echo "missing     charts/$chart (is the checkout on the compliance-charts branch?)"
    fail=1
    continue
  fi
  if helm template "jetty-$chart" "charts/$chart" -f "$f" > "$out"; then
    echo "template ok $chart ($(grep -c '^kind:' "$out") objects)"
  else
    fail=1
    continue
  fi
  if [[ $diff_jetty == --diff-jetty ]]; then
    if oc diff -f "$out" > "$out.diff" 2>&1; then
      echo "  oc diff: none"
    elif [[ $? -eq 1 ]]; then
      # ArgoCD's own annotations and the generation bump are expected.
      n=$(grep -E '^[-+]' "$out.diff" | grep -v -E '^(---|\+\+\+) ' | grep -v -E 'argocd\.argoproj\.io/|^[-+]  generation: ' | grep -c . || true)
      if [[ $n -eq 0 ]]; then
        echo "  oc diff: ArgoCD annotations only"
      else
        echo "  oc diff: $n changed lines -> .render/$(basename "$out").diff"
      fi
    else
      echo "  oc diff: error"; sed 's/^/    /' "$out.diff"; fail=1
    fi
  fi
done

exit $fail
