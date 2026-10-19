# Installation

The tool is used through a single command, `os-upgrade`, with no need to clone the repo. Each
release (a `v*` tag) publishes two equivalent forms:

| Form | Contents | Needs on the operator's machine |
|---|---|---|
| Tarball `os-upgrade-<version>-linux-amd64.tar.gz` ([Releases](https://github.com/Hector295/ubuntu-upgrade-plan/releases)) | Scripts, base manifests, docs, pinned yq, kustomize and kubeconform | Linux x86_64, `sh`, GNU coreutils, `kubectl` |
| Image `ghcr.io/hector295/os-upgrade:<version>` | The same plus kubectl v1.33.5 | Docker or Podman |

Both render exactly the same manifests for the same version. Use a fixed version in production
(the image also has `latest`, for trying it out).

## Tarball

```sh
V=0.1.0
URL=https://github.com/Hector295/ubuntu-upgrade-plan/releases/download/v$V
curl -fsSLO "$URL/os-upgrade-$V-linux-amd64.tar.gz"
curl -fsSLO "$URL/os-upgrade-$V-linux-amd64.tar.gz.sha256"
sha256sum -c "os-upgrade-$V-linux-amd64.tar.gz.sha256"
sudo tar -xzf "os-upgrade-$V-linux-amd64.tar.gz" -C /opt
sudo ln -sfn "/opt/os-upgrade-$V-linux-amd64/bin/os-upgrade" /usr/local/bin/os-upgrade
os-upgrade version
```

Without internet access on that machine (or behind the proxy), download both files elsewhere and
copy them over. To upgrade the tool, install the new version next to the old one and move the
symlink; the cluster configuration is not inside the package, so nothing else changes.

## Container image

```sh
docker pull ghcr.io/hector295/os-upgrade:0.1.0
alias os-upgrade='docker run --rm -it --user "$(id -u):$(id -g)" \
  -v "$PWD:/work" -v "$KUBECONFIG:/kube/config:ro" -e KUBECONFIG=/kube/config \
  ghcr.io/hector295/os-upgrade:0.1.0'
os-upgrade version
```

- The current directory is mounted on `/work`: run it from the directory that holds the cluster
  overlays, and refer to them with relative paths (`os-upgrade validate my-cluster`).
- `-it` is needed for the confirmations of `rollout` and `apply`; without a terminal they are
  answered with "no". `--user` makes the files it writes yours.
- `KUBECONFIG` must point to a single file. A kubeconfig that references other files
  (certificates, `exec` plugins) needs those mounted too; the Rancher one is self-contained.
- The image runs `kubectl` too: `docker run --rm -it ... --entrypoint kubectl
  ghcr.io/hector295/os-upgrade:0.1.0 get nodes`.
- The registry is public: no `docker login` is needed. To use an internal registry, copy the
  image there (`docker pull`, `docker tag`, `docker push`).

## First use on a cluster

The configuration of each cluster is a directory (an overlay) kept outside the tool, for example
in a repo of your own with one directory per cluster:

```sh
export KUBECONFIG=~/.kube/my-cluster.yaml
kubectl config current-context                     # ALWAYS check which cluster you point to

os-upgrade init my-cluster --kernel 6.8.0-139-generic          # 22.04 -> 24.04
# os-upgrade init my-cluster --kernel 7.0.0-38-generic --target 26.04   # 24.04 -> 26.04
$EDITOR my-cluster/config.env my-cluster/kustomization.yaml    # proxy, mirror, registry, window...
os-upgrade export-crd my-cluster                   # my-cluster/crd-plans.json, from the cluster
os-upgrade validate my-cluster                     # renders my-cluster/manifests.yaml and validates it
os-upgrade apply my-cluster                        # creates the Plans; no node is affected yet
```

Then the [runbook](runbook.md) from step 0. The parameters and the overlay options are in
[configuration.md](configuration.md).

## Commands

| Command | What it does | Contacts the cluster |
|---|---|---|
| `os-upgrade init <dir> --kernel K [--target T]` | Creates `kustomization.yaml` and `config.env` | No |
| `os-upgrade export-crd <dir>` | Saves the Plan CRD in `<dir>/crd-plans.json` | Reads |
| `os-upgrade render <dir> [-o file\|-]` | Renders the overlay (default `<dir>/manifests.yaml`) | No |
| `os-upgrade validate <dir>` | Render + validation against `<dir>/crd-plans.json` | No |
| `os-upgrade apply <dir> [--yes]` | Validate, show the context, confirm and `kubectl apply` | Writes |
| `os-upgrade preflight ...` | Checks before a campaign ([runbook](runbook.md#0-before-the-campaign-once-per-cluster)) | Reads |
| `os-upgrade rollout ...` | Predownload, upgrade node by node, status ([runbook](runbook.md#4-window-with-rolloutsh-recommended)) | Writes |
| `os-upgrade check` | Detailed state of nodes, etcd, Jobs and pods | Reads |
| `os-upgrade version` | Version of the tool | No |

The first line of `manifests.yaml` records the tool version that rendered it.

## Publishing a release

From `main`, with `make check` green:

```sh
git tag v0.2.0 && git push origin v0.2.0
```

The `release` workflow runs `make check`, publishes the tarball and its sha256 on GitHub Releases
and pushes the image with the version tag and `latest`. Locally, `make dist` and `make image`
build the same thing in `dist/`.
