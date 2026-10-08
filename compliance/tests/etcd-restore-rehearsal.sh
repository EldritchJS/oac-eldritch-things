#!/usr/bin/env bash
# etcd restore rehearsal — does the newest backup actually restore?
#
# MUTATING, but only by one temporary pod in the etcd-backup namespace. It
# does NOT touch the control plane, the live etcd members, or the backups
# (the backup volume is mounted read-only).
#
# What it proves, beyond the integrity checks T-14 and the backup job do:
#   1. The snapshot restores with etcdutl into a fresh data dir (the step the
#      real recovery procedure runs on a master).
#   2. A real etcd server starts on the restored data and serves it.
#   3. The restored keyspace matches live etcd by resource type, allowing
#      for churn since the backup was taken.
#   4. Every Secret and ConfigMap in it is aesgcm-encrypted, and every key
#      name they reference is present in the backup's own encryption-config,
#      i.e. the backup carries what it needs to decrypt itself. Only key
#      NAMES are read; key material never leaves the pod and is never printed.
#
# What it does NOT prove: the full disaster-recovery procedure
# (cluster-restore.sh on a master, static pods stopped, the other members
# re-added). That takes the API down and belongs on a disposable cluster.
#
# Isolation: the pod runs in etcd-backup, which has default-deny ingress and
# egress NetworkPolicies, and the rehearsal etcd listens on 127.0.0.1 only.
# The restored data sits on an emptyDir and is discarded with the pod. The
# pod is deleted on exit (trap), and also self-terminates after 1h.
#
# Usage: ./etcd-restore-rehearsal.sh [<backup-dir-name>]   (default: newest)
set -uo pipefail

NS=etcd-backup
POD="etcd-restore-rehearsal-$(date -u +%Y%m%d%H%M%S)"
WANT="${1:-}"

command -v oc >/dev/null || { echo "oc not found" >&2; exit 2; }
oc whoami >/dev/null 2>&1 || { echo "not logged in (set KUBECONFIG)" >&2; exit 2; }

hdr() { printf '\n== %s ==\n' "$*"; }
die() { printf 'FAIL %s\n' "$*" >&2; exit 1; }

# The release's own etcd image: signature-verified by the built-in openshift
# ClusterImagePolicy, and the same etcd/etcdutl version a real restore uses.
IMG=$(oc adm release info --image-for=etcd) || die "cannot resolve etcd image"
LIVE=$(oc get pods -n openshift-etcd -l app=etcd -o jsonpath='{.items[0].metadata.name}')
[ -n "$LIVE" ] || die "no live etcd pod found"

OUT=$(mktemp)
cleanup() { oc delete pod "$POD" -n "$NS" --ignore-not-found --wait=false >/dev/null 2>&1; rm -f "$OUT"; }
trap cleanup EXIT

hdr "creating $POD"
oc apply -f - <<EOF >/dev/null || die "pod create failed"
apiVersion: v1
kind: Pod
metadata:
  name: $POD
  namespace: $NS
  labels: {app: etcd-restore-rehearsal}
spec:
  # Root is needed to read the 0600 root-owned backups; the etcd-backup SA's
  # privileged SCC permits it. Nothing else privileged: no host namespaces,
  # no host mounts, no capabilities.
  serviceAccountName: etcd-backup
  restartPolicy: Never
  activeDeadlineSeconds: 3600
  containers:
    - name: rehearsal
      image: $IMG
      command: ["sleep", "3600"]
      securityContext:
        runAsUser: 0
        privileged: false
        allowPrivilegeEscalation: false
        capabilities: {drop: [ALL]}
      resources:
        requests: {cpu: 500m, memory: 1Gi}
        limits: {cpu: "2", memory: 4Gi}
      volumeMounts:
        - {name: backup, mountPath: /backup, readOnly: true}
        - {name: restore, mountPath: /restore}
  volumes:
    - name: backup
      persistentVolumeClaim: {claimName: etcd-backup, readOnly: true}
    - name: restore
      emptyDir: {sizeLimit: 4Gi}
EOF
oc wait pod "$POD" -n "$NS" --for=condition=Ready --timeout=300s >/dev/null || die "pod not Ready"
echo "on node $(oc get pod "$POD" -n "$NS" -o jsonpath='{.spec.nodeName}')"

