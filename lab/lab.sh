#!/bin/sh
# Lab reproducible con libvirt: VMs Ubuntu (22.04 o 24.04) con RKE2 y el system-upgrade-controller
# oficial (v0.16.3), para probar os-upgrade de principio a fin sin tocar ningún cluster real.
#
# Uso: lab/lab.sh <comando>
#   plan        muestra lo que se crearía (no cambia nada)
#   up          crea las VMs, instala RKE2, el SUC y deja el kubeconfig en $LAB_DIR
#   e2e         render + validación + apply + preflight + predownload + upgrade de todos los
#               nodos con rollout.sh, y comprueba que quedan en la versión destino con el kernel fijado
#   status      VMs del lab y nodos del cluster
#   env         imprime los export para usar kubectl/rollout.sh contra el lab
#   ssh <vm>    ssh a una VM del lab (p. ej. osu-lab-cp1)
#   reports     muestra el informe de os-upgrade de cada nodo
#   down        borra las VMs y discos del lab (solo los suyos, por nombre exacto)
#   destroy     como down y además borra la imagen base del pool y $LAB_DIR
#
# Configuración (variables de entorno):
#   LAB_CP=3 LAB_WORKERS=1 LAB_CPUS=2 LAB_MEM_MB=4096 LAB_DISK_GB=30
#   LAB_UEFI=false (true: las VMs arrancan con UEFI, para probar GRUB como en bare metal UEFI)
#   LAB_UBUNTU=22.04 (24.04: VMs en noble, para probar 24.04 -> 26.04 con LAB_OVERLAY=.../lab-vm-2604)
#   LAB_RKE2_VERSION=v1.33.13+rke2r2 (vacío: usar el canal LAB_RKE2_CHANNEL, p. ej. v1.33)
#   LAB_POOL=default LAB_NET=default LIBVIRT_DEFAULT_URI=qemu:///system
#   LAB_DIR=<repo>/.lab LAB_PREFIX=osu-lab
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
# Versión fija por defecto: un canal puede apuntar a una release aún sin artefactos.
LAB_RKE2_VERSION="${LAB_RKE2_VERSION-v1.33.13+rke2r2}"
LAB_OVERLAY="${LAB_OVERLAY:-$REPO_DIR/manifests/overlays/lab-vm}"
export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"

case "$LAB_UBUNTU" in
  22.04) LAB_CODENAME=jammy ;;
  24.04) LAB_CODENAME=noble ;;
  *) echo "LAB_UBUNTU no soportado: $LAB_UBUNTU (22.04 o 24.04)" >&2; exit 2 ;;
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
# kubectl fijado de tools/ (make tools): versión controlada y sin las rarezas del de snap.
KUBECTL="${KUBECTL:-$TOOLS_BIN/kubectl}"
export KUBECTL

info() { echo "$(date '+%H:%M:%S') $*"; }
die() { echo "$(date '+%H:%M:%S') ERROR: $*" >&2; exit 1; }

usage() {
  sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

# ------------------------------------------------------------------ topología
cp_names() { i=1; while [ "$i" -le "$LAB_CP" ]; do echo "$LAB_PREFIX-cp$i"; i=$((i + 1)); done; }
worker_names() { i=1; while [ "$i" -le "$LAB_WORKERS" ]; do echo "$LAB_PREFIX-w$i"; i=$((i + 1)); done; }
all_names() { cp_names; worker_names; }
first_cp() { cp_names | head -n1; }

# Solo nombres de la topología del lab: down/destroy nunca tocan otras VMs.
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
  die "$1 no obtuvo IP"
}

ssh_vm() {
  name=$1
  shift
  ip=$(vm_ip "$name")
  [ -n "$ip" ] || die "$name no tiene IP (¿está encendida?)"
  ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    -o ConnectTimeout=10 "ubuntu@$ip" "$@"
}

