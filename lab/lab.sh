#!/bin/sh
# Reproducible libvirt lab: Ubuntu VMs (22.04 or 24.04) with RKE2 and the official
# system-upgrade-controller (v0.16.3), to test os-upgrade end to end without touching a real cluster.
#
# Usage: lab/lab.sh <command>
#   plan        show what would be created (changes nothing)
#   up          create the VMs, install RKE2 and the SUC, and leave the kubeconfig in $LAB_DIR
#   e2e         render + validation + apply + preflight + predownload + upgrade of every node
#               with os-upgrade, then check they end on the target version with the pinned kernel
#   status      lab VMs and cluster nodes
#   env         print the exports to use kubectl/rollout.sh against the lab
#   ssh <vm>    ssh into a lab VM (e.g. osu-lab-cp1)
#   reports     show the os-upgrade report of every node
#   down        delete the lab VMs and disks (only its own, by exact name)
#   destroy     like down, and also delete the base image from the pool and $LAB_DIR
#
# Configuration (environment variables):
#   LAB_CP=3 LAB_WORKERS=1 LAB_CPUS=2 LAB_MEM_MB=4096 LAB_DISK_GB=30
#   LAB_UEFI=false (true: VMs boot with UEFI, to test GRUB as on UEFI bare metal)
#   LAB_UBUNTU=22.04 (24.04: noble VMs, to test 24.04 -> 26.04 with LAB_OVERLAY=.../lab-vm-2604)
#   LAB_RKE2_VERSION=v1.33.13+rke2r2 (empty: use the LAB_RKE2_CHANNEL channel, e.g. v1.33)
#   LAB_POOL=default LAB_NET=default LIBVIRT_DEFAULT_URI=qemu:///system
#   LAB_DIR=<repo>/.lab LAB_PREFIX=osu-lab
#   LAB_IMAGE= (e.g. ghcr.io/hector295/os-upgrade:0.1.0: e2e runs os-upgrade from that image
#              with docker instead of bin/os-upgrade from the repo)
set -eu

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
LAB_PREFIX="${LAB_PREFIX:-osu-lab}"
LAB_DIR="${LAB_DIR:-$REPO_DIR/.lab}"
LAB_CP="${LAB_CP:-3}"
LAB_WORKERS="${LAB_WORKERS:-1}"
LAB_CPUS="${LAB_CPUS:-2}"
LAB_MEM_MB="${LAB_MEM_MB:-4096}"
LAB_DISK_GB="${LAB_DISK_GB:-30}"
LAB_UEFI="${LAB_UEFI:-false}"
LAB_UBUNTU="${LAB_UBUNTU:-22.04}"
LAB_POOL="${LAB_POOL:-default}"
LAB_NET="${LAB_NET:-default}"
LAB_RKE2_CHANNEL="${LAB_RKE2_CHANNEL:-v1.33}"
# Fixed version by default: a channel may point to a release that has no artifacts yet.
LAB_RKE2_VERSION="${LAB_RKE2_VERSION-v1.33.13+rke2r2}"
LAB_OVERLAY="${LAB_OVERLAY:-$REPO_DIR/manifests/overlays/lab-vm}"
LAB_IMAGE="${LAB_IMAGE:-}"
export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"

case "$LAB_UBUNTU" in
  22.04) LAB_CODENAME=jammy ;;
  24.04) LAB_CODENAME=noble ;;
  *) echo "unsupported LAB_UBUNTU: $LAB_UBUNTU (22.04 or 24.04)" >&2; exit 2 ;;
esac
IMAGE_URL="https://cloud-images.ubuntu.com/releases/$LAB_CODENAME/release"
IMAGE_NAME="ubuntu-$LAB_UBUNTU-server-cloudimg-amd64.img"
BASE_VOL="$LAB_PREFIX-base-$LAB_CODENAME.qcow2"
SUC_URL=https://github.com/rancher/system-upgrade-controller/releases/download/v0.16.3
SUC_CRD_SHA=d26cb57b27012e7ea2992e10707741e36c3eb2031bf8b41aaf7d1e611c878376
SUC_YAML_SHA=e08b240b349ffac89dd2a1a3276211711aabe3433eb253c712d592b74ce7595d
SUC_NS=system-upgrade

KEY="$LAB_DIR/id_ed25519"
KUBECONFIG_FILE="$LAB_DIR/kubeconfig"
TOOLS_BIN="$REPO_DIR/tools/bin"
# Pinned kubectl from tools/ (make tools): controlled version, without the quirks of the snap one.
KUBECTL="${KUBECTL:-$TOOLS_BIN/kubectl}"
export KUBECTL

