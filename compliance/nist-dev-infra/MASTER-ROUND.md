# One reboot round on the masters: 40 CPUs and USBGuard

nist-dev-infra flaps under FIPS (README.md, stage D). jetty, also FIPS but
with 40-CPU masters, does not; oac-dev-infra, with the same 176-CPU FC830s
but no FIPS, does not either. This round boots the masters with 40 CPUs
to test whether core count is the difference, and fixes USBGuard in the
same reboot.

The upgrade to 4.22.18 is left for a round of its own, so each change can
be judged alone.

| File | What |
|---|---|
| `nr-cpus-machineconfig.yaml` | `nr_cpus=40` on the masters |
| `usbguard-enable-machineconfig.yaml` | Enables `usbguard.service` at boot |

## Before

- All three masters Ready for at least 15 minutes, and etcd healthy:
  `oc get nodes`, `oc get pods -n openshift-etcd -l app=etcd`.
- The hosted cluster stays paused and scaled to 0, so its pods do not move
  with the drains.
- Someone can reach the hub's BMCs, in case a node does not come back.

## Steps

```
K="--kubeconfig $HOME/kubeadmin-nist-dev-infra"

# 1. Pause the master pool, so both MachineConfigs land as one rendered
#    config and each master reboots once.
oc $K patch mcp master --type merge -p '{"spec":{"paused":true}}'

# 2. Apply both, after a server-side dry run.
oc $K apply --dry-run=server -f nr-cpus-machineconfig.yaml -f usbguard-enable-machineconfig.yaml
oc $K apply -f nr-cpus-machineconfig.yaml -f usbguard-enable-machineconfig.yaml

# 3. Check the new rendered config has both, then unpause.
oc $K get mcp master -o jsonpath='{.spec.configuration.name}{"\n"}'
oc $K get mc <that name> -o jsonpath='{.spec.kernelArguments}{"\n"}'   # includes nr_cpus=40
oc $K patch mcp master --type merge -p '{"spec":{"paused":false}}'

# 4. Watch. Each master drains, reboots and returns in turn.
oc $K get mcp master -w
```

## During

- A drain moves a master's pods and connections to the other two. In
  stage C this crashed etcd on the receiving nodes and once took the API
  away for about 10 minutes; it recovered without intervention.
- To stop between nodes, pause the pool again (step 1). The node in
  progress finishes; the rest wait.
- A kubelet that stops reporting for more than 10 minutes while its node
  answers can be restarted (`systemctl restart kubelet`), as on u13 on
  2026-10-21.

## After

On each master:

```
oc $K get node <node> -o jsonpath='{.status.capacity.cpu}{"\n"}'        # 40
oc $K debug node/<node> -- chroot /host systemctl is-enabled usbguard   # enabled
```

Then watch the hub for a few hours: NotReady spells, etcd and
kube-apiserver restarts, and thread counts (`container_threads` for etcd
and kube-apiserver; the kubelet's from `/proc`). Rescan: the node scans'
`service-usbguard-enabled` should pass.

## Undo

Delete `99-master-nr-cpus` (and, if needed, `99-master-usbguard-enable`).
That is another reboot round.
