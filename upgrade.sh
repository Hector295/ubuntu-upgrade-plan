#!/bin/sh
# Upgrade Ubuntu 22.04 -> 24.04 + kernel, ejecutado por system-upgrade-controller
# dentro de "chroot /host". Es idempotente: cada reboot mata el pod, el Job crea
# otro y el script continúa desde donde quedó. Solo termina con exit 0 cuando el
# nodo está en 24.04, con el kernel objetivo arrancado y sin reboot pendiente.
set -eu

TARGET_VERSION="24.04"
KERNEL_FLAVOR="${KERNEL_FLAVOR:-hwe}"      # hwe = linux-generic-hwe-24.04 | ga = linux-generic (6.8)
UNIT="noble-release-upgrade"
STATE_DIR="/var/lib/os-upgrade"
HOST_SCRIPT="/usr/local/sbin/noble-release-upgrade.sh"
MAX_REBOOTS=5
MIN_FREE_ROOT_MB=5000
MIN_FREE_BOOT_MB=300

export DEBIAN_FRONTEND=noninteractive
APT="apt-get -y -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"

mkdir -p "$STATE_DIR"

log()  { echo "[$(date -Is)] [$(hostname)] $*"; }
fail() { log "ERROR: $*"; touch "$STATE_DIR/failed"; exit 1; }

kernel_meta() {
  case "$1" in
    hwe) echo "linux-generic-hwe-24.04" ;;
    ga)  echo "linux-generic" ;;
    *)   log "KERNEL_FLAVOR inválido: $1 (usar hwe o ga)"; exit 1 ;;
  esac
}

os_version() { ( . /etc/os-release; echo "$VERSION_ID" ); }

newest_kernel() {
  ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's|^/boot/vmlinuz-||' | sort -V | tail -n1
}

pkg_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

reboot_now() {
  n=$(cat "$STATE_DIR/reboots" 2>/dev/null || echo 0)
  n=$((n + 1))
  echo "$n" > "$STATE_DIR/reboots"
  [ "$n" -le "$MAX_REBOOTS" ] || fail "demasiados reboots ($n); posible bucle, revisar a mano"
  log "Reiniciando ($n/$MAX_REBOOTS): $1"
  sync
  systemctl reboot || reboot
  sleep infinity
}

wait_for_unit() {
  log "Release upgrade en curso (unidad $UNIT). Logs en el nodo: journalctl -fu $UNIT"
  while systemctl is-active --quiet "$UNIT"; do sleep 30; done
  [ ! -f "$STATE_DIR/failed" ] || fail "la unidad $UNIT falló; ver journalctl -u $UNIT y /var/log/dist-upgrade/"
  log "Unidad terminada; esperando el reboot"
  sleep infinity
}

is_done() {
  [ "$(os_version)" = "$TARGET_VERSION" ] || return 1
  pkg_installed "$KMETA" || return 1
  [ "$(uname -r)" = "$(newest_kernel)" ] || return 1
  [ ! -f /run/reboot-required ] || return 1
}

free_mb() { df -Pm "$1" | awk 'NR==2 {print $4}'; }

preflight() {
  [ "$(free_mb /)" -ge "$MIN_FREE_ROOT_MB" ] || fail "espacio libre insuficiente en / ($(free_mb /) MB)"
  [ "$(free_mb /boot)" -ge "$MIN_FREE_BOOT_MB" ] || fail "espacio libre insuficiente en /boot ($(free_mb /boot) MB)"
}

configure_host() {
  # Conservar siempre los archivos de configuración existentes
  cat > /etc/apt/apt.conf.d/99-os-upgrade <<'EOF'
Dpkg::Options { "--force-confdef"; "--force-confold"; };
EOF
  # needrestart en modo lista: que no reinicie servicios por su cuenta
  mkdir -p /etc/needrestart/conf.d
  echo "\$nrconf{restart} = 'l';" > /etc/needrestart/conf.d/99-no-auto-restart.conf
  # Asegurar que do-release-upgrade ofrezca la siguiente LTS
  if [ -f /etc/update-manager/release-upgrades ]; then
    sed -i 's/^Prompt=.*/Prompt=lts/' /etc/update-manager/release-upgrades
  fi
  systemctl stop unattended-upgrades 2>/dev/null || true
}

