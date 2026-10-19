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
#   ssh <vm>    ssh into a lab VM (e.g. osu-lab-cp1, osu-lab-proxy)
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
#   LAB_PREDOWNLOAD=groups (parallel: e2e predownloads every node at once, with the Plan
#              concurrency raised to the number of nodes, and checks that they overlapped)
#   LAB_IMAGE= (e.g. ghcr.io/hector295/os-upgrade:0.1.0: e2e runs os-upgrade from that image
#              with docker instead of bin/os-upgrade from the repo)
#   LAB_PROXY=off (open | auth: up adds a squid VM, osu-lab-proxy, and the nodes can only reach
#              the Internet through it; auth requires a user and a password with special
#              characters. e2e configures os-upgrade with it: config.env for open, proxy.env
#              (Secret) for auth. Chosen at up time; later commands use the saved mode)
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
LAB_PREDOWNLOAD="${LAB_PREDOWNLOAD:-groups}"
LAB_PROXY="${LAB_PROXY:-}"
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
PROXY_VM="$LAB_PREFIX-proxy"
PROXY_MODE_FILE="$LAB_DIR/proxy-mode"
PROXY_PASS_FILE="$LAB_DIR/proxy-password"
PROXY_USER=osu
# Destinations that never go through the proxy: lab network, cluster CIDRs and services.
LAB_NO_PROXY=127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.svc,.cluster.local
KUBECONFIG_FILE="$LAB_DIR/kubeconfig"
TOOLS_BIN="$REPO_DIR/tools/bin"
# Pinned kubectl from tools/ (make tools): controlled version, without the quirks of the snap one.
KUBECTL="${KUBECTL:-$TOOLS_BIN/kubectl}"
export KUBECTL

info() { echo "$(date '+%H:%M:%S') $*"; }
die() { echo "$(date '+%H:%M:%S') ERROR: $*" >&2; exit 1; }
warn() { echo "$(date '+%H:%M:%S') WARNING: $*" >&2; }

usage() {
  awk 'NR > 1 && /^set -eu/ {exit} NR > 1' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

# ------------------------------------------------------------------ topology
cp_names() { i=1; while [ "$i" -le "$LAB_CP" ]; do echo "$LAB_PREFIX-cp$i"; i=$((i + 1)); done; }
worker_names() { i=1; while [ "$i" -le "$LAB_WORKERS" ]; do echo "$LAB_PREFIX-w$i"; i=$((i + 1)); done; }
all_names() { cp_names; worker_names; }
first_cp() { cp_names | head -n1; }

# Only names from the lab topology (and its proxy): down/destroy never touch other VMs.
lab_vms() { all_names; echo "$PROXY_VM"; }
is_lab_vm() { lab_vms | grep -qx "$1"; }

# Proxy mode: LAB_PROXY, or the one saved by up, or off.
proxy_mode() {
  if [ -n "$LAB_PROXY" ]; then echo "$LAB_PROXY"
  elif [ -f "$PROXY_MODE_FILE" ]; then cat "$PROXY_MODE_FILE"
  else echo off
  fi
}

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
  extra=${2:-}
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
  [ -z "$extra" ] || echo "$extra" >> "$dir/user-data"
  genisoimage -quiet -output "$dir/seed.iso" -volid cidata -joliet -rock "$dir/user-data" "$dir/meta-data"
  echo "$dir/seed.iso"
}

