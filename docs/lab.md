# VM lab (end-to-end tests)

`lab/lab.sh` creates on your machine an RKE2 cluster of Ubuntu 22.04 (or 24.04) VMs on libvirt
and installs the **official system-upgrade-controller v0.16.3** (the same version Rancher uses).
It tests the whole flow (`preflight.sh`, `rollout.sh`, the Plans and `upgrade.sh`) without
touching any real cluster.

## Requirements

- libvirt with KVM: `virsh`, `virt-install`, `genisoimage`, and your user in the `libvirt`
  group. It uses `qemu:///system`, the `default` pool and the `default` network (NAT with DHCP).
- `ssh`, `curl` and `make tools` (the lab uses the `kubectl` pinned in `tools/bin`, v1.33).
- Resources for the default topology (3 control plane + 1 worker): **16 GB of RAM, 8 vCPU** and
  about 10 GB of disk in the pool (copy-on-write disks over a shared base image).
- Internet access from the VMs: Ubuntu image, RKE2, the `ubuntu:24.04` Job image and the target
  release packages.

## Usage

```sh
lab/lab.sh plan        # what would be created (changes nothing)
lab/lab.sh up          # VMs + RKE2 + SUC; leaves the kubeconfig in .lab/kubeconfig (~15-20 min)
eval "$(lab/lab.sh env)"   # KUBECONFIG, NS=system-upgrade and KUBECTL for kubectl and the scripts
lab/lab.sh e2e         # full test (see below)
lab/lab.sh reports     # os-upgrade report of each node
lab/lab.sh ssh osu-lab-cp1
lab/lab.sh down        # deletes the VMs and their disks (keeps the base image for next time)
lab/lab.sh destroy     # also deletes the base image and .lab/
```

Topology and versions, through environment variables:

```sh
LAB_CP=1 LAB_WORKERS=1 lab/lab.sh up          # minimal version (8 GB): no move-leader
LAB_RKE2_VERSION=v1.33.13+rke2r1 lab/lab.sh up  # another version (default v1.33.13+rke2r2)
LAB_RKE2_VERSION= LAB_RKE2_CHANNEL=v1.34 lab/lab.sh up   # latest of a channel
LAB_UEFI=true lab/lab.sh up                     # UEFI boot, like UEFI bare metal
```

To test **24.04 → 26.04**, create the VMs on 24.04 and use the `lab-vm-2604` overlay
(`TARGET_VERSION=26.04`, kernel `7.0.0-38-generic`):

```sh
lab/lab.sh down                                  # if there was a 22.04 lab
LAB_UBUNTU=24.04 lab/lab.sh up
LAB_UBUNTU=24.04 LAB_OVERLAY=$PWD/manifests/overlays/lab-vm-2604 lab/lab.sh e2e
```

Use the same `LAB_UBUNTU` for every command of that lab (`status`, `ssh`, `down`...).

With `LAB_CP` below 3, `preflight.sh` and `rollout.sh` fail the etcd check (3 members minimum);
for that topology: `export ETCD_MIN_MEMBERS=1`.

**Safety:** the lab only creates and deletes VMs and volumes with its prefix (`osu-lab-cp1`,
`osu-lab-w1`, `osu-lab-base-jammy.qcow2`...), by exact name. Other libvirt VMs are never touched;
there are tests that check it.

## What `e2e` does

1. Renders the manifests of the overlay (`manifests/overlays/lab-vm` by default, or
   `LAB_OVERLAY`) and validates them against the CRD **exported from the lab**
   (`.lab/schema/crd-plans.json`).
2. Applies the Plans and runs `preflight.sh`.
3. `rollout.sh predownload --wait` for group 1 (worker) and group 2 (control plane).
4. `rollout.sh upgrade --yes` for group 1 and then group 2: this includes `move-leader` of the
   etcd leader, phase supervision and verification after each node.
5. Checks that **all** nodes end up on the overlay's `TARGET_VERSION` with its `KERNEL_VERSION`
   and that `check-cluster.sh` is healthy. The last line is
   `E2E OK in <n> min: all nodes on Ubuntu <target> with <kernel>`.

With 4 nodes it takes about one hour (each node: drain, release upgrade and one reboot).
`lab/lab.sh reports` then shows each node's report.

The `lab-vm` overlay differs from a Rancher cluster overlay in the namespace and ServiceAccount of
the official SUC (`system-upgrade`) and in a `postCompleteDelay` of 2 min.

## What the lab does not cover

- **Bare metal:** firmware, RAID controllers, NICs and real boot times. GRUB is tested with BIOS
  or UEFI (`LAB_UEFI=true`), without Secure Boot.
- **Rancher:** it uses the official SUC, not Rancher's; there is no Rancher agent on the nodes.
- **Proxy and internal mirror:** the VMs go straight to the internet.
- **Workloads and PDBs:** the cluster is empty. To test the drain, deploy test applications with
  PDBs before the `e2e`.
