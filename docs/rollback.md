# Rollback

Ubuntu **cannot go back to the previous LTS** (from 24.04 to 22.04, or from 26.04 to 24.04) on the
same system. The examples are from the campaign to 24.04. Here "rollback" means bringing the node
(and the cluster) back to a healthy state through one of these paths:

| Path | When | Impact |
|---|---|---|
| [A. Fix the node on the target release](#a-fix-the-node-on-the-target-release) | The system boots; something specific fails (a service, a repo, the hook) | Only that node, no reinstall |
| [B. Switch to another kernel](#b-switch-to-another-kernel) | The problem is the pinned kernel (driver, performance, hardware) | One reboot per node |
| [C. Rebuild a worker](#c-rebuild-a-worker) | The worker does not boot or is not worth fixing | Reinstall the OS and register it in Rancher again |
| [D. Rebuild a control plane](#d-rebuild-a-control-plane--etcd) | Same, on a control plane + etcd node | Like C, protecting the etcd quorum |
| [E. Restore etcd from a snapshot](#e-loss-of-etcd-quorum-last-resort) | The etcd quorum is lost | **The whole cluster**; last resort |

In every case, **stop the campaign first**: do not launch more nodes and, if `rollout.sh` is
running, answer "no" or interrupt it. Set the affected node aside with
`kubectl label node N os-upgrade=hold --overwrite`.

## Before the campaign: what makes rollback possible

Paths C, D and E depend on things you must have **before** starting:

1. **A recent etcd snapshot stored outside the nodes.** `preflight.sh` checks that there is one
   younger than 24 h. It must be copied outside the cluster (S3 configured in Rancher, or a manual
   copy of `/var/lib/rancher/rke2/server/db/snapshots/`).
2. **The cluster registration command** in Rancher (*Cluster Management → the cluster →
   Registration*) and the roles of each node (`kubectl get nodes -L os-upgrade-group` and the
   `node-role.kubernetes.io/*` labels).
3. **Installation media** for the servers (Ubuntu ISO or PXE) and access to their remote console
   (iDRAC/iLO/IPMI): a bare metal server that does not boot can only be fixed from there.
4. **Each node's own configuration** that the Rancher registration does not recreate: network
   (bonding, VLANs), mounts, `/etc/rancher/rke2/config.yaml` and `registries.yaml` if any,
   monitoring agents. Your `post-upgrade-hook.sh` is a good list of what to check.
5. **An alternative kernel available** in the archive (see [kernel.md](kernel.md)), in case path
   B is needed.

## A. Fix the node on the target release

The most common case: the node boots on the target release but the Job failed or the hook does
not pass. See [Common problems in the runbook](runbook.md#common-problems). After fixing it:

```sh
sh /usr/local/sbin/os-upgrade.sh reset-failed   # on the node
kubectl -n $NS delete job -l upgrade.cattle.io/node=N
kubectl label node N os-upgrade=upgrade --overwrite   # if it was on hold
```

The Job is recreated, finishes the finalize step (no reboot if the pinned kernel is already
running) and the SUC uncordons the node.

## B. Switch to another kernel

**The system boots** (even with problems): switch to another version with the tool's normal flow.
It is one reboot per node, without a release upgrade:

1. Pick a published ABI and check it ([kernel.md](kernel.md#choosing-and-checking-the-version)).
2. `KERNEL_VERSION=<other>` in `config.env`, `os-upgrade apply <cluster>`.
3. Remove the `done` label from the affected nodes (`kubectl label node N os-upgrade-`), then
   `rollout.sh predownload` and `rollout.sh upgrade` for them.

**The node does not boot with the pinned kernel:**

- **Before finalize** (right after the upgrade reboot), the source release kernel is still
  installed. From the remote console, in the GRUB menu, *Advanced options for Ubuntu* → the
  previous kernel. On servers the menu is usually hidden: press `Esc` (UEFI) or hold `Shift`
  (BIOS) while booting. With the node up, apply the normal path B (another `KERNEL_VERSION`).
- **After finalize** only the pinned kernel is left (the process purges the others). Boot from
  rescue media (target release ISO → *Rescue*), `chroot` into the system and install another
  kernel:

  ```sh
  # from the rescue system, with the node's / mounted on /mnt (and /boot, /boot/efi if separate)
  for d in dev proc sys run; do mount --bind /$d /mnt/$d; done
  chroot /mnt
  V=6.8.0-NNN-generic                                     # the alternative kernel
  apt-mark unhold $(apt-mark showhold | grep '^linux-')
  # 24.04: image, modules, modules-extra; 26.04: image, modules, main-modules-zfs
  apt-get install linux-image-$V linux-modules-$V linux-modules-extra-$V
  apt-mark hold linux-image-$V linux-modules-$V linux-modules-extra-$V
  rm /etc/default/grub.d/99-os-upgrade-kernel.cfg         # the next finalize regenerates it
  update-grub
  ```

  If it is not worth it, rebuild the node (path C or D).

> The tool does not keep a fallback kernel: after finalize only the pinned kernel remains. That
> way no other kernel can boot by surprise, but a later boot failure requires the rescue media.

## C. Rebuild a worker

1. **Take it out of the cluster**:

   ```sh
   kubectl label node N os-upgrade=hold --overwrite
   kubectl drain N --ignore-daemonsets --delete-emptydir-data --timeout=30m
   ```

   In Rancher: *Cluster Management → the cluster → Machines → N → Delete*. Wait until the node
   disappears from `kubectl get nodes`.
2. **Reinstall the system** from the installation media:
   - **The target release directly** (recommended): no release upgrade left to do.
   - **The source release**: the node goes back into the campaign from the start.

   Restore the node's own configuration (network, mounts, `registries.yaml`...).
3. **Register it again** with the Rancher registration command and the **worker** role. Wait
   until it is Ready and put its labels back: `kubectl label node N os-upgrade-group=<G>`.
4. **If the target release was installed:** pin the kernel with the tool. A node already on the
   target release only installs the kernel, applies the pin and GRUB, and reboots once:

   ```sh
   kubectl label node N os-upgrade-
   os-upgrade rollout predownload --nodes N --wait
   os-upgrade rollout upgrade --nodes N
   ```

If you reuse the disk without reinstalling (e.g. to register it again after an RKE2 failure),
first clean up RKE2 and the Rancher agent on the node:

```sh
sudo /usr/local/bin/rancher-system-agent-uninstall.sh   # if present (clusters created from Rancher)
sudo /usr/local/bin/rke2-uninstall.sh
```

## D. Rebuild a control plane + etcd

Same as path C, with these **mandatory** rules so the etcd quorum is not lost:

1. **Only one control plane at a time**, and only if the other two etcd members are healthy:
   `os-upgrade check` must report 3 members, all healthy, and one leader.
2. If the node is the **etcd leader**, move the leadership first (runbook, 5.5).
3. Delete the machine in Rancher and **check that its etcd member goes away**:

   ```sh
   POD=$(kubectl -n kube-system get pod -l component=etcd -o name | head -n1)
   CERTS="--cacert /var/lib/rancher/rke2/server/tls/etcd/server-ca.crt --cert /var/lib/rancher/rke2/server/tls/etcd/server-client.crt --key /var/lib/rancher/rke2/server/tls/etcd/server-client.key"
   kubectl -n kube-system exec $POD -- etcdctl $CERTS member list -w table
   ```

   If the member is still listed, remove it from a healthy etcd pod:
   `kubectl -n kube-system exec $POD -- etcdctl $CERTS member remove <hex-ID>`.
4. Reinstall and register it again with the roles it had (**etcd + control plane**, plus
   **worker** if the node had all roles).
5. **Do not continue** until `check-cluster.sh` reports 3 healthy members and one leader again.

## E. Loss of etcd quorum (last resort)

If two of the three etcd members are lost at the same time, the API server stops working. The
only option left is to **restore the cluster from a snapshot** in Rancher (*Cluster Management →
the cluster → Snapshots → Restore*). The restore affects **the whole cluster** and loses the
changes made after the snapshot. Follow the Rancher documentation for your version before doing
it.

The campaign is designed never to get here:
- one node at a time;
- healthy etcd before each node;
- `move-leader` before touching the leader;
- `postCompleteDelay` between control planes.

## Cleaning up os-upgrade changes on a node

What the tool leaves **on purpose** to keep the kernel in place, and how to remove it if you
stop pinning the kernel (details in
[kernel.md](kernel.md#undoing-the-pin-back-to-ubuntu-managed-kernels)):

| File / state | Purpose |
|---|---|
| `/etc/apt/preferences.d/99-os-upgrade-kernel` | Blocks the kernel metapackages |
| `/etc/default/grub.d/99-os-upgrade-kernel.cfg` | `GRUB_DEFAULT` to the pinned kernel |
| `apt-mark hold` on the 3 kernel packages | So they are neither removed nor changed |
| `/usr/local/sbin/os-upgrade.sh` | Copy of the script (status, reset-failed) |
| `/var/lib/os-upgrade/` | Process state (`done`, `config`) |
| `/var/log/os-upgrade.log`, `/var/log/os-upgrade-report.txt` | Log and report |