wait_ssh() {
  i=0
  until ssh_vm "$1" true 2>/dev/null; do
    i=$((i + 1))
    [ $i -lt 60 ] || die "$1 no responde por ssh"
    sleep 5
  done
  ssh_vm "$1" cloud-init status --wait >/dev/null || die "cloud-init falló en $1"
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
    info "Descargando $IMAGE_NAME"
    curl -fSL -o "$img.part" "$IMAGE_URL/$IMAGE_NAME"
    sum=$(curl -fsSL "$IMAGE_URL/SHA256SUMS" | awk -v n="*$IMAGE_NAME" '$2 == n {print $1}')
    [ -n "$sum" ] || die "no se encontró la suma de $IMAGE_NAME"
    echo "$sum  $img.part" | sha256sum -c --quiet - || die "sha256 incorrecto de $IMAGE_NAME"
    mv "$img.part" "$img"
  fi
  info "Subiendo la imagen base al pool $LAB_POOL"
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
  if domain_exists "$name"; then info "$name ya existe"; return 0; fi
  info "Creando $name ($LAB_CPUS CPU, $LAB_MEM_MB MB, $LAB_DISK_GB GB)"
  vol_exists "$name.qcow2" || virsh vol-create-as "$LAB_POOL" "$name.qcow2" "${LAB_DISK_GB}G" \
    --format qcow2 --backing-vol "$BASE_VOL" --backing-vol-format qcow2 >/dev/null
  seed=$(write_seed "$name")
  if vol_exists "$name-seed.iso"; then virsh vol-delete --pool "$LAB_POOL" "$name-seed.iso" >/dev/null; fi
  upload_volume "$name-seed.iso" "$seed" raw
  boot=""
  if [ "$LAB_UEFI" = true ]; then boot="--boot uefi"; fi
  # shellcheck disable=SC2086 # boot es una opción o nada
  virt-install --name "$name" --memory "$LAB_MEM_MB" --vcpus "$LAB_CPUS" --import $boot \
    --disk "vol=$LAB_POOL/$name.qcow2,bus=virtio" \
    --disk "vol=$LAB_POOL/$name-seed.iso,device=cdrom" \
    --os-variant "ubuntu$LAB_UBUNTU" --network "network=$LAB_NET,model=virtio" \
    --graphics none --noautoconsole >/dev/null
}

delete_vm() {
  name=$1
  is_lab_vm "$name" || die "negado: $name no pertenece al lab"
  if domain_exists "$name"; then
    info "Borrando $name"
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
    info "$name: rke2-$kind ya activo"
    return 0
  fi
  info "$name: instalando RKE2 ($kind, ${LAB_RKE2_VERSION:-canal $LAB_RKE2_CHANNEL})"
  {
    echo "token: $token"
    [ -z "$server_ip" ] || echo "server: https://$server_ip:9345"
    [ "$kind" = agent ] || echo "tls-san: [\"$(vm_ip "$name")\"]"
  } | ssh_vm "$name" "sudo mkdir -p /etc/rancher/rke2 && sudo tee /etc/rancher/rke2/config.yaml >/dev/null"
  if [ -n "$LAB_RKE2_VERSION" ]; then install_env="INSTALL_RKE2_VERSION=$LAB_RKE2_VERSION"; else install_env="INSTALL_RKE2_CHANNEL=$LAB_RKE2_CHANNEL"; fi
  ssh_vm "$name" "curl -sfL https://get.rke2.io | sudo INSTALL_RKE2_TYPE=$kind $install_env sh - >/dev/null && sudo systemctl enable --now rke2-$kind"
}

# Comprueba que la release de RKE2 tiene artefactos publicados antes de instalar.
check_rke2_release() {
  [ -n "$LAB_RKE2_VERSION" ] || return 0
  v=$(echo "$LAB_RKE2_VERSION" | sed 's/+/%2B/')
  curl -fsSL -o /dev/null "https://github.com/rancher/rke2/releases/download/$v/sha256sum-amd64.txt" \
    || die "la release de RKE2 $LAB_RKE2_VERSION no tiene artefactos publicados; usar otra con LAB_RKE2_VERSION"
}

kc() { KUBECONFIG="$KUBECONFIG_FILE" "$KUBECTL" "$@"; }

