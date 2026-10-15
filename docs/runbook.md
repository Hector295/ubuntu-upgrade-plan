# Runbook: upgrading a cluster

The window is run with **`scripts/rollout.sh`** ([step 4](#4-window-with-rolloutsh-recommended)),
which launches nodes one at a time, supervises each phase, verifies the result and asks for
confirmation before the next one. The manual procedures, node by node
([step 5](#5-manual-window-one-node-at-a-time)) or by groups
([step 6](#6-manual-window-by-groups)), remain as an alternative and as a reference of what the
orchestrator does.

Conventions: `N` is the node name, `G` the group number and `NS=cattle-system`. The examples are
from the 22.04 → 24.04 campaign; for 24.04 → 26.04 (`TARGET_VERSION=26.04`) the procedure is the
same with the other versions ([transitions](configuration.md#supported-transitions)).

## Cluster access (kubeconfig)

`make render` and `make validate` work without a cluster. **Everything else needs a kubeconfig**
of the downstream cluster (not the Rancher management cluster) with **cluster-admin**
permissions. It is needed to:

- export the CRD;
- create the Plans, the Secret and the ConfigMap in `cattle-system`;
- label the nodes;
- read Jobs and logs;
- `exec` into the etcd pods (`preflight.sh`, `rollout.sh`, `check-cluster.sh`).

The operator scripts also need `make tools` (they use `tools/bin/yq`) and GNU `date`. They use the
`kubectl` in the `PATH`, or the one in `KUBECTL` (e.g. `export KUBECTL=$PWD/tools/bin/kubectl`).

How to get it:

- **From Rancher:** cluster → *Download KubeConfig*. It goes through Rancher (through the
  `cattle-cluster-agent`): while the node running that agent is drained, the connection drops
  for a few seconds and commands with `-w` or `-f` must be relaunched.
- **From a control plane node:** `/etc/rancher/rke2/rke2.yaml`, replacing `server:
  https://127.0.0.1:6443` with the IP or FQDN of a control plane. Preferably one that is **not**
  being upgraded at that moment, or a load balancer in front of the three.

With several clusters, use one file per cluster and **always** check which one you point to
before applying or labeling anything:

```sh
export KUBECONFIG=~/.kube/<cluster>.yaml
kubectl config current-context
kubectl get nodes -o wide          # are these the nodes you expect?
NS=cattle-system
```

## 0. Before the campaign (once per cluster)

1. **SUC Job retries.** Each reboot kills the Job pod and counts as a failure. By default SUC
   v0.16 allows 2 (`backoffLimit`). Check what Rancher configures:

   ```sh
   kubectl -n cattle-system get deploy system-upgrade-controller -o jsonpath='{..env}'; echo
   kubectl -n cattle-system get configmap -o name | grep -i upgrade
   ```

   With the normal flow (1 reboot) the default is enough. With `SINGLE_REBOOT=false` or manual
   retries the margin is small: keep it in mind when reading the state of a Job.
2. **Kernel available:** see [kernel.md](kernel.md#choosing-and-checking-the-version).
3. **Freeze RKE2 upgrades in Rancher** for the duration of the campaign: Rancher's
   `system-agent-upgrader*` Plans must not run at the same time as these.
4. **Recent etcd snapshot** (Rancher → cluster → Snapshots, or `kubectl get etcdsnapshotfiles`).
5. **Healthy state:** `sh scripts/preflight.sh` (read-only) checks in one go the SUC, the Plans,
   that no Rancher Plan is in progress, nodes Ready, etcd (members, health, one leader, RAFT INDEX
   in sync, alarms), the age of the latest snapshot, PDBs that would block the drain and the free
   space on the nodes. It exits with 1 if something fails. `sh scripts/check-cluster.sh` shows
   the details (etcd tables, Jobs, pods with problems).
6. **Define the groups** (to predownload and upgrade in batches): one `os-upgrade-group` label
   per node.

   ```sh
   kubectl label node w1 w2 os-upgrade-group=1        # canary: 1-2 workers
   kubectl label node w3 w4 w5 w6 os-upgrade-group=2
   kubectl label node cp2 cp3 os-upgrade-group=3      # non-leader control planes
   kubectl label node cp1 os-upgrade-group=4          # leader control plane, always alone
   kubectl get nodes -L os-upgrade-group,os-upgrade
   ```

## 1. Render and apply the Plans

```sh
make validate CLUSTER=<cluster>
kubectl apply -f out/<cluster>.yaml
kubectl -n $NS get plans
```

Applying the Plans does not touch any node: they only act on nodes with the `os-upgrade` label.

## 2. Pre-patching (to get a single reboot)

`do-release-upgrade` requires a reboot first if the source release has a pending update of
`libc6`, `linux-base` or the kernel. The kernel metapackages are removed before the full-upgrade,
so usually only `libc6` can cause it. With `SINGLE_REBOOT=true` (default), a node in that
situation **is not drained**: the preflight fails with
`the node would need a prior reboot because of: ...`.

The predownload (step 3) reports which nodes are in that situation. Patch and reboot those nodes
in the usual patching window, before the upgrade window.

## 3. Predownload (days before, no impact)

No drain, no cordon and no reboot. It can be launched per node or per group; the Plan downloads
on 2 nodes at a time (`concurrency`, adjustable in the overlay). With the orchestrator:

```sh
sh scripts/rollout.sh predownload --group G --wait   # labels, waits and summarizes warnings per node
```

It skips nodes in `done`, `hold` and those in `upgrade`. Without `--wait` it only labels. By hand:

```sh
kubectl label node N1 N2 N3 os-upgrade=predownload --overwrite      # per node
kubectl label node -l os-upgrade-group=G os-upgrade=predownload --overwrite   # per group
kubectl -n $NS get jobs -l upgrade.cattle.io/plan=os-upgrade-predownload -w
```

Result per node:

```sh
kubectl -n $NS logs job/<job> -c upgrade | tail
# ... INFO Predownload OK: 734 packages, 812 MB in /var/lib/os-upgrade/archives
# ... WARN this node will need patching + a prior reboot ...   <- see step 2
```

A node with the predownload finished has the label
`plan.upgrade.cattle.io/os-upgrade-predownload` with the Plan hash.

**The closer to the window, the better:** whatever Ubuntu publishes between the predownload and
the window is downloaded during the window.

## 4. Window with `rollout.sh` (recommended)

```sh
sh scripts/preflight.sh --group G                     # read-only
sh scripts/rollout.sh upgrade --group G --dry-run     # plan, order and checks, changes nothing
sh scripts/rollout.sh upgrade --group G               # the window
sh scripts/rollout.sh status --group G                # state of the group's nodes
```

Instead of `--group G` you can use `--nodes n1,n2`. The window lasts hours: run it inside `tmux`
or `screen`. If the session drops, **relaunching the same command** resumes the node in progress
and skips the finished (`done`) and held (`hold`) ones.

### What it does

1. Orders the nodes: **workers → non-leader control planes → etcd leader**, and shows the plan.
   A group can mix workers and control planes: the orchestrator does them one at a time.
2. Checks the cluster: API, SUC, Plans applied, no Rancher Plan in progress and a recent etcd
   snapshot. Asks for confirmation to start (`[y/N]`).
3. For each node:
   1. **Before:** nodes Ready, no other node being upgraded, etcd healthy (members, health, one
      leader, RAFT INDEX in sync, no alarms). It warns about blocked PDBs in namespaces with pods
      on the node. If the node is the etcd leader, it runs `move-leader` to another member
      (preferably one already upgraded) and checks that the leadership moved.
   2. **Launches** the node (`os-upgrade=upgrade`) and **supervises** the Job phases: prepare,
      drain, upgrade, reboot.
   3. **Verifies** (retrying for up to 5 min while things settle): target Ubuntu release, target
      kernel, Ready, schedulable, Plan finished, the node's pods healthy, all DaemonSets
      complete, etcd healthy (for control planes) and a DNS/network test with a pod on that node.
   4. Marks the node `os-upgrade=done` and **asks for confirmation** before the next one.

### What it does when something goes wrong

| Situation | Reaction | Node state |
|---|---|---|
| `prepare` fails or exceeds `--prepare-timeout` | Shows the prepare log, holds the node and stops | **Untouched**: neither cordoned nor drained. `os-upgrade=hold` |
| The drain exceeds `--drain-timeout` | Shows the remaining pods and the blocked PDBs. Asks **[w]ait** another interval or **[a]bort** (with `--yes`, it aborts) | On abort: `hold` and **uncordon** (safe: the upgrade had not started) |
| The Job fails after the upgrade started, or `--node-timeout` is exceeded | Shows the Job conditions and log, and stops | **Cordoned** and in `upgrade`: see [Common problems](#common-problems) |
| Verification does not pass | Stops | In `upgrade` (not marked `done`) |
| You answer "no" between nodes | Stops cleanly | Finished nodes stay in `done` |

To retry a held node after fixing the cause: `kubectl label node N os-upgrade-` and relaunch the
command.

### Options

| Option | Default | Description |
|---|---|---|
| `--dry-run` | - | Changes nothing: shows the plan, the actions (`[dry-run] kubectl ...`) and runs the checks |
| `--yes` | - | No questions. On a slow drain, it aborts the node |
| `--drain-timeout` | `30m` | Maximum drain time before asking |
| `--prepare-timeout` | `15m` | Maximum time of the node preflight |
| `--node-timeout` | `4h` | Maximum time per node (from labeling to Plan finished) |
| `--skip-net-test` | - | Skips the DNS test (e.g. if the Plan image is not available to regular pods) |

Environment variables: `SETTLE_TIMEOUT` (`5m`), `POLL_SECONDS` (`15`), `ETCD_MIN_MEMBERS` (`3`),
`ETCD_RAFT_MAX_LAG` (`100`), `SNAPSHOT_MAX_AGE_HOURS` (`24`), `NS` (`cattle-system`), `KUBECTL`
(`kubectl`).

The DNS test creates a temporary pod `os-upgrade-nettest-<node>` in `cattle-system`, with the
Plans' image, which runs `getent hosts kubernetes.default.svc.cluster.local`.

## 5. Manual window: one node at a time

Order: **workers → non-leader control planes → leader control plane**.

### 5.1 Launch

```sh
kubectl label node N os-upgrade=upgrade --overwrite
```

The Job runs, in this order:

1. **`prepare`**: preflight without touching the node (configuration, predownload, space, proxy,
   prior reboot). If it fails, the node is **not** cordoned.
2. **`drain`**: cordon + drain (done by the SUC).
3. **`upgrade`**:
   - removes the kernel metapackages and applies the pin;
   - brings the source release to the latest patch level;
   - starts the `os-upgrade-release` unit on the host (`do-release-upgrade` with the
     predownloaded cache, installation of the pinned kernel, GRUB);
   - reboots **once**.
4. After the reboot the Job creates another pod, which verifies, cleans up and finishes
   successfully. The SUC uncordons the node.

### 5.2 Follow

```sh
kubectl -n $NS get jobs,pods -l upgrade.cattle.io/node=N -o wide -w
kubectl -n $NS logs -l upgrade.cattle.io/node=N -c prepare
kubectl -n $NS logs -l upgrade.cattle.io/node=N -c upgrade -f
```

The pod logs mark each step (`STEP 1/7` ... `STEP 7/7`). During the release upgrade, the pod only
says `Release upgrade in progress`. The details are on the node:

```sh
journalctl -fu os-upgrade-release          # host unit
tail -f /var/log/os-upgrade.log            # all phases, one line ts=... node=... phase=... level=... msg="..."
grep 'level=WARN\|level=ERROR' /var/log/os-upgrade.log
tail -f /var/log/dist-upgrade/main.log     # Ubuntu upgrader log
sh /usr/local/sbin/os-upgrade.sh status    # state summary (includes the final report)
```

At the end, each node keeps a report in `/var/log/os-upgrade-report.txt`:
- duration and number of reboots;
- system and kernel versions;
- hook result;
- apt sources the upgrade disabled;
- held packages.

### 5.3 Check that it finished

```sh
PLAN=os-upgrade-workers    # or os-upgrade-cp
kubectl -n $NS get plan $PLAN -o jsonpath='{.status.latestHash}'; echo
kubectl get node N -o jsonpath="{.metadata.labels.plan\.upgrade\.cattle\.io/$PLAN}"; echo
```

If both hashes match, the Plan finished on that node. In the control plane Plan, the label
appears after `postCompleteDelay` (10 min); the uncordon is immediate. Verify:

```sh
kubectl get node N -o wide                 # Ready, OS-IMAGE Ubuntu 24.04, KERNEL 6.8.0-139-generic
kubectl get pods -A -o wide --field-selector spec.nodeName=N | grep -v Running   # no broken pods
sh scripts/check-cluster.sh                # control plane: 3 healthy etcd members and one leader
```

### 5.4 Close the node

```sh
kubectl label node N os-upgrade=done --overwrite
```

**Mandatory:** without it, any future change of the Plans (another hash) would launch the
process on that node again.

### 5.5 Leader control plane

Before launching the etcd leader node, move the leadership to another member that is already
upgraded. The RKE2 etcd container **has no `/bin/sh`**: `etcdctl` runs directly with
`kubectl exec`, without `sh -c`.

```sh
POD=$(kubectl -n kube-system get pod -l component=etcd -o name | head -n1)
CERTS="--cacert /var/lib/rancher/rke2/server/tls/etcd/server-ca.crt --cert /var/lib/rancher/rke2/server/tls/etcd/server-client.crt --key /var/lib/rancher/rke2/server/tls/etcd/server-client.key"
kubectl -n kube-system exec $POD -- etcdctl $CERTS endpoint status --cluster -w table   # IS LEADER and ID
kubectl -n kube-system exec $POD -- etcdctl $CERTS --endpoints=https://<leader-IP>:2379 move-leader <target-hex-ID>
kubectl -n kube-system exec $POD -- etcdctl $CERTS endpoint status --cluster -w table   # check the change
```

(`$CERTS` is unquoted on purpose: it holds several options.) Then continue with 5.1.

## 6. Manual window: by groups

This is the manual alternative to step 5 when there are many nodes (with `rollout.sh`, `--group`
is enough). A whole group is labeled at once and the SUC processes it **one node at a time**
(`concurrency: 1`), without waiting for confirmation between nodes.

### How the SUC behaves with a group (v0.16.3)

- **One after another:** when a node finishes, the SUC starts the next one of the same Plan. It
  does not verify anything else in between (on the control plane it waits `postCompleteDelay:
  10m`).
- **Order cannot be controlled:** within a Plan, the SUC orders nodes by a hash of their UID, not
  by name. If the order matters, put the nodes in different groups.
- **A failure stops the group:** a node whose Job fails keeps occupying the `concurrency: 1` slot
  and the SUC does not start another one. But if its **label is removed**, the SUC moves on to
  the next node of the group (see *Pause or stop a group*).
- **Workers and control planes run in parallel:** they are different Plans and `exclusive` does
  not serialize them. A group must be **only workers or only control planes**, and do not launch
  a group of one kind while one of the other kind is in progress.

### Rules for building the groups

1. **Group 1 = canary:** 1 or 2 workers. Verify them thoroughly (5.3) before continuing.
2. **Workers:** groups of a size you can watch during the window. Nodes are drained one at a
   time, so the cluster only loses one node of capacity at a time.
3. **Non-leader control planes:** they can go together in one group (the SUC does them one at a
   time with 10 min between them). With 3 control planes, that is 2 nodes.
4. **Leader control plane:** always in a group of its own, after `move-leader` (5.5).
5. **All-roles nodes:** count as control planes (Plan `os-upgrade-cp`).

### Launch a group

The selector excludes finished (`done`) and held (`hold`) nodes, so relaunching a group never
repeats nodes:

```sh
G=2
SEL="os-upgrade-group=$G,os-upgrade notin (done,hold)"
kubectl get nodes -l "$SEL" -L os-upgrade        # review which nodes are included
kubectl label node -l "$SEL" os-upgrade=upgrade --overwrite
```

### Follow the group

```sh
PLAN=os-upgrade-workers    # or os-upgrade-cp
H=$(kubectl -n $NS get plan $PLAN -o jsonpath='{.status.latestHash}')
kubectl -n $NS get plan $PLAN -o jsonpath='{.status.applying}'; echo   # node in progress
kubectl get nodes -l os-upgrade-group=$G -L os-upgrade -L plan.upgrade.cattle.io/$PLAN
kubectl get nodes -l "os-upgrade-group=$G,plan.upgrade.cattle.io/$PLAN=$H"   # finished
kubectl -n $NS get jobs -l upgrade.cattle.io/plan=$PLAN -w
```

Following each node (logs, `journalctl`, `status`) is the same as in 5.2.

### Close the group

When all the group's nodes are finished and verified (5.3), mark them `done`. The selector only
includes nodes whose hash matches the Plan's, so it never marks a node halfway through:

```sh
kubectl label node -l "os-upgrade-group=$G,plan.upgrade.cattle.io/$PLAN=$H" os-upgrade=done --overwrite
kubectl get nodes -l os-upgrade-group=$G -L os-upgrade     # all must be done
sh scripts/check-cluster.sh
```

Move to the next group only with a healthy cluster.

### Pause or stop a group

Remove the label from the nodes that **have not started yet**. The one in progress finishes its
process (a release upgrade cannot be stopped halfway):

```sh
APPLYING=$(kubectl -n $NS get plan $PLAN -o jsonpath='{.status.applying[*]}')
for n in $(kubectl get nodes -l "os-upgrade-group=$G,os-upgrade=upgrade" -o name | cut -d/ -f2); do
  case " $APPLYING " in *" $n "*) echo "in progress, left as is: $n" ;; *) kubectl label node "$n" os-upgrade- ;; esac
done
```

To resume, launch the group again with the command in *Launch a group*: only pending nodes are
included.

### If a node of the group fails

The group stops on that node (it occupies the slot). Options:

- **Fix it and continue:** see [Common problems](#common-problems). When it finishes, the SUC
  continues with the rest of the group.
- **Set it aside and let the group continue:** first **pause** the group (otherwise the SUC will
  start another node as soon as the slot frees up). Then set the failed node aside with
  `kubectl label node N os-upgrade=hold --overwrite` (no Plan selects it and relaunching the
  group excludes it), review it separately and resume the group. Once fixed, launch it alone:
  `kubectl label node N os-upgrade=upgrade --overwrite`.

## 7. End of the campaign

- All nodes with `os-upgrade=done` and `sh scripts/check-cluster.sh` healthy.
- Optional: `kubectl delete -f out/<cluster>.yaml` and remove the labels
  (`kubectl label node N os-upgrade-`). What keeps the kernel in place (pin, hold, GRUB) stays on
  the nodes.
- Re-enable RKE2 upgrades in Rancher.

---

## Common problems

If a node cannot be fixed, see [rollback.md](rollback.md).

General rule: the process leaves a **failure mark** (`/var/lib/os-upgrade/failed`) when a person
is needed. While the mark is present, retries do nothing.

```sh
cat /var/lib/os-upgrade/failed                 # reason
sh /usr/local/sbin/os-upgrade.sh reset-failed  # after fixing it: clears the mark and the reboot counter
kubectl -n $NS delete job <job>                # the SUC creates a new Job and the process continues
```

If `/usr/local/sbin/os-upgrade.sh` does not exist yet, the failure happened before it was copied
and there is no mark.

### `prepare` fails (the node was not touched)

| Message | Cause and fix |
|---|---|
| `predownload missing for ...` | Step 3 was not done, or it was done with another `KERNEL_VERSION`. Run it, or set `REQUIRE_PREDOWNLOAD=false` |
| `the node would need a prior reboot because of: ...` | See step 2. Patch and reboot the node in the patching window |
| `not enough free space on ...` | Free up space (`apt-get clean`, old kernels, logs) |
| `apt-get update failed (proxy or mirror unreachable?)` | Proxy or mirror: check `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` |
| `the node Ubuntu mirror (...) is not a public mirror` | Internal mirror with `ALLOW_THIRD_PARTY=false`: the upgrade would switch it to `archive.ubuntu.com`. Use `ALLOW_THIRD_PARTY=true` ([configuration.md](configuration.md#apt-sources-internal-mirror-and-third-party-repos)) |
| `the post-upgrade hook has syntax errors` | Fix the overlay's `post-upgrade-hook.sh`, `make validate` and `kubectl apply` |
| `KERNEL_VERSION ...` | Overlay configuration; fix it, `make validate` and `kubectl apply` |
| `the node is on 22.04 and the target is 26.04` | `do-release-upgrade` only jumps one LTS: take that node through a campaign to 24.04 first |

To retry after fixing it: `kubectl -n $NS delete job <job>`. To leave the node for later:
`kubectl label node N os-upgrade-` and delete the Job.

### The Job failed after the drain (node cordoned)

The SUC only uncordons the node if the Job succeeds. First of all, check whether the process is
still alive on the host:

```sh
systemctl status os-upgrade-release
sh /usr/local/sbin/os-upgrade.sh status
```

- **Deadline exceeded (`DeadlineExceeded`) with the unit active:** the upgrade is still running
  on the host and will reboot the node. **Do not uncordon.** Wait until it finishes
  (`journalctl -fu os-upgrade-release`) and then delete the Job so the SUC recreates it,
  verifies and uncordons. Next time, raise `jobActiveDeadlineSecs`.
- **`do-release-upgrade ended with an error`:** check `/var/log/dist-upgrade/main.log` and
  `apt.log`. Often it is a third-party repository or a held package. If the system is still on
  the source release and dpkg is healthy (`lsb_release -r` shows the source release and
  `dpkg --audit` prints nothing): fix the cause, `reset-failed`,
  `rm /var/lib/os-upgrade/release-upgrade.started` (this confirms nothing was left halfway) and
  delete the Job.
- **`the release upgrade started and did not finish`:** there was a power cut or a reboot halfway.
  **It is not retried automatically.** Check by hand (`dpkg --configure -a`,
  `apt-get -f install`, `/var/log/dist-upgrade/`). If the system ends up consistent on the target
  release: `reset-failed`, delete `/var/lib/os-upgrade/release-upgrade.started` and delete the
  Job (it will install the kernel and reboot). Otherwise, reinstall the node.
- **`no GRUB entry for ...` / `grub.cfg did not pick up GRUB_DEFAULT`:** the node is on the target
  release but **has not rebooted**. Check `update-grub`, `/etc/default/grub` and
  `/etc/default/grub.d/`. After fixing it: `reset-failed` and delete the Job.
- **`too many reboots`:** the node does not boot the pinned kernel. Check
  `grep GRUB_DEFAULT /etc/default/grub.d/*` and `uname -r`, and the GRUB menu through the
  server console.
- **`dpkg --audit reports half-installed packages`:** `dpkg --configure -a`, review and
  `reset-failed`.
- **`the post-upgrade hook failed N times`:** the node is already on the target release with the
  pinned kernel, but your own check does not pass. Its output is in
  `grep 'msg="hook:' /var/log/os-upgrade.log`. Fix the cause on the node, `reset-failed` and
  delete the Job: the next attempt only finalizes (it runs the hook again, without a reboot).
- **Leave the node for now:** `kubectl label node N os-upgrade-`, delete the Job and
  `kubectl uncordon N` **only if** `systemctl is-active os-upgrade-release` says `inactive`.

### Apt sources disabled after the upgrade

Warning `sources disabled by the upgrade` (also in the node report): the upgrader commented them
out (`# ... disabled on upgrade to <codename>` in `.list` files) or set `Enabled: no` (in
`.sources` files) because they do not publish the target codename or because
`ALLOW_THIRD_PARTY=false`. It does not prevent finishing. If you need them, check that the vendor
has packages for the target release and re-enable them by hand, replacing the source codename
with the target one (e.g. `jammy` with `noble`).

### `rke2 is not active after N s`

After the reboot, finalize waits up to 10 min for rke2 to finish starting: a control plane takes
a while to rejoin etcd. If it does not start in that time, the attempt fails **without marking the
node** and the Job retries it. Check `systemctl status rke2-server` (or `rke2-agent`) and
`journalctl -u rke2-server`.

### The Job pod is `Pending` or `ImagePullBackOff`

- **Image:** the Job image comes from Docker Hub by default. In clusters without internet
  access, set `images:` in the overlay ([configuration.md](configuration.md)).
- **Drain blocked:** the `drain` container does not finish if a PodDisruptionBudget prevents it.
  `kubectl -n $NS logs <pod> -c drain`.

### etcd degraded during the control plane

Stop: do not label more nodes. `sh scripts/check-cluster.sh`. If a member does not come back after
the reboot, check `journalctl -u rke2-server` on that node before touching etcd.
