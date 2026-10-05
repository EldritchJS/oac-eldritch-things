# VM Testing

Test suites for OpenShift Virtualization:

- **Networking** (`test-vm.sh`, `net-test-vm.yaml`) — a CirrOS VM on an ephemeral `containerDisk`, checking egress and inbound reachability.
- **Persistent storage** (`test-vm-storage.sh`) — a Fedora VM on a CDI-provisioned PVC, checking that guest data survives a stop/start.
- **Live migration** (`test-vm-migration.sh`) — the same VM moved between nodes while running, checking that the guest never reboots.
- **GPU passthrough** ([`gpu/`](gpu/)) — handing a VM a physical H100, and measuring what it costs to move a node between serving containers and serving VMs. Separate directory because it is largely admin work and because a GPU VM behaves differently from everything above: it cannot live migrate.

## Prerequisites

All three require `oc` and `virtctl`, authenticated to the target cluster, with OpenShift Virtualization installed (see `component-checks/oc-virt-checks.sh`). `virtctl` is not bundled with `oc`; get its download URL with:

```bash
oc get consoleclidownload virtctl-clidownloads-kubevirt-hyperconverged -o jsonpath='{.spec.links[*].href}'
```

The scripts run entirely as the logged-in user — no `--as system:admin` anywhere — so what they prove is what a real project user can actually do. Creating VMs, DataVolumes and PVCs works with ordinary namespace edit rights, but **migration does not**, and needs a one-time RBAC grant.

### One-time: migration RBAC

KubeVirt ships no role that delegates migration. Neither `kubevirt.io:edit` nor `kubevirt.io:admin` includes the `virtualmachines/migrate` subresource or `create` on `VirtualMachineInstanceMigration` — both only get `get`/`list`/`watch` — so it is cluster-admin-only until granted explicitly. Without it `virtctl migrate` fails with:

```
virtualmachines.subresources.kubevirt.io "my-vm" is forbidden: User "you@example.com"
cannot update resource "virtualmachines/migrate" in API group "subresources.kubevirt.io"
```

`migrate-rbac.yaml` creates a namespaced Role and RoleBinding granting exactly the two permissions needed. A cluster admin applies it once per namespace:

```bash
oc process --local -f migrate-rbac.yaml \
  -p NAMESPACE=mm-test \
  -p USER_NAME=$(oc whoami) \
  | oc apply --as system:admin -f -
```

`--local` matters: without it `oc process` tries to create a `processedtemplates` object in `default` and is denied.

| Rule | Grants |
|------|--------|
| `subresources.kubevirt.io` → `virtualmachines/migrate` : `update` | what `virtctl migrate` calls |
| `kubevirt.io` → `virtualmachineinstancemigrations` : `get,list,watch,create,delete` | the object-based path used by `test-vm-migration.sh`; `delete` also covers `virtctl migrate-cancel` |

Verify, then remove when no longer wanted:

```bash
oc auth can-i update virtualmachines/migrate -n mm-test          # yes
oc auth can-i create virtualmachineinstancemigrations -n mm-test # yes

oc delete role,rolebinding vm-live-migrator -n mm-test --as system:admin
```

Applied on `oac-dev-workload0` for `memalhot@redhat.com` in `mm-test`. Confirmed scoped — the same check in another namespace returns `no`.

---

# VM Network Testing

Verifies that OpenShift Virtualization can run a VM with working pod-network connectivity. Boots a minimal CirrOS VM and checks outbound IP reachability, DNS resolution, and inbound access through a port forward.

Confirmed working on the OAC dev cluster.

## Usage

```bash
cd vm-testing
oc apply -f net-test-vm.yaml
```

Requires `oc` and `virtctl`, authenticated to the target cluster, with OpenShift Virtualization installed (see `component-checks/oc-virt-checks.sh`).

## Steps

1. **Create the VM** — `oc apply -f net-test-vm.yaml` creates `net-test-vm`, a CirrOS VM (`quay.io/kubevirt/cirros-container-disk-demo`) on a `containerDisk` volume with a masquerade interface on the default pod network.

2. **Wait for it to boot** — `oc get vmi net-test-vm` until the phase is `Running`.

3. **Open a console** — `virtctl console net-test-vm`, then log in with the credentials printed on the CirrOS login banner.

4. **Test outbound IP** — `ping -c 3 8.8.8.8`

5. **Test DNS** — `ping google.com` or `curl -I google.com`

6. **Exit the console** — `Ctrl+]`

7. **Test inbound connectivity** — port-forward to the VM and check the port is reachable:

   ```bash
   oc port-forward svc/net-test-ssh 2222:22
   ```

   Then in another terminal:

   ```bash
   nc -zv 127.0.0.1 2222
   ```

   The `net-test-ssh` Service is created by `net-test-vm.yaml` alongside the VM. It selects the virt-launcher pod by the `kubevirt.io/vm: net-test-vm` label the VM template stamps on it, so it follows the VM across restarts.

