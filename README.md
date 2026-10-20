# os-upgrade: Ubuntu LTS to the next LTS with a pinned kernel on RKE2 nodes

A tool to upgrade in place the operating system of the nodes of RKE2 clusters managed by
Rancher, using the **system-upgrade-controller (SUC)** that Rancher already deploys in
`cattle-system`. It does not modify the SUC or Rancher's own Plans.

What it does on each node:

- Upgrades Ubuntu to the next LTS with `do-release-upgrade`: **22.04 → 24.04** or
  **24.04 → 26.04**, depending on `TARGET_VERSION`
  ([transitions](docs/configuration.md#supported-transitions)). The documentation examples use
  22.04 → 24.04.
- Installs **exactly** the kernel set in `KERNEL_VERSION` (e.g. `6.8.0-139-generic`) and keeps it
  in place: no kernel metapackages, `apt-mark hold`, an apt pin and a fixed `GRUB_DEFAULT`. The
  three packages installed depend on the target: `linux-image`, `linux-modules` and
  `linux-modules-extra` for 24.04; `linux-image`, `linux-modules` and `linux-main-modules-zfs`
  for 26.04. See [docs/kernel.md](docs/kernel.md).
- **A single reboot** per node during the window (designed for bare metal).
- Predownloads the packages, without draining, days before the window: the window does not
  depend on the network.
- Preflight before the drain: if the node cannot be upgraded, it fails without cordoning it.
- Idempotent: each reboot kills the pod, the Job creates another one and the process continues
  where it left off.
- Keeps the internal mirror and the third-party repos that publish the target release
  (`--allow-third-party`) and reports the ones that get disabled.
- Optional per-cluster post-upgrade hook for your own checks, and a final report on each node
  (`/var/log/os-upgrade-report.txt`).

## Requirements

- RKE2 clusters with Rancher and its SUC in `cattle-system` (built for
  `rancher/system-upgrade-controller:v0.16.3`).
- Ubuntu nodes on the source release of the transition (or already on the target, to only change
  the kernel), booting with GRUB.
- Node access to an Ubuntu mirror (direct, through a proxy with or without credentials, or an
  internal mirror): [configuration → Proxy](docs/configuration.md#proxy).
- On your machine, one of the two release forms ([docs/install.md](docs/install.md)):
  - the **tarball** (Linux x86_64; brings yq, kustomize and kubeconform, uses your `kubectl`);
  - the **image** `ghcr.io/hector295/os-upgrade` (brings everything, kubectl v1.33.5 included).
- **A kubeconfig of the downstream cluster with cluster-admin permissions** to export the CRD,
  apply the Plans, label nodes and query etcd. `os-upgrade render`/`validate` do not need it. How
  to get it and precautions with several clusters:
  [runbook → Cluster access](docs/runbook.md#cluster-access-kubeconfig).

## Quick start

```sh
V=0.3.0   # see the Releases page
curl -fsSL https://github.com/Hector295/ubuntu-upgrade-plan/releases/download/v$V/os-upgrade-$V-linux-amd64.tar.gz \
  | sudo tar -xz -C /opt
sudo ln -sfn /opt/os-upgrade-$V-linux-amd64/bin/os-upgrade /usr/local/bin/os-upgrade
# or the image: docker run --rm -it ... ghcr.io/hector295/os-upgrade:$V (docs/install.md)

export KUBECONFIG=~/.kube/my-cluster.yaml   # cluster kubeconfig (cluster-admin)
kubectl config current-context              # ALWAYS check which cluster you point to
os-upgrade init my-cluster --kernel 6.8.0-139-generic   # for 24.04 -> 26.04: --kernel 7.0.0-38-generic --target 26.04
$EDITOR my-cluster/config.env               # proxy, mirror... (docs/configuration.md)
os-upgrade export-crd my-cluster            # the cluster's Plan CRD, for the validation
os-upgrade validate my-cluster              # renders my-cluster/manifests.yaml and validates it
os-upgrade apply my-cluster                 # creates the Plans; no node is affected yet
```

The cluster configuration (`my-cluster/`) lives outside the tool: keep it in a repo of your own
and upgrading the tool does not touch it.

The Plans only act on nodes with the `os-upgrade` label:

| Label | Plan | What it does |
|---|---|---|
| `os-upgrade=predownload` | `os-upgrade-predownload` | Downloads packages. No drain, no reboot |
| `os-upgrade=upgrade` | `os-upgrade-workers` / `os-upgrade-cp` | Preflight → drain → upgrade → 1 reboot |
| `os-upgrade=done` | none | Node finished. `rollout.sh` sets it after verifying the node (you set it in the manual procedure) |
| `os-upgrade=hold` | none | Node set aside: excluded when launching or resuming a group |

The orchestrator sets the labels:

```sh
os-upgrade preflight --group 1                      # checks, read-only
os-upgrade rollout predownload --group 1 --wait     # predownload (no impact)
os-upgrade rollout upgrade --group 1 --dry-run      # plan and checks, changes nothing
os-upgrade rollout upgrade --group 1                # node by node, verifying and confirming
os-upgrade rollout status --group 1
```

`rollout` orders workers → non-leader control planes → etcd leader (with `move-leader`
first). It supervises prepare and the drain with timeouts, and holds the node without touching it
if they fail. After each node it verifies the target release, kernel, DaemonSets, pods, DNS and
etcd, marks the node `done` and asks for confirmation before the next one. Groups are an
`os-upgrade-group=<n>` label.

The complete procedure, including the manual alternative, is in the
**[runbook](docs/runbook.md)**.

## Tested

Both transitions passed the VM lab end-to-end test ([docs/lab.md](docs/lab.md)): 3 control plane
+ 1 worker, RKE2 v1.33.13+rke2r2 and the official SUC v0.16.3, one reboot per node.

- 22.04 → 24.04 with `6.8.0-139-generic`.
- 24.04 → 26.04.1 with `7.0.0-38-generic`.

Both also passed it with the released image `ghcr.io/hector295/os-upgrade:0.1.0` (56-57 min);
the 24.04 → 26.04 run predownloaded the 4 nodes in parallel (550 MB each, 3.5 min).

Behind a proxy, with the nodes **without direct Internet access** (squid, `LAB_PROXY`): 22.04 →
24.04 without credentials and 24.04 → 26.04 with a user and a password with special characters
(in the `proxy.env` Secret, never in logs). It has not yet been run on bare metal or with
Rancher's own SUC.

## Documentation

- [docs/install.md](docs/install.md): tarball and image, commands, publishing a release.
- [docs/runbook.md](docs/runbook.md): step-by-step procedure, monitoring and common problems.
- [docs/configuration.md](docs/configuration.md): all parameters, supported transitions and how
  to customize a cluster.
- [docs/kernel.md](docs/kernel.md): choosing, checking, changing and undoing the pinned kernel.
- [docs/rollback.md](docs/rollback.md): what to do if a node goes wrong: fix it, another kernel,
  rebuild a worker or a control plane, restore etcd.
- [docs/lab.md](docs/lab.md): libvirt VM lab to test the whole flow end to end.

## Layout

```
bin/os-upgrade                 single entry point (init, render, validate, apply, preflight, rollout...)
scripts/upgrade.sh             runs on the nodes (subcommands prepare, predownload, upgrade...)
scripts/rollout.sh             orchestrator: predownload, node-by-node upgrade, status
scripts/preflight.sh           cluster checks before a campaign (read-only)
scripts/check-cluster.sh       detailed state of nodes, etcd, Jobs and pods, with a verdict
scripts/lib/                   operator libraries: kubectl, etcd and checks
scripts/validate-manifests.sh  validates the Plans against the real cluster CRD and our own rules
manifests/base/                Plans, default config.env and kustomize config
manifests/components/          target-version: copies TARGET_VERSION into the Plans' spec.version
manifests/overlays/<cluster>/  the only thing edited per cluster (lab is the template)
manifests/overlays/lab-vm*/    overlays for the VM lab (lab-vm: 22.04 -> 24.04, lab-vm-2604: 24.04 -> 26.04)
manifests/schemas/<cluster>/   Plan CRD exported from each cluster
lab/lab.sh                     libvirt VM lab with RKE2 and the official SUC for e2e tests
docs/                          documentation; docs/examples/ has a post-upgrade hook example
tests/bats/                    bats tests
tests/stubs/                   fake node commands (apt, dpkg, systemctl, grub...) for upgrade.sh
tests/k8s-stubs/               fake kubectl over a fake cluster for the operator scripts
tests/lab-stubs/               fake virsh for the lab safety tests
tools/                         install.sh downloads the pinned tools (tools/bin is not versioned);
                               dist.sh builds the release tarball
Dockerfile                     operator image (make image)
.github/workflows/             ci: make check on main and PRs; release: tarball + image on v* tags
```

## Development

From a clone, `bin/os-upgrade` works like the installed one (after `make tools`), and the lab
overlays live in `manifests/overlays/` with their CRD in `manifests/schemas/`.

```sh
make tools      # pinned tools in tools/bin: shellcheck, bats, kubeconform, kustomize, yq, kubectl
make lint       # shellcheck with no warnings
make test       # bats: upgrade.sh on a fake root, operator scripts on a fake cluster, manifests, lab
make check      # lint + test + validate
make dist       # release tarball in dist/; make image builds the image too
lab/lab.sh up && lab/lab.sh e2e   # full test on local VMs (see docs/lab.md)
```

None of the `make` targets contact a cluster: they only render and validate files locally.

Conventions: POSIX shell (`/bin/sh`, `set -eu`), shellcheck clean; code, messages and
documentation in English.