# ---- inside the pod: verify, restore, serve, inspect ------------------------
hdr "restore"
# -i is essential: without it oc exec sends no stdin, `bash -s` runs an EMPTY
# script and exits 0 -- a silent pass. Each block must also print a DONE
# sentinel, checked below, so a block that did not run cannot look green.
oc exec -i -n "$NS" "$POD" -- env WANT="$WANT" bash -s >"$OUT" 2>&1 <<'EOS'

set -euo pipefail
cd /backup
d="${WANT:-$(ls -1d 20*/ | sort | tail -1)}"; d="${d%/}"
[ -d "$d" ] || { echo "no backup dir $d"; exit 1; }
echo "backup: $d"
( cd "$d" && sha256sum -c --quiet SHA256SUMS ) && echo "checksums: OK"
snap=$(ls "$d"/snapshot_*.db)
etcdutl snapshot status "$snap" -w table

t0=$(date +%s)
etcdutl snapshot restore "$snap" --data-dir /restore/data --name rehearsal \
  --initial-cluster rehearsal=http://127.0.0.1:2380 \
  --initial-advertise-peer-urls http://127.0.0.1:2380 >/restore/restore.log 2>&1 \
  || { tail -20 /restore/restore.log; exit 1; }
echo "etcdutl restore: OK in $(( $(date +%s) - t0 ))s ($(du -sh /restore/data | cut -f1))"

etcd --name rehearsal --data-dir /restore/data \
  --listen-client-urls http://127.0.0.1:2379 --advertise-client-urls http://127.0.0.1:2379 \
  --listen-peer-urls http://127.0.0.1:2380 --listen-metrics-urls http://127.0.0.1:2381 \
  >/restore/etcd.log 2>&1 &
for i in $(seq 1 60); do
  etcdctl --endpoints=127.0.0.1:2379 endpoint health >/dev/null 2>&1 && break; sleep 1
done
etcdctl --endpoints=127.0.0.1:2379 endpoint health >/dev/null 2>&1 \
  || { echo "rehearsal etcd did not become healthy"; tail -20 /restore/etcd.log; exit 1; }
echo "etcd serving restored data: OK (started in $(( $(date +%s) - t0 ))s from restore start)"
etcdctl --endpoints=127.0.0.1:2379 endpoint status -w table

etcdctl --endpoints=127.0.0.1:2379 get / --prefix --keys-only \
  | awk -F/ 'NF>2{print "/"$2"/"$3}' | sort | uniq -c | awk '{print $2"\t"$1}' > /restore/restored-counts.tsv
echo "restored keys: $(awk -F'\t' '{s+=$2} END{print s}' /restore/restored-counts.tsv)"
echo REHEARSAL-STEP-DONE
EOS
rc=$?; grep -v REHEARSAL-STEP-DONE "$OUT"
[ $rc -eq 0 ] && grep -q REHEARSAL-STEP-DONE "$OUT" || die "restore steps failed"

# ---- encryption: every Secret/ConfigMap encrypted with a key the backup holds
hdr "encryption at rest in the restored data"
oc exec -i -n "$NS" "$POD" -- env WANT="$WANT" bash -s >"$OUT" 2>&1 <<'EOS'

set -euo pipefail
d="/backup/${WANT:-$(cd /backup && ls -1d 20*/ | sort | tail -1)}"
tarball=$(ls "$d"/static_kuberesources_*.tar.gz)
# tail, not grep -m1: an early-exiting reader SIGPIPEs tar (141) under pipefail.
member=$(tar tzf "$tarball" | grep 'secrets/encryption-config/encryption-config$' | tail -1)
[ -n "$member" ] || { echo "no encryption-config in $tarball"; exit 1; }
# Key NAMES only. The config is read into python on stdin and never printed.
tar xzOf "$tarball" "$member" | python3 -c '
import json, re, sys
raw = sys.stdin.read()
names, resources = set(), set()
try:
    cfg = json.loads(raw)
    for r in cfg.get("resources", []):
        resources.update(r.get("resources", []))
        for p in r.get("providers", []):
            for kind, body in p.items():
                for k in (body or {}).get("keys", []):
                    names.add(kind + ":" + str(k["name"]))
