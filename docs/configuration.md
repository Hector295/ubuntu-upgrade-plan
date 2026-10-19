# Configuration

Each cluster has its overlay: a directory with these files.

- `config.env`: parameters for the process on the nodes. It becomes the ConfigMap
  `os-upgrade-config-<hash>`, which the Jobs receive as environment variables.
- `kustomization.yaml`: image, namespace and Plan settings (window, deadlines...).
- `crd-plans.json`: the cluster's Plan CRD, for `os-upgrade validate` (`os-upgrade export-crd`).
- `post-upgrade-hook.sh` (optional): see [Post-upgrade hook](#post-upgrade-hook).

To create one: `os-upgrade init <cluster> --kernel <X.Y.Z-N-generic> [--target 26.04]`. The
overlay refers to the base as `../../base`, wherever it lives: `os-upgrade render` puts it on top
of the base of the installed version. In the repo, the overlays of the lab are in
`manifests/overlays/` and `make validate CLUSTER=<name>` uses `manifests/schemas/<name>/`.

> Any change to `config.env` or to `scripts/upgrade.sh` produces a ConfigMap/Secret with a
> different hash and therefore new Plans. **Do not change the configuration while nodes are
> halfway through an upgrade**; nodes that already finished are not affected if they have
> `os-upgrade=done`.

## `config.env` parameters

Only the ones that differ from the default (`manifests/base/config.env`) need to be set.

| Parameter | Default | Description |
|---|---|---|
| `TARGET_VERSION` | `24.04` | Target release: `24.04` (from 22.04) or `26.04` (from 24.04). See [Supported transitions](#supported-transitions) |
| `KERNEL_VERSION` | *(required)* | Exact kernel, format `X.Y.Z-N-generic` (e.g. `6.8.0-139-generic`). Three packages of that version are installed; which ones depends on the target (see [Supported transitions](#supported-transitions) and [kernel.md](kernel.md)) |
| `SINGLE_REBOOT` | `true` | If the node would need a reboot before the release upgrade (pending libc6, linux-base or a source-release kernel), the preflight fails **before the drain**. With `false` it only warns and the node reboots twice |
| `REQUIRE_PREDOWNLOAD` | `true` | The preflight requires the predownload to have been done for this `KERNEL_VERSION`. With `false` it only warns and everything is downloaded during the window |
| `APT_MIRROR` | *(empty)* | Mirror for the predownload, e.g. `http://mirror.internal/ubuntu`. Empty: the one the node uses in its apt sources |
| `HTTP_PROXY` | *(empty)* | Proxy for the HTTP traffic of apt and `do-release-upgrade` (`http://host:port`). **Without credentials**: a proxy with a user goes in `proxy.env` ([Proxy](#proxy)) |
| `HTTPS_PROXY` | *(empty)* | Proxy for the HTTPS traffic (usually the same URL) |
| `NO_PROXY` | *(empty)* | Destinations that bypass the proxy (e.g. the internal mirror) |
| `MIN_FREE_ROOT_MB` | `5000` | Minimum free space on `/` |
| `MIN_FREE_BOOT_MB` | `300` | Minimum free space on `/boot` |
| `MAX_REBOOTS` | `3` | Maximum reboots of the process on a node; above it the node is marked as failed. Normally it is 1 |
| `ALLOW_THIRD_PARTY` | `true` | Runs `do-release-upgrade --allow-third-party`. See [Apt sources](#apt-sources-internal-mirror-and-third-party-repos) |
| `POST_UPGRADE_HOOK_RETRIES` | `3` | Attempts of the [post-upgrade hook](#post-upgrade-hook) (20 s apart) before marking the node |

The proxy is exported to apt, to `do-release-upgrade` and to the host systemd unit. If the nodes
already have the proxy configured in apt (`Acquire::http::Proxy`), there is no need to repeat it
here. See [Proxy](#proxy) for proxies with credentials and what the nodes need besides this.

## Proxy

Everything the nodes download (the predownload, `apt-get update` in `prepare`, the release
upgrade and the kernel) goes through `HTTP_PROXY`/`HTTPS_PROXY`. The usual value of both is the
same `http://` URL: HTTPS goes through the proxy with `CONNECT`.

**Without credentials:** in `config.env`.

```sh
HTTP_PROXY=http://proxy.internal:3128
HTTPS_PROXY=http://proxy.internal:3128
NO_PROXY=127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.svc,.cluster.local
```

**With a user and a password:** in a `proxy.env` file next to `config.env`, which becomes the
Secret `os-upgrade-proxy-<hash>` instead of going into the ConfigMap. `os-upgrade validate`
rejects credentials in `config.env` and never prints the values of `proxy.env`.

```sh
# <cluster>/proxy.env (keep it out of git, or encrypted: it has the password)
HTTP_PROXY=http://user:p%40ss%3Aword@proxy.internal:3128
HTTPS_PROXY=http://user:p%40ss%3Aword@proxy.internal:3128
NO_PROXY=127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.svc,.cluster.local
```

and in the overlay `kustomization.yaml`:

```yaml
secretGenerator:
  - name: os-upgrade-proxy
    behavior: merge
    envs:
      - proxy.env
```

- Characters of the user or password that are special in a URL must be percent-encoded:
  `@` → `%40`, `:` → `%3A`, `/` → `%2F`, `#` → `%23`, `%` → `%25`, `!` → `%21`, space → `%20`.
- `proxy.env` only accepts `HTTP_PROXY`, `HTTPS_PROXY` and `NO_PROXY`. Its values win over the
  ones in `config.env`.
- The Jobs receive it with `envFrom` (it does not appear in the Plan or in `kubectl describe`).
  On the node, the configuration that the host unit uses (`/var/lib/os-upgrade/config`) is only
  readable by root.
- Changing the password produces a new Secret and new Plans, like any change of `config.env`.

**What the nodes need besides this** (it is not configured by os-upgrade):

- **The Job image** (`docker.io/library/ubuntu:24.04` or the one of your registry) is pulled by
  containerd. Behind a proxy, RKE2 needs it in `/etc/default/rke2-server` and
  `/etc/default/rke2-agent` (`HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY` with the cluster and service
  CIDRs; Rancher sets it when the cluster is provisioned with a proxy), or the image must come from
  an internal registry ([Plan settings](#plan-settings-kustomizationyaml)). The predownload uses the
  same image: if it cannot be pulled, its Jobs stay in `ImagePullBackOff` days before the window.
- `NO_PROXY` must include the internal mirror, if there is one.

Tested in the lab with the nodes **without direct Internet access** (only through a squid proxy),
with and without credentials ([lab.md](lab.md#proxy)).

## Supported transitions

`do-release-upgrade` only jumps to the **next LTS**, so each campaign is one jump:

| `TARGET_VERSION` | Source | Codename | Pinned kernel packages | Example `KERNEL_VERSION` |
|---|---|---|---|---|
| `24.04` (default) | 22.04 | noble | `linux-image`, `linux-modules`, `linux-modules-extra` | `6.8.0-139-generic` |
| `26.04` | 24.04 | resolute | `linux-image`, `linux-modules`, `linux-main-modules-zfs` | `7.0.0-38-generic` |

- **26.04 has no `linux-modules-extra`:** its content was merged into `linux-modules`. The ZFS
  modules come in a separate package that the metapackage installs by default, and the tool
  installs it too.
- **Tested in the lab** (3 control plane + 1 worker, RKE2 v1.33.13+rke2r2): 24.04 → 26.04.1 with
  `7.0.0-38-generic`, one reboot per node. The upgrade keeps `initramfs-tools` (it does not switch
  to dracut) and RKE2 v1.33 works on 26.04. For production, also check the support matrix of your
  RKE2 version.
- **A node two LTS releases behind** (22.04 with `TARGET_VERSION=26.04`) is rejected in `prepare`,
  before the drain: first a campaign to 24.04, then another one to 26.04.
- **A node already on the target release** only changes its kernel.
- The table lives in `scripts/upgrade.sh` (`TRANSITIONS`); `os-upgrade validate` rejects a
  `TARGET_VERSION` that is not in it.
- The Plans' `spec.version` takes the value of `TARGET_VERSION` through the component
  `manifests/components/target-version`. New overlays copied from `lab` already include it;
  `os-upgrade validate` reports it if it is missing.

## Apt sources: internal mirror and third-party repos

`do-release-upgrade` only accepts the public Ubuntu mirrors as valid (its `mirrors.cfg` list).
Without `--allow-third-party`, any other source is **disabled** with the comment
`disabled on upgrade to <codename>`, and that includes an **internal Ubuntu mirror**, which is
also replaced by `archive.ubuntu.com`. With `--allow-third-party`, the upgrader checks each
source: if it publishes the target codename, it rewrites it to that codename; otherwise it
disables it.

| `ALLOW_THIRD_PARTY` | Internal Ubuntu mirror | Vendor repos |
|---|---|---|
| `true` (default) | Kept (if it publishes the target codename) | Those that publish the target codename are kept; the rest are disabled |
| `false` | `prepare` **fails before the drain**: the upgrade would switch it to `archive.ubuntu.com` | All disabled |

On each node, `prepare` and the predownload log the unofficial sources they find (`.list` and
`.sources` formats) and how they will be handled. At the end, the sources the upgrade disabled
are reported as a warning and in the node report (`/var/log/os-upgrade-report.txt`).
Re-enabling them is manual: check that the vendor publishes packages for the target release.

`prepare` and the predownload also warn about packages held with `apt-mark hold` (besides the
pinned kernel), because they can stop `do-release-upgrade` from computing the upgrade.

## Post-upgrade hook

Your own script that runs on each node **at the end** of the process, as root on the host, with
the system already on the target release, the pinned kernel booted and rke2 active. It is for
environment checks the tool does not know about: mounts, your own services, GPU drivers,
monitoring agents, etc.

- It receives `NODE_NAME`, `KERNEL_VERSION` and `TARGET_VERSION`. Its output goes to the node log.
- If it fails, it is retried (`POST_UPGRADE_HOOK_RETRIES`, 20 s apart). If it keeps failing, the
  node is **marked as failed and stays cordoned**: the system is upgraded, but something of your
  own does not work.
- Its syntax is checked by `os-upgrade validate` and by `prepare` (before the drain). The ones of
  the repo overlays also go through shellcheck in `make lint`.

To enable it for a cluster, start from the example `docs/examples/post-upgrade-hook.sh` (in the
tarball too; in the image it is under `/opt/os-upgrade/docs/examples/`):

```sh
cp docs/examples/post-upgrade-hook.sh <cluster>/
```

and add to the overlay `kustomization.yaml`:

```yaml
secretGenerator:
  - name: os-upgrade-script
    behavior: merge
    files:
      - post-upgrade-hook.sh
```

The hook travels in the same Secret as `upgrade.sh`: changing it produces a new Secret and new
Plans.

## Plan settings (`kustomization.yaml`)

Full example of a production overlay (checked with `os-upgrade validate`):

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../base

components:
  - ../../components/target-version

configMapGenerator:
  - name: os-upgrade-config
    behavior: merge
    envs:
      - config.env

# Job image from an internal registry (it only needs sh and chroot).
images:
  - name: docker.io/library/ubuntu
    newName: registry.internal.local/library/ubuntu
    newTag: "24.04"

patches:
  # Time window: the SUC does not create new Jobs outside it (running ones continue).
  - target: {kind: Plan, name: "os-upgrade-(workers|cp)"}
    patch: |
      - op: add
        path: /spec/window
        value: {days: ["saturday", "sunday"], startTime: "22:00", endTime: "06:00", timeZone: "UTC"}
  # More time per node (drain + upgrade + reboot of a slow bare metal server).
  - target: {kind: Plan, name: "os-upgrade-(workers|cp)"}
    patch: |
      - op: replace
        path: /spec/jobActiveDeadlineSecs
        value: 10800
  # More nodes predownloading at the same time (mind the proxy bandwidth).
  - target: {kind: Plan, name: os-upgrade-predownload}
    patch: |
      - op: replace
        path: /spec/concurrency
        value: 4
```

Other settings with the same mechanism: `namespace:` (if the SUC is not in `cattle-system`),
`/spec/serviceAccountName`, `imagePullSecrets` or `/spec/postCompleteDelay` of the control plane
Plan (default `10m`).

### Plan defaults

| Plan | Nodes | concurrency | Deadline | Drain | Other |
|---|---|---|---|---|---|
| `os-upgrade-predownload` | all with `os-upgrade=predownload` | 2 | 3600 s | no | - |
| `os-upgrade-workers` | `os-upgrade=upgrade` without the control-plane role | 1 | 7200 s | yes | prepare before the drain |
| `os-upgrade-cp` | `os-upgrade=upgrade` with the control-plane role (includes all-roles nodes) | 1 | 7200 s | yes | prepare, `postCompleteDelay: 10m` |

The three Plans tolerate any taint and are `exclusive` (in SUC v0.16 this only prevents two of
these Jobs from running **on the same node**; it does not serialize the cluster).

## What validation prevents

`os-upgrade validate <cluster>` fails if:

- A Plan uses a field the cluster CRD does not know (e.g. `postCompleteLabels`) or has a wrong
  type. It is validated against `<cluster>/crd-plans.json` in strict mode.
- `spec.drain.timeout` is present: in SUC v0.16 it is nanoseconds in an int32 (maximum about 2 s)
  and a large value broke the listing of all the controller's Plans.
- A Plan with drain has a `concurrency` other than 1.
- `jobActiveDeadlineSecs` is not between 600 and 86400.
- An image has no explicit tag.
- `KERNEL_VERSION` is missing or has an invalid format; wrong booleans or numbers; proxy or
  mirror without `http://`/`https://`.
- `TARGET_VERSION` is not a supported target, or the Plans' `spec.version` does not match it.
- The post-upgrade hook has syntax errors.
- The resources end up in different namespaces.

If you upgrade Rancher, export the CRD again:
`os-upgrade export-crd <cluster>`.