info() { echo "$(date '+%H:%M:%S') $*"; }
die() { echo "$(date '+%H:%M:%S') ERROR: $*" >&2; exit 1; }

usage() {
  sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

# ------------------------------------------------------------------ topology
cp_names() { i=1; while [ "$i" -le "$LAB_CP" ]; do echo "$LAB_PREFIX-cp$i"; i=$((i + 1)); done; }
worker_names() { i=1; while [ "$i" -le "$LAB_WORKERS" ]; do echo "$LAB_PREFIX-w$i"; i=$((i + 1)); done; }
all_names() { cp_names; worker_names; }
first_cp() { cp_names | head -n1; }

# Only names from the lab topology: down/destroy never touch other VMs.
is_lab_vm() { all_names | grep -qx "$1"; }

# ------------------------------------------------------------------ libvirt
domain_exists() { virsh dominfo "$1" >/dev/null 2>&1; }
vol_exists() { virsh vol-info --pool "$LAB_POOL" "$1" >/dev/null 2>&1; }

vm_ip() {
  virsh domifaddr "$1" --source lease 2>/dev/null | awk '/ipv4/ {split($4, a, "/"); print a[1]; exit}'
}

wait_ip() {
  i=0
  while [ $i -lt 120 ]; do
    ip=$(vm_ip "$1")
    if [ -n "$ip" ]; then echo "$ip"; return 0; fi
    i=$((i + 1))
    sleep 5
  done
  die "$1 did not get an IP"
}

ssh_vm() {
  name=$1
  shift
  ip=$(vm_ip "$name")
  [ -n "$ip" ] || die "$name has no IP (is it running?)"
  ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    -o ConnectTimeout=10 "ubuntu@$ip" "$@"
}

wait_ssh() {
  i=0
  until ssh_vm "$1" true 2>/dev/null; do
    i=$((i + 1))
    [ $i -lt 60 ] || die "$1 does not answer over ssh"
    sleep 5
  done
  ssh_vm "$1" cloud-init status --wait >/dev/null || die "cloud-init failed on $1"
}

upload_volume() {
  vol=$1
  file=$2
  format=$3
  virsh vol-create-as "$LAB_POOL" "$vol" "$(stat -c %s "$file")" --format "$format" >/dev/null
  virsh vol-upload --pool "$LAB_POOL" "$vol" "$file"
}

ensure_base_image() {
  vol_exists "$BASE_VOL" && return 0
  img="$LAB_DIR/$IMAGE_NAME"
  if [ ! -f "$img" ]; then
    info "Downloading $IMAGE_NAME"
    curl -fSL -o "$img.part" "$IMAGE_URL/$IMAGE_NAME"
    sum=$(curl -fsSL "$IMAGE_URL/SHA256SUMS" | awk -v n="*$IMAGE_NAME" '$2 == n {print $1}')
    [ -n "$sum" ] || die "checksum for $IMAGE_NAME not found"
    echo "$sum  $img.part" | sha256sum -c --quiet - || die "wrong sha256 for $IMAGE_NAME"
    mv "$img.part" "$img"
  fi
  info "Uploading the base image to pool $LAB_POOL"
  upload_volume "$BASE_VOL" "$img" qcow2
}

write_seed() {
  name=$1
  dir="$LAB_DIR/seed-$name"
  mkdir -p "$dir"
  cat > "$dir/meta-data" <<EOF
instance-id: $name-$(date +%s)
local-hostname: $name
EOF
  cat > "$dir/user-data" <<EOF
#cloud-config
hostname: $name
manage_etc_hosts: true
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $(cat "$KEY.pub")
growpart:
  mode: auto
  devices: ["/"]
EOF
  genisoimage -quiet -output "$dir/seed.iso" -volid cidata -joliet -rock "$dir/user-data" "$dir/meta-data"
  echo "$dir/seed.iso"
}

create_vm() {
  name=$1
  if domain_exists "$name"; then info "$name already exists"; return 0; fi
  info "Creating $name ($LAB_CPUS CPU, $LAB_MEM_MB MB, $LAB_DISK_GB GB)"
  vol_exists "$name.qcow2" || virsh vol-create-as "$LAB_POOL" "$name.qcow2" "${LAB_DISK_GB}G" \
    --format qcow2 --backing-vol "$BASE_VOL" --backing-vol-format qcow2 >/dev/null
  seed=$(write_seed "$name")
  if vol_exists "$name-seed.iso"; then virsh vol-delete --pool "$LAB_POOL" "$name-seed.iso" >/dev/null; fi
  upload_volume "$name-seed.iso" "$seed" raw
  boot=""
  if [ "$LAB_UEFI" = true ]; then boot="--boot uefi"; fi
  # shellcheck disable=SC2086 # boot is one option or nothing
  virt-install --name "$name" --memory "$LAB_MEM_MB" --vcpus "$LAB_CPUS" --import $boot \
    --disk "vol=$LAB_POOL/$name.qcow2,bus=virtio" \
    --disk "vol=$LAB_POOL/$name-seed.iso,device=cdrom" \
    --os-variant "ubuntu$LAB_UBUNTU" --network "network=$LAB_NET,model=virtio" \
    --graphics none --noautoconsole >/dev/null
}

delete_vm() {
  name=$1
  is_lab_vm "$name" || die "refused: $name does not belong to the lab"
  if domain_exists "$name"; then
    info "Deleting $name"
    virsh destroy "$name" >/dev/null 2>&1 || true
    virsh undefine "$name" --nvram >/dev/null 2>&1 || virsh undefine "$name" >/dev/null
  fi
  for v in "$name.qcow2" "$name-seed.iso"; do
    if vol_exists "$v"; then virsh vol-delete --pool "$LAB_POOL" "$v" >/dev/null; fi
  done
}

# ------------------------------------------------------------------ RKE2
install_rke2() {
  name=$1
  kind=$2
  server_ip=${3:-}
  token=$(cat "$LAB_DIR/token")
  if ssh_vm "$name" "systemctl is-active --quiet rke2-$kind" 2>/dev/null; then
    info "$name: rke2-$kind already active"
    return 0
  fi
  info "$name: installing RKE2 ($kind, ${LAB_RKE2_VERSION:-channel $LAB_RKE2_CHANNEL})"
  {
    echo "token: $token"
    [ -z "$server_ip" ] || echo "server: https://$server_ip:9345"
    [ "$kind" = agent ] || echo "tls-san: [\"$(vm_ip "$name")\"]"
  } | ssh_vm "$name" "sudo mkdir -p /etc/rancher/rke2 && sudo tee /etc/rancher/rke2/config.yaml >/dev/null"
  if [ -n "$LAB_RKE2_VERSION" ]; then install_env="INSTALL_RKE2_VERSION=$LAB_RKE2_VERSION"; else install_env="INSTALL_RKE2_CHANNEL=$LAB_RKE2_CHANNEL"; fi
  ssh_vm "$name" "curl -sfL https://get.rke2.io | sudo INSTALL_RKE2_TYPE=$kind $install_env sh - >/dev/null && sudo systemctl enable --now rke2-$kind"
}

# Check that the RKE2 release has published artifacts before installing.
check_rke2_release() {
  [ -n "$LAB_RKE2_VERSION" ] || return 0
  v=$(echo "$LAB_RKE2_VERSION" | sed 's/+/%2B/')
  curl -fsSL -o /dev/null "https://github.com/rancher/rke2/releases/download/$v/sha256sum-amd64.txt" \
    || die "RKE2 release $LAB_RKE2_VERSION has no published artifacts; pick another one with LAB_RKE2_VERSION"
}

kc() { KUBECONFIG="$KUBECONFIG_FILE" "$KUBECTL" "$@"; }

wait_node_ready() {
  i=0
  until kc get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -qx True; do
    i=$((i + 1))
    [ $i -lt 240 ] || die "$1 not Ready after 20 min"
    sleep 5
  done
  info "$1 Ready"
}

install_suc() {
  for f in crd.yaml system-upgrade-controller.yaml; do
    [ -f "$LAB_DIR/$f" ] || curl -fsSL -o "$LAB_DIR/$f" "$SUC_URL/$f"
  done
  echo "$SUC_CRD_SHA  $LAB_DIR/crd.yaml" | sha256sum -c --quiet - || die "wrong sha256 for crd.yaml"
  echo "$SUC_YAML_SHA  $LAB_DIR/system-upgrade-controller.yaml" | sha256sum -c --quiet - || die "wrong sha256 for the SUC manifest"
  kc apply -f "$LAB_DIR/crd.yaml" >/dev/null
  kc apply -f "$LAB_DIR/system-upgrade-controller.yaml" >/dev/null
  kc -n "$SUC_NS" rollout status deploy/system-upgrade-controller --timeout=300s >/dev/null
  mkdir -p "$LAB_DIR/schema"
  kc get crd plans.upgrade.cattle.io -o json > "$LAB_DIR/schema/crd-plans.json"
  info "system-upgrade-controller v0.16.3 ready in $SUC_NS"
}

# ------------------------------------------------------------------ commands
cmd_plan() {
  echo "Lab '$LAB_PREFIX' on $LIBVIRT_DEFAULT_URI (pool $LAB_POOL, network $LAB_NET):"
  for n in $(cp_names); do echo "  $n  control plane + etcd  ${LAB_CPUS} CPU ${LAB_MEM_MB} MB ${LAB_DISK_GB} GB"; done
  for n in $(worker_names); do echo "  $n  worker                ${LAB_CPUS} CPU ${LAB_MEM_MB} MB ${LAB_DISK_GB} GB"; done
  echo "  Ubuntu $LAB_UBUNTU ($LAB_CODENAME); image: $IMAGE_NAME (volume $BASE_VOL), boot $( [ "$LAB_UEFI" = true ] && echo UEFI || echo BIOS)"
  echo "  RKE2: ${LAB_RKE2_VERSION:-channel $LAB_RKE2_CHANNEL}; SUC v0.16.3 in $SUC_NS"
  echo "  total: $(( (LAB_CP + LAB_WORKERS) * LAB_MEM_MB )) MB of RAM, $(( (LAB_CP + LAB_WORKERS) * LAB_CPUS )) vCPU"
  echo "  local state: $LAB_DIR"
}

cmd_up() {
  for c in virsh virt-install genisoimage curl ssh ssh-keygen sha256sum "$KUBECTL"; do
    command -v "$c" >/dev/null 2>&1 || die "missing $c (the tools in tools/ are installed with 'make tools')"
  done
  virsh pool-info "$LAB_POOL" >/dev/null 2>&1 || die "libvirt pool '$LAB_POOL' does not exist"
  virsh net-info "$LAB_NET" >/dev/null 2>&1 || die "libvirt network '$LAB_NET' does not exist"
  mkdir -p "$LAB_DIR"
  [ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N "" -C "$LAB_PREFIX" -f "$KEY"
  check_rke2_release
  [ -f "$LAB_DIR/token" ] || head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$LAB_DIR/token"
  cmd_plan
  ensure_base_image
  for n in $(all_names); do create_vm "$n"; done
  for n in $(all_names); do
    info "$n: IP $(wait_ip "$n"), waiting for cloud-init"
    wait_ssh "$n"
  done

  cp1=$(first_cp)
  cp1_ip=$(vm_ip "$cp1")
  install_rke2 "$cp1" server
  i=0
  until ssh_vm "$cp1" "sudo test -f /etc/rancher/rke2/rke2.yaml"; do
    i=$((i + 1)); [ $i -lt 60 ] || die "RKE2 does not start on $cp1"; sleep 5
  done
  ssh_vm "$cp1" "sudo cat /etc/rancher/rke2/rke2.yaml" | sed "s/127.0.0.1/$cp1_ip/" > "$KUBECONFIG_FILE"
  chmod 600 "$KUBECONFIG_FILE"
  wait_node_ready "$cp1"
  for n in $(cp_names | tail -n +2); do
    install_rke2 "$n" server "$cp1_ip"
    wait_node_ready "$n"
  done
  for n in $(worker_names); do
    install_rke2 "$n" agent "$cp1_ip"
    wait_node_ready "$n"
  done

  # os-upgrade groups: workers in 1, control plane in 2.
  for n in $(worker_names); do kc label node "$n" os-upgrade-group=1 --overwrite >/dev/null; done
  for n in $(cp_names); do kc label node "$n" os-upgrade-group=2 --overwrite >/dev/null; done
  install_suc
  ssh_vm "$cp1" "sudo /usr/local/bin/rke2 etcd-snapshot save --name lab >/dev/null 2>&1 || sudo rke2 etcd-snapshot save --name lab >/dev/null"
  info "etcd snapshot taken"
  echo
  kc get nodes -o wide
  echo
  echo "Lab ready. To use it: eval \"\$(lab/lab.sh env)\""
}

cmd_env() {
  echo "export KUBECONFIG='$KUBECONFIG_FILE'"
  echo "export NS=$SUC_NS"
  echo "export KUBECTL='$KUBECTL'"
  echo "alias kubectl='$KUBECTL'"
}

cmd_status() {
  for n in $(all_names); do
    if domain_exists "$n"; then
      printf '%-20s %-10s %s\n' "$n" "$(virsh domstate "$n" 2>/dev/null)" "$(vm_ip "$n")"
    else
      printf '%-20s %s\n' "$n" "does not exist"
    fi
  done
  if [ -f "$KUBECONFIG_FILE" ]; then echo; kc get nodes -o wide -L os-upgrade,os-upgrade-group 2>&1 || true; fi
}

cmd_reports() {
  for n in $(all_names); do
    echo "===== $n"
    ssh_vm "$n" "cat /var/log/os-upgrade-report.txt 2>/dev/null || echo '(no report)'"
  done
}

# os-upgrade from the repo, or from LAB_IMAGE. The image sees $LAB_DIR/e2e as /work and uses the
# host network (the API is on the libvirt network).
osu() {
  if [ -n "$LAB_IMAGE" ]; then
    docker run --rm --network host --user "$(id -u):$(id -g)" -v /etc/localtime:/etc/localtime:ro \
      -v "$LAB_DIR/e2e:/work" -v "$KUBECONFIG_FILE:/kube/config:ro" -e KUBECONFIG=/kube/config \
      -e NS="$SUC_NS" ${ETCD_MIN_MEMBERS:+-e ETCD_MIN_MEMBERS="$ETCD_MIN_MEMBERS"} \
      "$LAB_IMAGE" "$@"
  else
    (cd "$LAB_DIR/e2e" && "$REPO_DIR/bin/os-upgrade" "$@")
  fi
}

cmd_e2e() {
  [ -f "$KUBECONFIG_FILE" ] || die "no lab: run 'lab/lab.sh up' first"
  export KUBECONFIG="$KUBECONFIG_FILE" NS="$SUC_NS"
  start=$(date +%s)
  # The overlay as an operator keeps it: its own directory with the CRD exported from the lab.
  rm -rf "$LAB_DIR/e2e"
  mkdir -p "$LAB_DIR/e2e"
  cp -R "$LAB_OVERLAY" "$LAB_DIR/e2e/cluster"
  cp "$LAB_DIR/schema/crd-plans.json" "$LAB_DIR/e2e/cluster/"
  out="$LAB_DIR/e2e/cluster/manifests.yaml"
  info "os-upgrade $(osu version)${LAB_IMAGE:+ (image $LAB_IMAGE)}: render, validation and apply of $LAB_OVERLAY"
  osu apply cluster --yes
  kernel=$("$TOOLS_BIN/yq" 'select(.kind == "ConfigMap") | .data.KERNEL_VERSION' "$out")
  target=$("$TOOLS_BIN/yq" 'select(.kind == "ConfigMap") | .data.TARGET_VERSION' "$out")

  osu preflight
  for g in 1 2; do
    osu rollout predownload --group "$g" --wait --yes
  done
  for g in 1 2; do
    osu rollout upgrade --group "$g" --yes
  done

  info "Final check"
  bad=$("$KUBECTL" get nodes -o json | "$TOOLS_BIN/yq" -p json ".items[] | select((.status.nodeInfo.osImage | test(\"Ubuntu $target\") | not) or .status.nodeInfo.kernelVersion != \"$kernel\") | .metadata.name")
  osu check >/dev/null || die "os-upgrade check reports problems"
  [ -z "$bad" ] || die "nodes not upgraded: $bad"
  osu rollout status
  info "E2E OK in $(( ($(date +%s) - start) / 60 )) min: all nodes on Ubuntu $target with $kernel"
}

cmd_down() {
  for n in $(all_names); do delete_vm "$n"; done
  rm -rf "$LAB_DIR"/seed-* "$KUBECONFIG_FILE"
  info "Lab VMs deleted (the base image and $LAB_DIR are kept)"
}

cmd_destroy() {
  cmd_down
  if vol_exists "$BASE_VOL"; then virsh vol-delete --pool "$LAB_POOL" "$BASE_VOL" >/dev/null; fi
  rm -rf "$LAB_DIR"
  info "Lab fully removed"
}

case "${1:-}" in
  plan) cmd_plan ;;
  up) cmd_up ;;
  e2e) cmd_e2e ;;
  status) cmd_status ;;
  env) cmd_env ;;
  ssh) [ $# -ge 2 ] || usage; is_lab_vm "$2" || die "$2 is not a lab VM"; n=$2; shift 2; ssh_vm "$n" "$@" ;;
  reports) cmd_reports ;;
  down) cmd_down ;;
  destroy) cmd_destroy ;;
  *) usage ;;
esac