## Cleanup

```bash
oc delete -f net-test-vm.yaml
```

---

# VM Persistent Storage Testing

`test-vm.sh` boots from a `containerDisk`, which is a copy-on-write overlay discarded when the VMI stops — it proves compute and networking work and nothing about storage. `test-vm-storage.sh` covers the gap: it provisions a real PVC root disk through CDI, boots a Fedora guest off it, writes a unique marker inside the guest, fully stops and restarts the VM, and reads the marker back.

```bash
cd vm-testing
./test-vm-storage.sh
```

Takes roughly 3-4 minutes end to end and deletes everything it created on exit.

## What it asserts

| # | Check | Why it matters |
|---|-------|----------------|
| 1 | DataVolume reaches `Succeeded` | CDI actually provisions a disk. `oc-virt-checks.sh` only confirms the CDI operators are `Available`, which is a weaker claim |
| 2 | PVC is `Bound` at the requested size | The StorageClass serves VM disks, not just pod volumes |
| 3 | VMI `volumeStatus` shows `rootdisk` backed by the PVC | The VM really booted off persistent storage, not an ephemeral disk |
| 4 | Guest answers `virtctl ssh` | cloud-init ran and the image is a usable guest |
| 5 | Marker written and `sync`ed in-guest | Data reached the disk, not just the page cache |
| 6 | VMI object is deleted after `virtctl stop` | The guest and its virt-launcher pod were genuinely torn down |
| 7 | VM restarts and reaches `Ready` | — |
| 8 | PVC UID is unchanged | The disk was reused, not silently reprovisioned |
| 9 | Marker reads back after the restart | **The actual persistence claim** |

It also reports, without failing: whether `qemu-guest-agent` is connected, whether the disk is `ReadWriteMany`, and the VMI's `LiveMigratable` condition — the three prerequisites a live-migration test needs.

## Configuration

| Variable | Default | Notes |
|----------|---------|-------|
| `NAMESPACE` | `mm-test` | also honours `PROJECT` |
| `SOURCE_MODE` | `registry` | `registry` imports a container disk; `datasource` clones an SSP golden image |
| `IMAGE_URL` | `docker://quay.io/containerdisks/fedora:41` | used when `SOURCE_MODE=registry` |
| `DATA_SOURCE` | `fedora` | used when `SOURCE_MODE=datasource`; `oc get datasource -n openshift-virtualization-os-images` lists them |
| `GUEST_USER` | `fedora` | `cloud-user` for the `rhel*` images |
| `DISK_SIZE` | `10Gi` | must be at least the source image size when cloning |
| `STORAGE_CLASS`, `ACCESS_MODE` | unset | unset means CDI picks from the StorageProfile, which is what a real user gets |
| `DV_STALL` | `240` | seconds of no progress before the disk provisioning step is called stalled |
| `KEEP_VM` | `0` | `1` leaves the VM and disk in place for `virtctl console` |

## Result: 9 passed, 0 failed

Run against `mm-test` on `oac-dev-workload0`, Fedora Linux 41 Cloud Edition on a 10Gi `pure-fb-nfsv4` PVC. Import took about 20 seconds; the marker survived the stop/start; the guest agent connected, the disk came back RWX, and the VMI reported `LiveMigratable=True`.

## Known issue: cloning is broken on `pure-fb-nfsv4`

`SOURCE_MODE=registry` is the default because `SOURCE_MODE=datasource` does not work on this cluster, and the failure is silent — the DataVolume never reports `Failed`, it retry-loops indefinitely. Both clone strategies fail:

- **`csi-clone`** — the PVC event reads `rpc error: code = Unimplemented desc = volume cloning is not supported for FlashBlade`. The StorageProfile nonetheless advertises `cloneStrategy: csi-clone`, so CDI keeps choosing a strategy the driver cannot serve.
- **host-assisted `copy`** (forced with the `cdi.kubevirt.io/cloneType: copy` annotation) — gets further, standing up a source pod and an upload server, then the upload server dies untarring onto the target: `error unarchiving to /data: exit status 2`, and the clone restarts from the beginning.

This affects more than this test. Cloning a golden image is the path the console's **Create VirtualMachine → from template** button takes, so provisioning a VM through the UI on the default StorageClass hangs with no error surfaced to the user. Worth raising with whoever owns the Pure/Portworx CSI configuration.

The `DV_STALL` detector exists because of this: it fails the test in about four minutes with the CDI worker pod logs attached, rather than spinning for the full `DV_TIMEOUT`.

---

# VM Live Migration Testing