write_host_script() {
  cat > "$HOST_SCRIPT" <<'EOF'
#!/bin/sh
# Ejecutado por systemd en el host (no depende del pod).
set -u
STATE_DIR=/var/lib/os-upgrade
FLAVOR=$(cat "$STATE_DIR/kernel-flavor")
APT="apt-get -y -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"
export DEBIAN_FRONTEND=noninteractive
fail() { echo "ERROR: $*"; touch "$STATE_DIR/failed"; exit 1; }

systemctl stop unattended-upgrades 2>/dev/null || true

echo ">>> do-release-upgrade"
do-release-upgrade -f DistUpgradeViewNonInteractive || fail "do-release-upgrade terminó con error"

VER=$( . /etc/os-release; echo "$VERSION_ID" )
[ "$VER" = "24.04" ] || fail "tras do-release-upgrade la versión es $VER"

echo ">>> kernel ($FLAVOR)"
apt-get update || fail "apt-get update"
case "$FLAVOR" in
  hwe) $APT install --install-recommends linux-generic-hwe-24.04 || fail "instalación kernel HWE" ;;
  ga)  $APT install linux-generic || fail "instalación kernel GA" ;;
esac
# Metapaquetes HWE de 22.04 que puedan haber quedado
$APT purge linux-generic-hwe-22.04 linux-image-generic-hwe-22.04 linux-headers-generic-hwe-22.04 2>/dev/null || true

echo ">>> reboot"
sync
systemctl reboot
EOF
  chmod 0755 "$HOST_SCRIPT"
}

# ------------------------------------------------------------------ main
KMETA=$(kernel_meta "$KERNEL_FLAVOR")
echo "$KERNEL_FLAVOR" > "$STATE_DIR/kernel-flavor"

log "Estado: Ubuntu $(os_version), kernel $(uname -r), objetivo $TARGET_VERSION + $KMETA"

if is_done; then
  log "Upgrade completo. Verificaciones finales"
  systemctl is-active --quiet rke2-server || systemctl is-active --quiet rke2-agent \
    || fail "rke2 no está activo tras el upgrade"
  $APT autoremove --purge || log "WARN: autoremove falló (no crítico)"
  rm -f /etc/apt/apt.conf.d/99-os-upgrade "$STATE_DIR/reboots"
  log "OK: Ubuntu $(os_version), kernel $(uname -r)"
  exit 0
fi

[ ! -f "$STATE_DIR/failed" ] || fail "upgrade marcado como fallido previamente; revisar y borrar $STATE_DIR/failed"

if systemctl is-active --quiet "$UNIT"; then
  wait_for_unit
fi

case "$(os_version)" in
  22.04)
    preflight
    configure_host
    log "Actualizando 22.04 al último nivel de parches"
    apt-get -o DPkg::Lock::Timeout=600 update
    $APT full-upgrade
    $APT install update-manager-core
    if [ -f /run/reboot-required ]; then
      reboot_now "reboot pendiente antes de do-release-upgrade"
    fi
    write_host_script
    systemctl reset-failed "$UNIT" 2>/dev/null || true
    systemd-run --unit="$UNIT" --description="Ubuntu 22.04 -> 24.04" "$HOST_SCRIPT"
    wait_for_unit
    ;;
  24.04)
    # Ya en 24.04 pero falta kernel o reboot (p. ej. reintento tras un corte)
    log "Asegurando kernel $KMETA"
    apt-get -o DPkg::Lock::Timeout=600 update
    $APT install $([ "$KERNEL_FLAVOR" = hwe ] && echo --install-recommends) "$KMETA"
    reboot_now "arrancar kernel $(newest_kernel)"
    ;;
  *)
    fail "versión inesperada: $(os_version)"
    ;;
esac