# create_vm <name> [<extra cloud-init>] [<cpus> <mem MB> <disk GB>]
create_vm() {
  name=$1
  extra=${2:-}
  cpus=${3:-$LAB_CPUS}
  mem=${4:-$LAB_MEM_MB}
  disk=${5:-$LAB_DISK_GB}
  if domain_exists "$name"; then info "$name already exists"; return 0; fi
  info "Creating $name ($cpus CPU, $mem MB, $disk GB)"
  vol_exists "$name.qcow2" || virsh vol-create-as "$LAB_POOL" "$name.qcow2" "${disk}G" \
    --format qcow2 --backing-vol "$BASE_VOL" --backing-vol-format qcow2 >/dev/null
  seed=$(write_seed "$name" "$extra")
  if vol_exists "$name-seed.iso"; then virsh vol-delete --pool "$LAB_POOL" "$name-seed.iso" >/dev/null; fi
  upload_volume "$name-seed.iso" "$seed" raw
  boot=""
  if [ "$LAB_UEFI" = true ]; then boot="--boot uefi"; fi
  # shellcheck disable=SC2086 # boot is one option or nothing
  virt-install --name "$name" --memory "$mem" --vcpus "$cpus" --import $boot \
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

# ------------------------------------------------------------------ proxy
# The password has characters that must be percent-encoded in a URL (@ : !).
proxy_password() { cat "$PROXY_PASS_FILE"; }
proxy_password_encoded() { proxy_password | sed 's/@/%40/g; s/:/%3A/g; s/!/%21/g'; }

proxy_url() {
  ip=$(vm_ip "$PROXY_VM")
  [ -n "$ip" ] || die "$PROXY_VM has no IP (is it running?)"
  if [ "$(proxy_mode)" = auth ]; then
    echo "http://$PROXY_USER:$(proxy_password_encoded)@$ip:3128"
  else
    echo "http://$ip:3128"
  fi
}

# cloud-init for the proxy VM: squid for the lab network, with basic auth in auth mode.
proxy_user_data() {
  cat <<EOF
packages: [squid]
write_files:
  - path: /etc/squid/conf.d/osu-lab.conf
    content: |
      acl lab_net src 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16
EOF
  if [ "$(proxy_mode)" = auth ]; then
    cat <<EOF
      auth_param basic program /usr/lib/squid/basic_ncsa_auth /etc/squid/osu-lab.passwd
      auth_param basic realm osu-lab
      acl lab_users proxy_auth REQUIRED
      http_access allow lab_net lab_users
  - path: /etc/squid/osu-lab.passwd
    permissions: '0644'
    content: |
      $PROXY_USER:$(openssl passwd -apr1 "$(proxy_password)")
EOF
  else
    echo "      http_access allow lab_net"
  fi
  cat <<EOF
runcmd:
  - systemctl restart squid
EOF
}

# Firewall of the nodes: no direct Internet access, only private destinations (the proxy is
# one). Loaded by nftables.service on every boot; the counters show what was blocked.
# Without sets: with a set in this table, the nft bundled in calico (canal) segfaults on 26.04
# and the canal pod of the node never becomes ready.
egress_rules() {
  cat <<'EOF'
#!/usr/sbin/nft -f
# osu-lab: the Internet only through the lab proxy.
table ip osu_lab_egress
delete table ip osu_lab_egress
table ip osu_lab_egress {
  chain output {
    type filter hook output priority 0; policy accept
    oif "lo" accept
    ip daddr 10.0.0.0/8 accept
    ip daddr 127.0.0.0/8 accept
    ip daddr 169.254.0.0/16 accept
    ip daddr 172.16.0.0/12 accept
    ip daddr 192.168.0.0/16 accept
    ip daddr 224.0.0.0/4 accept
    ip daddr 255.255.255.255 accept
    counter reject
  }
  chain forward {
    type filter hook forward priority 0; policy accept
    ip daddr 10.0.0.0/8 accept
    ip daddr 172.16.0.0/12 accept
    ip daddr 192.168.0.0/16 accept
    counter reject
  }
}
EOF
}

# Before RKE2: firewall, and the proxy for rke2 and containerd (images) as in a cluster
# behind a proxy. Then check that the node only reaches the Internet through the proxy.
setup_node_proxy() {
  name=$1
  url=$(proxy_url)
  ssh_vm "$name" "command -v nft >/dev/null || sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q nftables >/dev/null"
  egress_rules | ssh_vm "$name" "sudo tee /etc/nftables.conf >/dev/null && sudo systemctl enable --now nftables >/dev/null 2>&1 && sudo nft -f /etc/nftables.conf"
  for kind in server agent; do
    printf 'HTTP_PROXY=%s\nHTTPS_PROXY=%s\nNO_PROXY=%s\n' "$url" "$url" "$LAB_NO_PROXY" \
      | ssh_vm "$name" "sudo tee /etc/default/rke2-$kind >/dev/null && sudo chmod 600 /etc/default/rke2-$kind"
  done
  if ssh_vm "$name" "curl -s -o /dev/null -m 10 http://archive.ubuntu.com/ubuntu/"; then
    die "$name still reaches the Internet without the proxy"
  fi
  ssh_vm "$name" "curl -sf -o /dev/null -m 20 -x '$url' http://archive.ubuntu.com/ubuntu/ && curl -sf -o /dev/null -m 20 -x '$url' https://get.rke2.io" \
    || die "$name does not reach the Internet through the proxy"
  info "$name: Internet only through $PROXY_VM"
}

create_proxy() {
  if [ "$(proxy_mode)" = auth ] && [ ! -f "$PROXY_PASS_FILE" ]; then
    ( umask 077 && printf '%s@:!x' "$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')" > "$PROXY_PASS_FILE" )
  fi
  create_vm "$PROXY_VM" "$(proxy_user_data)" 1 1024 10
  info "$PROXY_VM: IP $(wait_ip "$PROXY_VM"), waiting for cloud-init"
  wait_ssh "$PROXY_VM"
  url=$(proxy_url)
  if ! curl -sf -o /dev/null -m 20 -x "$url" http://archive.ubuntu.com/ubuntu/ \
    || ! curl -sf -o /dev/null -m 20 -x "$url" https://get.rke2.io; then
    die "$PROXY_VM does not work as a proxy"
  fi
  if [ "$(proxy_mode)" = auth ]; then
    code=$(curl -s -o /dev/null -m 20 -w '%{http_code}' -x "http://$(vm_ip "$PROXY_VM"):3128" http://archive.ubuntu.com/ || true)
    [ "$code" = 407 ] || die "$PROXY_VM accepts requests without credentials (HTTP $code)"
  fi
  info "$PROXY_VM: squid ready ($(proxy_mode))"
}

# After e2e: evidence that every node used the proxy and that no credential reached the logs.
proxy_evidence() {
  # access.log.1 only exists if logrotate ran during the e2e.
  log=$(ssh_vm "$PROXY_VM" "sudo sh -c 'cat /var/log/squid/access.log.1 /var/log/squid/access.log 2>/dev/null; true'")
  for n in $(all_names); do
    ip=$(vm_ip "$n")
    total=$(echo "$log" | awk -v ip="$ip" '$3 == ip' | wc -l)
    ubuntu=$(echo "$log" | awk -v ip="$ip" '$3 == ip && $7 ~ /ubuntu\.com/' | wc -l)
    blocked=$(ssh_vm "$n" "sudo nft list chain ip osu_lab_egress output" | sed -n 's/.*counter packets \([0-9]*\).*/\1/p')
    info "$n: $total requests through the proxy ($ubuntu to *.ubuntu.com); direct connections blocked: ${blocked:-?}"
    [ -n "$blocked" ] || warn "$n: the egress firewall is gone after the upgrade (/etc/nftables.conf replaced?)"
    [ "$ubuntu" -gt 0 ] || die "$n did not download from Ubuntu through the proxy"
    if [ "$(proxy_mode)" = auth ]; then
      anon=$(echo "$log" | awk -v ip="$ip" -v user="$PROXY_USER" '$3 == ip && $4 !~ /\/407$/ && $8 != user' | wc -l)
      [ "$anon" -eq 0 ] || die "$n: $anon requests went through without the proxy user"
      leaks=$(ssh_vm "$n" "sudo grep -rlF -e '$(proxy_password)' -e '$(proxy_password_encoded)' /var/log 2>/dev/null" \
        | grep -E 'os-upgrade|dist-upgrade|/apt/|apply-os-upgrade' || true)
      [ -z "$leaks" ] || die "$n: the proxy password appears in: $(echo "$leaks" | tr '\n' ' ')"
    fi
  done
  if [ "$(proxy_mode)" = auth ]; then info "Proxy password not found in the os-upgrade, apt or dist-upgrade logs"; fi
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
  proxy_env=""
  curl_proxy=""
  if [ "$(proxy_mode)" != off ]; then
    url=$(proxy_url)
    proxy_env="http_proxy='$url' https_proxy='$url'"
    curl_proxy="-x '$url'"
  fi
  ssh_vm "$name" "curl -sfL $curl_proxy https://get.rke2.io | sudo env $proxy_env INSTALL_RKE2_TYPE=$kind $install_env sh - >/dev/null && sudo systemctl enable --now rke2-$kind"
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
  if [ "$(proxy_mode)" != off ]; then
    echo "  $PROXY_VM  squid ($(proxy_mode)), 1 CPU 1024 MB; the nodes only reach the Internet through it"
  fi
  echo "  total: $(( (LAB_CP + LAB_WORKERS) * LAB_MEM_MB )) MB of RAM, $(( (LAB_CP + LAB_WORKERS) * LAB_CPUS )) vCPU"
  echo "  local state: $LAB_DIR"
}

cmd_up() {
  case "$(proxy_mode)" in off|open|auth) ;; *) die "LAB_PROXY must be off, open or auth" ;; esac
  for c in virsh virt-install genisoimage curl ssh ssh-keygen sha256sum openssl "$KUBECTL"; do
    command -v "$c" >/dev/null 2>&1 || die "missing $c (the tools in tools/ are installed with 'make tools')"
  done
  virsh pool-info "$LAB_POOL" >/dev/null 2>&1 || die "libvirt pool '$LAB_POOL' does not exist"
  virsh net-info "$LAB_NET" >/dev/null 2>&1 || die "libvirt network '$LAB_NET' does not exist"
  mkdir -p "$LAB_DIR"
  [ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N "" -C "$LAB_PREFIX" -f "$KEY"
  check_rke2_release
  [ -f "$LAB_DIR/token" ] || head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$LAB_DIR/token"
  cmd_plan
  proxy_mode > "$PROXY_MODE_FILE"
  ensure_base_image
  [ "$(proxy_mode)" = off ] || create_proxy
  for n in $(all_names); do create_vm "$n"; done
  for n in $(all_names); do
    info "$n: IP $(wait_ip "$n"), waiting for cloud-init"
    wait_ssh "$n"
    [ "$(proxy_mode)" = off ] || setup_node_proxy "$n"
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
  for n in $(lab_vms); do
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

# Most predownload Jobs that were running at the same time (from their start/completion times).
max_parallel_predownload() {
  kc -n "$SUC_NS" get jobs -l upgrade.cattle.io/plan=os-upgrade-predownload -o json \
    | "$TOOLS_BIN/yq" -p json '.items[] | [.status.startTime, .status.completionTime // ""] | @tsv' \
    | while IFS='	' read -r start end; do
        echo "$(date -d "$start" +%s) 1"
        [ -z "$end" ] || echo "$(date -d "$end" +%s) -1"
      done \
    | sort -k1,1n -k2,2n | awk '{c += $2; if (c > m) m = c} END {print m + 0}'
}

cmd_e2e() {
  [ -f "$KUBECONFIG_FILE" ] || die "no lab: run 'lab/lab.sh up' first"
  case "$LAB_PREDOWNLOAD" in groups|parallel) ;; *) die "LAB_PREDOWNLOAD must be groups or parallel" ;; esac
  export KUBECONFIG="$KUBECONFIG_FILE" NS="$SUC_NS"
  start=$(date +%s)
  # The overlay as an operator keeps it: its own directory with the CRD exported from the lab.
  rm -rf "$LAB_DIR/e2e"
  mkdir -p "$LAB_DIR/e2e"
  cp -R "$LAB_OVERLAY" "$LAB_DIR/e2e/cluster"
  cp "$LAB_DIR/schema/crd-plans.json" "$LAB_DIR/e2e/cluster/"
  case "$(proxy_mode)" in
    open)
      printf '\nHTTP_PROXY=%s\nHTTPS_PROXY=%s\nNO_PROXY=%s\n' "$(proxy_url)" "$(proxy_url)" "$LAB_NO_PROXY" \
        >> "$LAB_DIR/e2e/cluster/config.env" ;;
    auth)
      # Credentials in the proxy Secret, never in config.env.
      ( umask 077 && printf 'HTTP_PROXY=%s\nHTTPS_PROXY=%s\nNO_PROXY=%s\n' "$(proxy_url)" "$(proxy_url)" "$LAB_NO_PROXY" \
        > "$LAB_DIR/e2e/cluster/proxy.env" )
      "$TOOLS_BIN/yq" -i '.secretGenerator += [{"name": "os-upgrade-proxy", "behavior": "merge", "envs": ["proxy.env"]}]' \
        "$LAB_DIR/e2e/cluster/kustomization.yaml" ;;
  esac
  nodes=$(all_names | wc -l)
  if [ "$LAB_PREDOWNLOAD" = parallel ]; then
    "$TOOLS_BIN/yq" -i ".patches += [{\"target\": {\"kind\": \"Plan\", \"name\": \"os-upgrade-predownload\"},
      \"patch\": \"- op: replace\\n  path: /spec/concurrency\\n  value: $nodes\\n\"}]" "$LAB_DIR/e2e/cluster/kustomization.yaml"
  fi
  out="$LAB_DIR/e2e/cluster/manifests.yaml"
  info "os-upgrade $(osu version)${LAB_IMAGE:+ (image $LAB_IMAGE)}: render, validation and apply of $LAB_OVERLAY (proxy: $(proxy_mode))"
  osu apply cluster --yes
  kernel=$("$TOOLS_BIN/yq" 'select(.kind == "ConfigMap") | .data.KERNEL_VERSION' "$out")
  target=$("$TOOLS_BIN/yq" 'select(.kind == "ConfigMap") | .data.TARGET_VERSION' "$out")

  osu preflight
  if [ "$LAB_PREDOWNLOAD" = parallel ]; then
    osu rollout predownload --nodes "$(all_names | paste -sd, -)" --wait --yes
    parallel=$(max_parallel_predownload)
    info "Predownload: up to $parallel of $nodes nodes at once"
    [ "$parallel" -eq "$nodes" ] || die "the predownload did not run on every node at once"
  else
    for g in 1 2; do
      osu rollout predownload --group "$g" --wait --yes
    done
  fi
  for g in 1 2; do
    osu rollout upgrade --group "$g" --yes
  done

  info "Final check"
  bad=$("$KUBECTL" get nodes -o json | "$TOOLS_BIN/yq" -p json ".items[] | select((.status.nodeInfo.osImage | test(\"Ubuntu $target\") | not) or .status.nodeInfo.kernelVersion != \"$kernel\") | .metadata.name")
  osu check >/dev/null || die "os-upgrade check reports problems"
  [ -z "$bad" ] || die "nodes not upgraded: $bad"
  osu rollout status
  [ "$(proxy_mode)" = off ] || proxy_evidence
  info "E2E OK in $(( ($(date +%s) - start) / 60 )) min: all nodes on Ubuntu $target with $kernel"
}

cmd_down() {
  for n in $(lab_vms); do delete_vm "$n"; done
  rm -rf "$LAB_DIR"/seed-* "$KUBECONFIG_FILE" "$PROXY_MODE_FILE" "$PROXY_PASS_FILE"
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