wait_node_ready() {
  i=0
  until kc get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -qx True; do
    i=$((i + 1))
    [ $i -lt 240 ] || die "$1 no llega a Ready en 20 min"
    sleep 5
  done
  info "$1 Ready"
}

install_suc() {
  for f in crd.yaml system-upgrade-controller.yaml; do
    [ -f "$LAB_DIR/$f" ] || curl -fsSL -o "$LAB_DIR/$f" "$SUC_URL/$f"
  done
  echo "$SUC_CRD_SHA  $LAB_DIR/crd.yaml" | sha256sum -c --quiet - || die "sha256 incorrecto de crd.yaml"
  echo "$SUC_YAML_SHA  $LAB_DIR/system-upgrade-controller.yaml" | sha256sum -c --quiet - || die "sha256 incorrecto del SUC"
  kc apply -f "$LAB_DIR/crd.yaml" >/dev/null
  kc apply -f "$LAB_DIR/system-upgrade-controller.yaml" >/dev/null
  kc -n "$SUC_NS" rollout status deploy/system-upgrade-controller --timeout=300s >/dev/null
  mkdir -p "$LAB_DIR/schema"
  kc get crd plans.upgrade.cattle.io -o json > "$LAB_DIR/schema/crd-plans.json"
  info "system-upgrade-controller v0.16.3 listo en $SUC_NS"
}

# ------------------------------------------------------------------ comandos
cmd_plan() {
  echo "Lab '$LAB_PREFIX' en $LIBVIRT_DEFAULT_URI (pool $LAB_POOL, red $LAB_NET):"
  for n in $(cp_names); do echo "  $n  control plane + etcd  ${LAB_CPUS} CPU ${LAB_MEM_MB} MB ${LAB_DISK_GB} GB"; done
  for n in $(worker_names); do echo "  $n  worker                ${LAB_CPUS} CPU ${LAB_MEM_MB} MB ${LAB_DISK_GB} GB"; done
  echo "  Ubuntu $LAB_UBUNTU ($LAB_CODENAME); imagen: $IMAGE_NAME (volumen $BASE_VOL), arranque $( [ "$LAB_UEFI" = true ] && echo UEFI || echo BIOS)"
  echo "  RKE2: ${LAB_RKE2_VERSION:-canal $LAB_RKE2_CHANNEL}; SUC v0.16.3 en $SUC_NS"
  echo "  total: $(( (LAB_CP + LAB_WORKERS) * LAB_MEM_MB )) MB de RAM, $(( (LAB_CP + LAB_WORKERS) * LAB_CPUS )) vCPU"
  echo "  estado local: $LAB_DIR"
}