Live migration is what makes node maintenance survivable for VM users. Drains, cluster upgrades and MachineConfig rollouts all evict VMs; without it, each of those hard-kills the guest and loses whatever was in RAM. `test-vm-migration.sh` boots a VM on an RWX PVC, starts a heartbeat inside the guest, migrates it to another node, and checks that the same kernel came out the other side.

```bash
cd vm-testing
./test-vm-migration.sh
```

Takes roughly 3-4 minutes end to end and deletes everything it created on exit.

## What it asserts

| # | Check | Why it matters |
|---|-------|----------------|
| 1 | DataVolume reaches `Succeeded` | Setup — the disk must exist before anything can move |
| 2 | Root disk is `ReadWriteMany` | A shared disk is the precondition; an RWO disk pins the VM to one node |
| 3 | VM boots and reaches `Ready` | — |
| 4 | Guest answers `virtctl ssh` before migrating | Establishes a working baseline to compare against |
| 5 | In-guest heartbeat starts | Setup for the downtime measurement |
| 6 | VMI reports `LiveMigratable=True` | KubeVirt's own up-front verdict. If false, its `reason` names the blocker and the test stops there rather than failing obscurely later |
| 7 | Migration reaches `Succeeded` | The `VirtualMachineInstanceMigration` finished, `migrationState.failed` is not set |
| 8 | VM is on a different node | It actually moved |
| 9 | VMI UID is unchanged | The object was not deleted and recreated |
| 10 | Guest answers SSH after migrating | It is still usable |
| 11 | **Guest `boot_id` is unchanged** | **The decisive check** — see below |
| 12 | Marker file still readable | The disk followed the VM to the new node |
| 13 | Longest heartbeat gap is under `DOWNTIME_BUDGET` | The pause was short enough to call this *live* migration |

### Why `boot_id`

A VM that crashes and reboots onto another node also ends up "running, on a different node, reachable over SSH" — it would pass a naive node-name check while having lost everything in RAM, which is the exact failure live migration is supposed to prevent. The kernel regenerates `/proc/sys/kernel/random/boot_id` on every boot and holds it stable for the life of a running kernel, so carrying the same value across the migration is what actually proves the guest never stopped.

### How downtime is measured

The guest appends `date +%s.%N` to a file every 50ms. When it is paused for the final switchover it stops executing, so the largest gap between consecutive samples is the outage as the guest itself experienced it — no network in the path. The measurement cannot resolve a pause much shorter than the heartbeat interval plus scheduler jitter.

Note that total migration time and downtime are different numbers. Memory is copied while the guest keeps running; only the final switchover pauses it. The script reports both.

## Configuration

Shares the disk and image variables with `test-vm-storage.sh` (`SOURCE_MODE`, `IMAGE_URL`, `DISK_SIZE`, `STORAGE_CLASS`, `ACCESS_MODE`, `GUEST_USER`, `DV_STALL`, `KEEP_VM`), plus:

| Variable | Default | Notes |
|----------|---------|-------|
| `VM_NAME` | `migrate-test-vm` | — |
| `MIGRATION_TIMEOUT` | `600` | seconds to wait for the migration to finish |
| `DOWNTIME_BUDGET` | `5` | seconds the guest may stop executing and still pass |
| `HEARTBEAT_INTERVAL` | `0.05` | guest sampling interval, and the floor on measurement resolution |
| `MEMORY` | `2Gi` | migration transfer time scales with this |

## Result: 13 passed, 0 failed

Run against `mm-test` on `oac-dev-workload0`:

- migrated `moc-r4pac22u27-s1` → `moc-r4pac22u29-s3`, mode `PreCopy`
- total migration 2 seconds for a 2Gi guest
- **guest-visible downtime 0.189s** across 276 heartbeat samples
- `boot_id` unchanged, VMI UID unchanged, marker file intact

## Why the script does not use `virtctl migrate`

The script creates the `VirtualMachineInstanceMigration` object directly with `oc create`. That triggers the same operation through a plain CRD write, so the migration is visible as a normal Kubernetes object the script can watch, name in its cleanup, and report `migrationState` from. It also keeps the whole test on one credential path — `virtctl` has no `--as` flag, so anything it does cannot be reasoned about separately from the logged-in user. The permission is checked in preflight rather than three minutes later, after a VM has been built; see [migration RBAC](#one-time-migration-rbac) above.

## Possible extension

The current downtime number is what the guest experienced. It does not measure *network* continuity, which is a separate question: with masquerade binding the virt-launcher pod IP changes on migration, so measuring that properly needs a Service in front of the VM and an external prober, and the result would fold in OVN-Kubernetes endpoint reprogramming time as well as the migration itself. Worth adding if inbound connection survival is something you need to claim.