except ValueError:
    # YAML form: provider kind lines then "- name: X". Names only.
    kind = None
    for line in raw.splitlines():
        m = re.match(r"\s*-?\s*(aesgcm|aescbc|secretbox|kms):\s*$", line)
        if m: kind = m.group(1)
        m = re.match(r"\s*-\s*name:\s*\"?([^\"\s]+)", line)
        if m and kind: names.add(kind + ":" + m.group(1))
open("/restore/keynames", "w").write("\n".join(sorted(names)))
print("encryption-config in backup: key names", sorted(names),
      "| resources", sorted(resources) or "(yaml, not parsed)")
'
for res in secrets configmaps; do
  etcdctl --endpoints=127.0.0.1:2379 get "/kubernetes.io/$res/" --prefix -w json \
  | python3 -c '
import base64, json, sys
res = sys.argv[1]
known = set(open("/restore/keynames").read().split())
kvs = json.load(sys.stdin).get("kvs", [])
seen, plain = {}, 0
for kv in kvs:
    v = base64.b64decode(kv["value"])
    if not v.startswith(b"k8s:enc:"):
        plain += 1; continue
    parts = v.split(b":", 5)          # k8s enc <provider> v1 <keyname> <ciphertext>
    tag = parts[2].decode() + ":" + parts[4].decode()
    seen[tag] = seen.get(tag, 0) + 1
missing = [t for t in seen if t not in known]
print(f"{res}: {len(kvs)} keys, plaintext {plain}, by key {seen}",
      "| all key names present in backup" if not missing else f"| MISSING {missing}")
sys.exit(1 if (plain or missing) else 0)
' "$res"
done
rm -f /restore/keynames
echo REHEARSAL-STEP-DONE
EOS
rc=$?; grep -v REHEARSAL-STEP-DONE "$OUT"
[ $rc -eq 0 ] && grep -q REHEARSAL-STEP-DONE "$OUT" || die "encryption check failed"

# ---- compare with live etcd by resource type --------------------------------
hdr "restored vs live, by resource type"
oc exec -n "$NS" "$POD" -- cat /restore/restored-counts.tsv > "${TMPDIR:-/tmp}/$POD.restored" \
  || die "no restored counts"
oc exec -n openshift-etcd "$LIVE" -c etcdctl -- sh -c \
  'etcdctl get / --prefix --keys-only | awk -F/ "NF>2{print \"/\"\$2\"/\"\$3}" | sort | uniq -c | awk "{print \$2\"\t\"\$1}"' \
  > "${TMPDIR:-/tmp}/$POD.live" || die "live key count failed"
python3 - "${TMPDIR:-/tmp}/$POD.restored" "${TMPDIR:-/tmp}/$POD.live" <<'EOP'
import sys
def load(p): return {k: int(v) for k, v in (l.split("\t") for l in open(p).read().split("\n") if l)}
r, l = load(sys.argv[1]), load(sys.argv[2])
only_live = sorted(set(l) - set(r)); only_rest = sorted(set(r) - set(l))
print(f"types: restored {len(r)}, live {len(l)}; keys: restored {sum(r.values())}, live {sum(l.values())}")
diffs = sorted(((k, r.get(k, 0), l.get(k, 0)) for k in set(r) | set(l)), key=lambda t: -abs(t[2]-t[1]))
print("largest differences (type, restored, live):")
for k, a, b in diffs[:12]:
    if a != b: print(f"  {k:60s} {a:6d} {b:6d}")
print("types only in live:", only_live or "none")
print("types only in restored:", only_rest or "none")
for k in ("/kubernetes.io/namespaces", "/kubernetes.io/secrets",
          "/kubernetes.io/apiextensions.k8s.io", "/kubernetes.io/machineconfiguration.openshift.io"):
    print(f"  {k:60s} restored {r.get(k,0):6d}  live {l.get(k,0):6d}")
EOP
rm -f "${TMPDIR:-/tmp}/$POD.restored" "${TMPDIR:-/tmp}/$POD.live"

hdr "cleanup"
oc exec -n "$NS" "$POD" -- sh -c 'pkill etcd; true' >/dev/null 2>&1
cleanup; trap - EXIT
oc wait pod "$POD" -n "$NS" --for=delete --timeout=120s >/dev/null 2>&1 && echo "pod deleted, restored data discarded"