cmd_up() {
  for c in virsh virt-install genisoimage curl ssh ssh-keygen sha256sum "$KUBECTL"; do
    command -v "$c" >/dev/null 2>&1 || die "falta $c (las herramientas de tools/ se instalan con 'make tools')"
  done
  virsh pool-info "$LAB_POOL" >/dev/null 2>&1 || die "no existe el pool de libvirt '$LAB_POOL'"
  virsh net-info "$LAB_NET" >/dev/null 2>&1 || die "no existe la red de libvirt '$LAB_NET'"
  mkdir -p "$LAB_DIR"
  [ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N "" -C "$LAB_PREFIX" -f "$KEY"
  check_rke2_release
  [ -f "$LAB_DIR/token" ] || head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$LAB_DIR/token"
  cmd_plan
  ensure_base_image
  for n in $(all_names); do create_vm "$n"; done
  for n in $(all_names); do
    info "$n: IP $(wait_ip "$n"), esperando cloud-init"
    wait_ssh "$n"
  done

  cp1=$(first_cp)
  cp1_ip=$(vm_ip "$cp1")
  install_rke2 "$cp1" server
  i=0
  until ssh_vm "$cp1" "sudo test -f /etc/rancher/rke2/rke2.yaml"; do
    i=$((i + 1)); [ $i -lt 60 ] || die "RKE2 no arranca en $cp1"; sleep 5
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

  # Grupos de os-upgrade: workers en el 1, control plane en el 2.
  for n in $(worker_names); do kc label node "$n" os-upgrade-group=1 --overwrite >/dev/null; done
  for n in $(cp_names); do kc label node "$n" os-upgrade-group=2 --overwrite >/dev/null; done
  install_suc
  ssh_vm "$cp1" "sudo /usr/local/bin/rke2 etcd-snapshot save --name lab >/dev/null 2>&1 || sudo rke2 etcd-snapshot save --name lab >/dev/null"
  info "Snapshot de etcd hecho"
  echo
  kc get nodes -o wide
  echo
  echo "Lab listo. Para usarlo: eval \"\$(lab/lab.sh env)\""
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
      printf '%-20s %s\n' "$n" "no existe"
    fi
  done
  if [ -f "$KUBECONFIG_FILE" ]; then echo; kc get nodes -o wide -L os-upgrade,os-upgrade-group 2>&1 || true; fi
}

cmd_reports() {
  for n in $(all_names); do
    echo "===== $n"
    ssh_vm "$n" "cat /var/log/os-upgrade-report.txt 2>/dev/null || echo '(sin informe)'"
  done
}

cmd_e2e() {
  [ -f "$KUBECONFIG_FILE" ] || die "no hay lab: ejecutar antes 'lab/lab.sh up'"
  export KUBECONFIG="$KUBECONFIG_FILE" NS="$SUC_NS"
  start=$(date +%s)
  out="$LAB_DIR/manifests.yaml"
  info "Render y validación de $LAB_OVERLAY"
  "$TOOLS_BIN/kustomize" build --load-restrictor LoadRestrictionsNone "$LAB_OVERLAY" > "$out"
  sh "$REPO_DIR/scripts/validate-manifests.sh" "$out" "$LAB_DIR/schema"
  "$KUBECTL" apply -f "$out" >/dev/null
  kernel=$("$TOOLS_BIN/yq" 'select(.kind == "ConfigMap") | .data.KERNEL_VERSION' "$out")
  target=$("$TOOLS_BIN/yq" 'select(.kind == "ConfigMap") | .data.TARGET_VERSION' "$out")

  sh "$REPO_DIR/scripts/preflight.sh"
  for g in 1 2; do
    sh "$REPO_DIR/scripts/rollout.sh" predownload --group "$g" --wait --yes
  done
  for g in 1 2; do
    sh "$REPO_DIR/scripts/rollout.sh" upgrade --group "$g" --yes
  done

  info "Comprobación final"
  bad=$("$KUBECTL" get nodes -o json | "$TOOLS_BIN/yq" -p json ".items[] | select((.status.nodeInfo.osImage | test(\"Ubuntu $target\") | not) or .status.nodeInfo.kernelVersion != \"$kernel\") | .metadata.name")
  sh "$REPO_DIR/scripts/check-cluster.sh" >/dev/null || die "check-cluster.sh reporta problemas"
  [ -z "$bad" ] || die "nodos sin actualizar: $bad"
  sh "$REPO_DIR/scripts/rollout.sh" status
  info "E2E OK en $(( ($(date +%s) - start) / 60 )) min: todos los nodos en Ubuntu $target con $kernel"
}

cmd_down() {
  for n in $(all_names); do delete_vm "$n"; done
  rm -rf "$LAB_DIR"/seed-* "$KUBECONFIG_FILE"
  info "VMs del lab borradas (se conservan la imagen base y $LAB_DIR)"
}

cmd_destroy() {
  cmd_down
  if vol_exists "$BASE_VOL"; then virsh vol-delete --pool "$LAB_POOL" "$BASE_VOL" >/dev/null; fi
  rm -rf "$LAB_DIR"
  info "Lab eliminado por completo"
}

case "${1:-}" in
  plan) cmd_plan ;;
  up) cmd_up ;;
  e2e) cmd_e2e ;;
  status) cmd_status ;;
  env) cmd_env ;;
  ssh) [ $# -ge 2 ] || usage; is_lab_vm "$2" || die "$2 no es una VM del lab"; n=$2; shift 2; ssh_vm "$n" "$@" ;;
  reports) cmd_reports ;;
  down) cmd_down ;;
  destroy) cmd_destroy ;;
  *) usage ;;
esac
