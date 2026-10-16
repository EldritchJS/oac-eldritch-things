#!/usr/bin/env bash
# Hub infrastructure preflight: checks BUILD.md I2 to I6 for one hub.
#
# READ-ONLY. It reads AWS Secrets Manager metadata (never secret values),
# fetches the hub's public OIDC document, and reads the hub's API.
#
# Usage:
#   KUBECONFIG=... AWS_PROFILE=... ./hub-preflight.sh <hub>
#
# <hub> is the name used in AWS and oac-apps (cluster/<hub>/..., values/<hub>/).
# Run it before calling any step done, and before re-syncing hub-portworx.
#
# Exit: 0 all passed, 1 one or more FAILed. SKIP does not fail the run.
set -uo pipefail

HUB="${1:-}"
[ -z "$HUB" ] || [ "$HUB" = "-h" ] && { sed -n '2,13p' "$0"; exit 2; }
AWS_REGION="${AWS_REGION:-us-east-1}"
S3_BUCKET="${S3_BUCKET:-oac-clusters-oidc}"
ISSUER="https://${S3_BUCKET}.s3.${AWS_REGION}.amazonaws.com/${HUB}"
GITOPS_NS=openshift-gitops

PASS=0; FAIL=0; SKIP=0
if [ -t 1 ]; then G=$'\e[32m'; R=$'\e[31m'; B=$'\e[1m'; N=$'\e[0m'
else G=""; R=""; B=""; N=""; fi
hdr()  { printf '\n%s== %s ==%s\n' "$B" "$*" "$N"; }
ok()   { printf '  %sPASS%s %s\n' "$G" "$N" "$*"; PASS=$((PASS+1)); }
bad()  { printf '  %sFAIL%s %s\n' "$R" "$N" "$*"; FAIL=$((FAIL+1)); }
skip() { printf '  SKIP %s\n' "$*"; SKIP=$((SKIP+1)); }
info() { printf '       %s\n' "$*"; }

secret_exists() {
  aws secretsmanager describe-secret --region "$AWS_REGION" \
    --secret-id "$1" --query Name --output text >/dev/null 2>&1
}

# ArgoCD's Application, by full name: ACM installs a second Application
# type (app.k8s.io), and plain `oc get applications` lists that one.
app_state() {
  oc get applications.argoproj.io "$1" -n "$GITOPS_NS" \
    -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null
}

# Without a working AWS session every secret looks missing. Say so instead.
if aws sts get-caller-identity --region "$AWS_REGION" >/dev/null 2>&1; then
  hdr "I2  Realm playbook: Portworx secret"
  if secret_exists "cluster/${HUB}/portworx"; then ok "cluster/${HUB}/portworx exists"
  else bad "cluster/${HUB}/portworx missing: the realm playbook has not run"; fi

  hdr "I3  moc-aws: OIDC roles applied"
  if secret_exists "cluster/${HUB}/aws-oidc"; then ok "cluster/${HUB}/aws-oidc exists (written by the moc-aws module)"
  else bad "cluster/${HUB}/aws-oidc missing: the moc-aws entry is not applied"; fi
else
  hdr "I2, I3  AWS"
  bad "no AWS session (set AWS_PROFILE; for SSO, run aws sso login): I2 and I3 not checked"
fi

hdr "I4  setup-oidc.sh: keys published, issuer set"
code=$(curl -s -o /dev/null -w '%{http_code}' "${ISSUER}/.well-known/openid-configuration")
if [ "$code" = 200 ]; then ok "OIDC document is public"
else bad "OIDC document returns HTTP ${code}: setup-oidc.sh has not uploaded it"; fi
current=$(oc get authentication cluster -o jsonpath='{.spec.serviceAccountIssuer}' 2>/dev/null)
if [ "$current" = "$ISSUER" ]; then ok "serviceAccountIssuer matches"
else bad "serviceAccountIssuer is '${current}', expected ${ISSUER}"; fi

hdr "I5  Storage VLAN: DHCP lease on each node's br-storage"
nodes=$(oc get nncp -o jsonpath='{range .items[*]}{.spec.nodeSelector.kubernetes\.io/hostname}{"\n"}{end}' 2>/dev/null | grep -v '^$')
if [ -z "$nodes" ]; then
  skip "no storage bridges yet: they come with the hub's portworx values (I6)"
else
  for n in $nodes; do
    addr=$(oc get nns "$n" -o jsonpath='{range .status.currentState.interfaces[?(@.name=="br-storage")].ipv4.address[*]}{.ip}{" "}{end}' 2>/dev/null)
    if [ -n "$addr" ]; then ok "$n has a lease"
    else bad "$n has no lease: check the switch port is untagged on the storage VLAN, and that DHCP reaches it"; fi
  done
fi

hdr "I6  The hub's values: ArgoCD and storage"
for a in hub-external-secrets hub-portworx; do
  s=$(app_state "$a")
  if [ "$s" = "Synced/Healthy" ]; then ok "$a $s"
  else bad "$a ${s:-not found}"; fi
done
es=$(oc get externalsecret px-pure-secret -n portworx -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
if [ "$es" = True ]; then ok "ExternalSecret px-pure-secret Ready"
else bad "ExternalSecret px-pure-secret not Ready: AWS does not accept the hub's identity yet (I3, I4)"; fi
default_sc=$(oc get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{" "}{end}' 2>/dev/null)
if [ -n "$default_sc" ]; then ok "default StorageClass: ${default_sc}"
else bad "no default StorageClass"; info "if I2 to I5 pass, re-sync hub-portworx: ArgoCD does not retry a failed sync of the same commit"; fi

printf '\n%sPASS %d  FAIL %d  SKIP %d%s\n' "$B" "$PASS" "$FAIL" "$SKIP" "$N"
[ "$FAIL" -eq 0 ]
