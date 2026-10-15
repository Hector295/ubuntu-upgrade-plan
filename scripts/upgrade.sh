#!/bin/sh
# os-upgrade: actualización in place de Ubuntu 22.04 -> 24.04 con un kernel fijado
# (KERNEL_VERSION) en nodos RKE2. Lo ejecuta system-upgrade-controller (SUC) dentro de
# "chroot /host", así que todas las rutas son del host.
#
# Subcomandos:
#   prepare       initContainer del Plan de upgrade. Corre ANTES del drain: si algo
#                 impide el upgrade, falla sin cordonear ni drenar el nodo.
#   predownload   Plan sin drain ni reboot: descarga a disco local los paquetes de 24.04
#                 y del kernel, para que la ventana de upgrade no dependa de la red.
#   upgrade       contenedor principal. Máquina de estados idempotente: cada reboot mata
#                 el pod, el Job crea otro y el script continúa donde quedó.
#   host-phase    lo ejecuta systemd en el host (unidad transitoria) para que
#                 do-release-upgrade sobreviva al pod. No se llama a mano.
#   status        muestra el estado del nodo (diagnóstico).
#   reset-failed  borra la marca de fallo y el contador de reboots tras revisar a mano.
#
# Configuración: variables de entorno (ConfigMap del Plan). Ver docs/configuracion.md.
set -eu

# ------------------------------------------------------------------ configuración
# ROOT solo se usa en los tests (raíz falsa); en el nodo siempre está vacío.
ROOT="${ROOT:-}"

KERNEL_VERSION="${KERNEL_VERSION:-}"
SINGLE_REBOOT="${SINGLE_REBOOT:-true}"
REQUIRE_PREDOWNLOAD="${REQUIRE_PREDOWNLOAD:-true}"
APT_MIRROR="${APT_MIRROR:-}"
HTTP_PROXY="${HTTP_PROXY:-}"
HTTPS_PROXY="${HTTPS_PROXY:-}"
NO_PROXY="${NO_PROXY:-}"
MIN_FREE_ROOT_MB="${MIN_FREE_ROOT_MB:-5000}"
MIN_FREE_BOOT_MB="${MIN_FREE_BOOT_MB:-300}"
MAX_REBOOTS="${MAX_REBOOTS:-3}"
# true: do-release-upgrade --allow-third-party. Mantiene las fuentes que no son mirrors
# públicos de Ubuntu (mirror interno, repos de proveedores) si publican la versión destino;
# sin él, el upgrader las desactiva y pasa a archive.ubuntu.com.
ALLOW_THIRD_PARTY="${ALLOW_THIRD_PARTY:-true}"
POST_UPGRADE_HOOK_RETRIES="${POST_UPGRADE_HOOK_RETRIES:-3}"
POST_UPGRADE_HOOK_SLEEP="${POST_UPGRADE_HOOK_SLEEP:-20}"
# Tras el reboot, el pod del Job arranca antes de que rke2 termine (sigue "activating"
# mientras se une a etcd): se espera hasta este tope antes de dar el cierre por fallido.
RKE2_WAIT_SECONDS="${RKE2_WAIT_SECONDS:-600}"
RKE2_WAIT_INTERVAL="${RKE2_WAIT_INTERVAL:-10}"

# Transición soportada. Parametrizable para el futuro, pero solo 22.04 -> 24.04 está probada.
SOURCE_VERSION="${SOURCE_VERSION:-22.04}"
TARGET_VERSION="${TARGET_VERSION:-24.04}"
TARGET_CODENAME="${TARGET_CODENAME:-noble}"

# Claves que se guardan en disco para que host-phase (fuera del pod) use la misma configuración.
CONFIG_KEYS="KERNEL_VERSION SINGLE_REBOOT REQUIRE_PREDOWNLOAD APT_MIRROR HTTP_PROXY HTTPS_PROXY NO_PROXY MIN_FREE_ROOT_MB MIN_FREE_BOOT_MB MAX_REBOOTS ALLOW_THIRD_PARTY POST_UPGRADE_HOOK_RETRIES SOURCE_VERSION TARGET_VERSION TARGET_CODENAME"

# ------------------------------------------------------------------ rutas del host
STATE_DIR="$ROOT/var/lib/os-upgrade"
CONFIG_FILE="$STATE_DIR/config"
FAILED_FILE="$STATE_DIR/failed"
REBOOTS_FILE="$STATE_DIR/reboots"
DONE_FILE="$STATE_DIR/done"
PREDOWNLOAD_FILE="$STATE_DIR/predownload.ok"
RELEASE_STARTED_FILE="$STATE_DIR/release-upgrade.started"
RELEASE_DONE_FILE="$STATE_DIR/release-upgrade.done"
TIMERS_STATE_FILE="$STATE_DIR/timers.state"
ARCHIVES_DIR="$STATE_DIR/archives"
ALT_APT_DIR="$STATE_DIR/apt"
STARTED_AT_FILE="$STATE_DIR/started-at"
# Log de todas las fases en formato clave=valor (persiste entre reboots) e informe final.
LOG_FILE="$ROOT/var/log/os-upgrade.log"
REPORT_FILE="$ROOT/var/log/os-upgrade-report.txt"

HOST_SCRIPT_PATH="/usr/local/sbin/os-upgrade.sh"     # ruta vista por systemd del host
HOST_SCRIPT="$ROOT$HOST_SCRIPT_PATH"
UNIT="os-upgrade-release"

OS_RELEASE="$ROOT/etc/os-release"
APT_CACHE_DIR="$ROOT/var/cache/apt/archives"
APT_CONF_FILE="$ROOT/etc/apt/apt.conf.d/99-os-upgrade"
PIN_FILE="$ROOT/etc/apt/preferences.d/99-os-upgrade-kernel"
NEEDRESTART_FILE="$ROOT/etc/needrestart/conf.d/99-os-upgrade.conf"
RELEASE_UPGRADES_FILE="$ROOT/etc/update-manager/release-upgrades"
GRUB_DEFAULT_FILE="$ROOT/etc/default/grub.d/99-os-upgrade-kernel.cfg"
GRUB_CFG="$ROOT/boot/grub/grub.cfg"
REBOOT_REQUIRED_PKGS="$ROOT/run/reboot-required.pkgs"

# Metapaquetes de kernel: arrastran siempre el kernel más nuevo, así que se quitan y se
# bloquean con Pin-Priority -1 para que KERNEL_VERSION sea el único kernel.
KERNEL_META_GLOBS="linux-generic* linux-image-generic* linux-headers-generic* linux-signed-generic* linux-signed-image-generic* linux-virtual* linux-image-virtual* linux-headers-virtual*"
# Paquetes que dependen de los metapaquetes y no deben quedar huérfanos (autoremove).
KEEP_MANUAL_PKGS="linux-firmware intel-microcode amd64-microcode"
# Timers que lanzan unattended-upgrades; se desactivan durante el proceso y se restauran.
APT_TIMERS="apt-daily.timer apt-daily-upgrade.timer"

SELF="$0"
PHASE="${1:-}"
# Hook opcional del overlay: viaja en el mismo Secret que este script.
POST_UPGRADE_HOOK_FILE="${POST_UPGRADE_HOOK_FILE:-$(dirname "$SELF")/post-upgrade-hook.sh}"

export DEBIAN_FRONTEND=noninteractive
export RELEASE_UPGRADER_NO_SCREEN=1

# ------------------------------------------------------------------ utilidades
# Salida legible en el pod; en el archivo del host, una línea clave=valor por evento:
#   ts=... node=... phase=... level=... msg="..."
log() {
  level=$1
  shift
  ts=$(date -Is)
  echo "$ts $(hostname) ${PHASE:-?} $level $*"
  msg=$(printf '%s' "$*" | sed 's/\\/\\\\/g; s/"/\\"/g')
  { mkdir -p "$(dirname "$LOG_FILE")" \
      && printf 'ts=%s node=%s phase=%s level=%s msg="%s"\n' "$ts" "$(hostname)" "${PHASE:-?}" "$level" "$msg" >> "$LOG_FILE"
  } 2>/dev/null || true
}
info() { log INFO "$@"; }
warn() { log WARN "$@"; }
# Marca de paso: "PASO 3/7: ..." para seguir el avance en los logs del pod.
step() { log INFO "PASO $1: $2"; }

# Error que se puede reintentar: el Job vuelve a intentarlo, no deja marca.
die() {
  log ERROR "$@"
  exit 1
}

# Error que requiere intervención humana: deja la marca y todos los reintentos paran aquí.
fail_hard() {
  log ERROR "$@"
  mkdir -p "$STATE_DIR"
  printf '%s %s: %s\n' "$(date -Is)" "$PHASE" "$*" > "$FAILED_FILE"
  log ERROR "Nodo marcado como fallido ($FAILED_FILE). Revisar y luego: sh $HOST_SCRIPT_PATH reset-failed"
  exit 1
}

apt_get() {
  apt-get -y -o DPkg::Lock::Timeout=600 \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

is_true() { [ "$1" = "true" ]; }

# shellcheck disable=SC1090
os_version() { ( . "$OS_RELEASE"; echo "$VERSION_ID" ); }

running_kernel() { uname -r; }

free_mb() { df -Pm "$1" | awk 'NR==2 {print $4}'; }

# Instalado, esté o no retenido: un paquete con apt-mark hold tiene ${Status}
# "hold ok installed" (no "install ok installed"); ${db:Status-Status} es "installed" en ambos.
pkg_installed() {
  [ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null)" = "installed" ]
}

# Paquetes instalados que coinciden con los patrones dados. En ${db:Status-Abbrev} la segunda
# letra es el estado ("i" = instalado); la primera es la selección ("i" normal, "h" hold).
installed_matching() {
  dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' "$@" 2>/dev/null \
    | awk 'substr($1, 2, 1) == "i" {print $2}' || true
}

kernel_packages() {
  echo "linux-image-$KERNEL_VERSION linux-modules-$KERNEL_VERSION linux-modules-extra-$KERNEL_VERSION"
}

kernel_installed() {
  for p in $(kernel_packages); do
    pkg_installed "$p" || return 1
  done
}

unit_active() { systemctl is-active --quiet "$UNIT"; }

shell_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

export_proxy_env() {
  if [ -n "$HTTP_PROXY" ]; then export HTTP_PROXY http_proxy="$HTTP_PROXY"; fi
  if [ -n "$HTTPS_PROXY" ]; then export HTTPS_PROXY https_proxy="$HTTPS_PROXY"; fi
  if [ -n "$NO_PROXY" ]; then export NO_PROXY no_proxy="$NO_PROXY"; fi
}

# ------------------------------------------------------------------ configuración
validate_config() {
  [ -n "$KERNEL_VERSION" ] || die "KERNEL_VERSION no está definido (p. ej. 6.8.0-139-generic)"
  echo "$KERNEL_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-generic$' \
    || die "KERNEL_VERSION inválido: '$KERNEL_VERSION' (formato esperado: 6.8.0-139-generic)"
  for v in SINGLE_REBOOT REQUIRE_PREDOWNLOAD ALLOW_THIRD_PARTY; do
    eval "val=\$$v"
    # shellcheck disable=SC2154 # val se asigna con eval
    case "$val" in true|false) ;; *) die "$v debe ser true o false (valor: '$val')" ;; esac
  done
  for v in MIN_FREE_ROOT_MB MIN_FREE_BOOT_MB MAX_REBOOTS POST_UPGRADE_HOOK_RETRIES; do
    eval "val=\$$v"
    case "$val" in ''|*[!0-9]*) die "$v debe ser un número entero (valor: '$val')" ;; esac
  done
}

write_config() {
  mkdir -p "$STATE_DIR"
  tmp="$CONFIG_FILE.tmp"
  : > "$tmp"
  for k in $CONFIG_KEYS; do
    eval "val=\$$k"
    printf '%s=%s\n' "$k" "$(shell_quote "$val")" >> "$tmp"
  done
  mv "$tmp" "$CONFIG_FILE"
}

load_config() {
  [ -f "$CONFIG_FILE" ] || fail_hard "no existe $CONFIG_FILE"
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
}

# ------------------------------------------------------------------ estado
release_upgrade_interrupted() {
  [ -f "$RELEASE_STARTED_FILE" ] && [ ! -f "$RELEASE_DONE_FILE" ] && ! unit_active
}

is_done() {
  [ "$(os_version)" = "$TARGET_VERSION" ] || return 1
  [ "$(running_kernel)" = "$KERNEL_VERSION" ] || return 1
  kernel_installed || return 1
  ! unit_active || return 1
  ! release_upgrade_interrupted || return 1
}

check_not_failed() {
  if [ -f "$FAILED_FILE" ]; then
    die "el nodo está marcado como fallido: $(cat "$FAILED_FILE"). Revisar y luego: sh $HOST_SCRIPT_PATH reset-failed"
  fi
}

check_space() {
  root_free=$(free_mb "$ROOT/")
  boot_free=$(free_mb "$ROOT/boot")
  [ "$root_free" -ge "$MIN_FREE_ROOT_MB" ] \
    || die "espacio libre insuficiente en /: $root_free MB (mínimo $MIN_FREE_ROOT_MB)"
  [ "$boot_free" -ge "$MIN_FREE_BOOT_MB" ] \
    || die "espacio libre insuficiente en /boot: $boot_free MB (mínimo $MIN_FREE_BOOT_MB)"
}

# do-release-upgrade se niega a arrancar si hay un reboot pendiente por estos paquetes.
filter_reboot_pkgs() { grep -Ex 'libc6|linux-base|linux-image-.*' || true; }

pending_reboot_pkgs() {
  [ -f "$REBOOT_REQUIRED_PKGS" ] || return 0
  filter_reboot_pkgs < "$REBOOT_REQUIRED_PKGS" | sort -u
}

# Paquetes que el full-upgrade de la versión origen instalaría y que obligarían a un
# reboot previo. Se simula con el pin de kernel, como se hará de verdad.
simulated_reboot_pkgs() {
  pin_tmp="$STATE_DIR/sim-preferences"
  write_pin_file "$pin_tmp"
  apt-get -s -o Dir::Etc::Preferences="$pin_tmp" full-upgrade 2>/dev/null \
    | awk '/^Inst / {print $2}' | filter_reboot_pkgs | sort -u
  rm -f "$pin_tmp"
}

predownload_matches() {
  [ -f "$PREDOWNLOAD_FILE" ] || return 1
  grep -qx "KERNEL_VERSION=$KERNEL_VERSION" "$PREDOWNLOAD_FILE" || return 1
  grep -qx "TARGET_VERSION=$TARGET_VERSION" "$PREDOWNLOAD_FILE" || return 1
  for p in $(kernel_packages); do
    ls "$ARCHIVES_DIR/${p}_"*.deb >/dev/null 2>&1 || return 1
  done
}

# ------------------------------------------------------------------ fuentes de apt
# Fuentes configuradas: "archivo<TAB>uri<TAB>suites<TAB>estado" (estado: on|off).
# Entiende sources.list/*.list (una línea por entrada) y *.sources (deb822).
list_sources() {
  for f in "$ROOT/etc/apt/sources.list" "$ROOT"/etc/apt/sources.list.d/*.list; do
    [ -f "$f" ] || continue
    awk -v f="${f#"$ROOT"}" '
      /^[[:space:]]*deb[[:space:]]/ {
        sub(/\[[^]]*\]/, ""); print f "\t" $2 "\t" $3 "\ton"; next }
      /^#[[:space:]]*deb[[:space:]].*disabled on upgrade/ {
        sub(/^#[[:space:]]*/, ""); sub(/\[[^]]*\]/, ""); print f "\t" $2 "\t" $3 "\toff" }
    ' "$f"
  done
  for f in "$ROOT"/etc/apt/sources.list.d/*.sources; do
    [ -f "$f" ] || continue
    awk -v f="${f#"$ROOT"}" '
      function flush() { if (uris != "") { n = split(uris, u, " "); for (i = 1; i <= n; i++) print f "\t" u[i] "\t" suites "\t" (enabled ? "on" : "off") } uris = ""; suites = ""; enabled = 1 }
      BEGIN { enabled = 1 }
      /^[[:space:]]*$/ { flush(); next }
      /^Enabled:/ { enabled = ($2 != "no") }
      /^URIs:/ { $1 = ""; sub(/^ /, ""); uris = $0 }
      /^Suites:/ { $1 = ""; sub(/^ /, ""); suites = $0 }
      END { flush() }
    ' "$f"
  done
}

# Mirrors públicos de Ubuntu (lo que do-release-upgrade reconoce sin --allow-third-party).
is_official_uri() {
  echo "$1" | grep -Eq '^[a-z]+://([a-z0-9-]+\.)*(archive|security|ports)\.ubuntu\.com(/|$)'
}

third_party_sources() {
  list_sources | awk -F'\t' '$4 == "on"' | while IFS="$(printf '\t')" read -r file uri suites _; do
    is_official_uri "$uri" || echo "$uri ($suites, $file)"
  done | sort -u
}

disabled_sources() {
  list_sources | awk -F'\t' '$4 == "off" {print $2 " (" $3 ", " $1 ")"}' | sort -u
}

# Informa de las fuentes que no son mirrors públicos de Ubuntu y de cómo las tratará el
# upgrade. Sin ALLOW_THIRD_PARTY, un mirror interno de Ubuntu se desactivaría: se para.
check_sources() {
  tp=$(third_party_sources)
  [ -n "$tp" ] || return 0
  if is_true "$ALLOW_THIRD_PARTY"; then
    info "fuentes no oficiales (se mantienen si publican $TARGET_CODENAME, si no se desactivan): $(echo "$tp" | tr '\n' ';')"
    return 0
  fi
  mirror=$(APT_MIRROR="" detect_mirror)
  if ! is_official_uri "$mirror"; then
    die "el mirror de Ubuntu del nodo ($mirror) no es un mirror público: con ALLOW_THIRD_PARTY=false do-release-upgrade lo desactivaría y usaría archive.ubuntu.com. Usar ALLOW_THIRD_PARTY=true"
  fi
  warn "fuentes no oficiales que el upgrade desactivará (ALLOW_THIRD_PARTY=false): $(echo "$tp" | tr '\n' ';')"
}

# Paquetes retenidos (apt-mark hold) ajenos al kernel fijado: pueden impedir el release upgrade.
held_packages() {
  apt-mark showhold 2>/dev/null | grep -vxF "$(kernel_packages | tr ' ' '\n')" | sort -u || true
}

check_held() {
  held=$(held_packages)
  [ -z "$held" ] || warn "paquetes retenidos (apt-mark hold) que pueden bloquear el release upgrade: $(echo "$held" | tr '\n' ' ')"
}

# ------------------------------------------------------------------ hook post-upgrade
check_hook_syntax() {
  [ -f "$POST_UPGRADE_HOOK_FILE" ] || return 0
  sh -n "$POST_UPGRADE_HOOK_FILE" 2>/dev/null \
    || die "el hook post-upgrade tiene errores de sintaxis: $POST_UPGRADE_HOOK_FILE"
}

# Ejecuta el hook del overlay (si existe) con reintentos. Si no pasa, el nodo queda marcado:
# el sistema está actualizado pero algo propio del entorno no funciona.
run_post_upgrade_hook() {
  [ -f "$POST_UPGRADE_HOOK_FILE" ] || { HOOK_RESULT="sin hook"; return 0; }
  attempt=1
  while :; do
    info "Hook post-upgrade (intento $attempt/$POST_UPGRADE_HOOK_RETRIES)"
    if out=$(NODE_NAME="${SYSTEM_UPGRADE_NODE_NAME:-$(hostname)}" KERNEL_VERSION="$KERNEL_VERSION" \
        TARGET_VERSION="$TARGET_VERSION" sh "$POST_UPGRADE_HOOK_FILE" 2>&1); then
      echo "$out" | while IFS= read -r l; do info "hook: $l"; done
      HOOK_RESULT="OK"
      return 0
    fi
    echo "$out" | while IFS= read -r l; do warn "hook: $l"; done
    if [ "$attempt" -ge "$POST_UPGRADE_HOOK_RETRIES" ]; then
      fail_hard "el hook post-upgrade falló $attempt veces; el sistema está en $TARGET_VERSION pero la verificación propia no pasa"
    fi
    attempt=$((attempt + 1))
    sleep "$POST_UPGRADE_HOOK_SLEEP"
  done
}

rke2_active() { systemctl is-active --quiet rke2-server || systemctl is-active --quiet rke2-agent; }

wait_rke2_active() {
  waited=0
  until rke2_active; do
    if [ "$waited" -ge "$RKE2_WAIT_SECONDS" ]; then
      die "rke2 no está activo tras $RKE2_WAIT_SECONDS s; ver journalctl -u rke2-server (o rke2-agent)"
    fi
    [ "$waited" -gt 0 ] || info "esperando a que rke2 esté activo (hasta $RKE2_WAIT_SECONDS s)"
    sleep "$RKE2_WAIT_INTERVAL"
    waited=$((waited + RKE2_WAIT_INTERVAL))
    [ "$RKE2_WAIT_INTERVAL" -gt 0 ] || waited=$((waited + 1))
  done
}

# ------------------------------------------------------------------ reboot
reboot_now() {
  n=$(cat "$REBOOTS_FILE" 2>/dev/null || echo 0)
  n=$((n + 1))
  echo "$n" > "$REBOOTS_FILE"
  [ "$n" -le "$MAX_REBOOTS" ] || fail_hard "demasiados reboots ($n > $MAX_REBOOTS); posible bucle"
  info "Reiniciando ($n/$MAX_REBOOTS): $1"
  sync
  systemctl reboot || reboot
  sleep infinity
  die "el reboot no se produjo"
}

# ------------------------------------------------------------------ preparación del host
configure_host() {
  mkdir -p "$(dirname "$APT_CONF_FILE")" "$(dirname "$NEEDRESTART_FILE")"
  # Conservar siempre los archivos de configuración existentes.
  cat > "$APT_CONF_FILE" <<'EOF'
// Gestionado por os-upgrade; se borra al terminar.
Dpkg::Options { "--force-confdef"; "--force-confold"; };
EOF
  # needrestart solo lista; que no reinicie servicios (rke2) por su cuenta.
  echo "\$nrconf{restart} = 'l';" > "$NEEDRESTART_FILE"
  if [ -f "$RELEASE_UPGRADES_FILE" ]; then
    sed -i 's/^Prompt=.*/Prompt=lts/' "$RELEASE_UPGRADES_FILE"
  fi
  # unattended-upgrades se lanza desde estos timers: se desactivan y se guarda su estado
  # original (solo la primera vez) para restaurarlo al final.
  if [ ! -f "$TIMERS_STATE_FILE" ]; then
    for t in $APT_TIMERS; do
      echo "$t $(systemctl is-enabled "$t" 2>/dev/null || true)"
    done > "$TIMERS_STATE_FILE"
  fi
  for t in $APT_TIMERS; do
    systemctl disable --now "$t" >/dev/null 2>&1 || true
  done
  systemctl stop apt-daily.service apt-daily-upgrade.service unattended-upgrades.service >/dev/null 2>&1 || true
}

restore_host() {
  rm -f "$APT_CONF_FILE" "$NEEDRESTART_FILE"
  if [ -f "$TIMERS_STATE_FILE" ]; then
    while read -r t state; do
      if [ "$state" = "enabled" ]; then
        systemctl enable --now "$t" >/dev/null 2>&1 || warn "no se pudo reactivar $t"
      fi
    done < "$TIMERS_STATE_FILE"
    rm -f "$TIMERS_STATE_FILE"
  fi
}

# Recupera un dpkg interrumpido (pod matado a mitad de un apt, corte de luz...).
recover_dpkg() {
  dpkg --configure -a || fail_hard "dpkg --configure -a falló"
  apt_get -f install || fail_hard "apt-get -f install falló"
  audit=$(dpkg --audit 2>&1 || true)
  [ -z "$audit" ] || fail_hard "dpkg --audit reporta paquetes a medio instalar: $audit"
}

write_pin_file() {
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<EOF
# Gestionado por os-upgrade: impide instalar metapaquetes de kernel para que el kernel
# fijado ($KERNEL_VERSION) siga siendo el único. Ver docs/kernel.md antes de borrarlo.
Package: $KERNEL_META_GLOBS
Pin: version *
Pin-Priority: -1
EOF
}

# Quita los metapaquetes de kernel y los bloquea. Se hace ANTES de actualizar: así ni el
# full-upgrade ni do-release-upgrade instalan (ni esperan reiniciar) un kernel no deseado.
apply_kernel_policy() {
  for p in $KEEP_MANUAL_PKGS; do
    if pkg_installed "$p"; then apt-mark manual "$p" >/dev/null; fi
  done
  write_pin_file "$PIN_FILE"
  # shellcheck disable=SC2086 # los globs se pasan a dpkg-query, no al shell
  metas=$(set -f; installed_matching $KERNEL_META_GLOBS)
  if [ -n "$metas" ]; then
    info "Quitando metapaquetes de kernel: $(echo "$metas" | tr '\n' ' ')"
    # shellcheck disable=SC2086
    apt_get remove --purge $metas || fail_hard "no se pudieron quitar los metapaquetes de kernel"
  fi
}

# Enlaza los .deb pre-descargados en la caché de apt; apt no vuelve a descargar lo que
# ya está ahí con el hash correcto.
stage_archives() {
  [ -d "$ARCHIVES_DIR" ] || return 0
  mkdir -p "$APT_CACHE_DIR"
  count=0
  for f in "$ARCHIVES_DIR"/*.deb; do
    [ -e "$f" ] || continue
    dest="$APT_CACHE_DIR/$(basename "$f")"
    [ -e "$dest" ] || ln -f "$f" "$dest" 2>/dev/null || cp -f "$f" "$dest"
    count=$((count + 1))
  done
  info "Paquetes pre-descargados disponibles en la caché de apt: $count"
}

# Purga imagen y módulos de cualquier kernel que no sea KERNEL_VERSION. Con
# keep_running=true conserva también el kernel arrancado (no se puede quitar en caliente).
purge_other_kernels() {
  keep_running=$1
  running=$(running_kernel)
  to_purge=""
  for p in $(installed_matching 'linux-image-[0-9]*' 'linux-modules-[0-9]*' 'linux-modules-extra-[0-9]*'); do
    v=${p#linux-image-}
    v=${v#linux-modules-extra-}
    v=${v#linux-modules-}
    [ "$v" = "$KERNEL_VERSION" ] && continue
    if is_true "$keep_running" && [ "$v" = "$running" ]; then continue; fi
    to_purge="$to_purge $p"
  done
  [ -n "$to_purge" ] || return 0
  info "Purgando kernels no deseados:$to_purge"
  # shellcheck disable=SC2086
  apt_get remove --purge --allow-change-held-packages $to_purge \
    || fail_hard "no se pudieron purgar los kernels:$to_purge"
}

# Fija GRUB_DEFAULT a la entrada exacta de KERNEL_VERSION. Es imprescindible cuando queda
# otro kernel con versión mayor (p. ej. el HWE de 22.04 que está arrancado ahora).
configure_grub() {
  update-grub >/dev/null 2>&1 || fail_hard "update-grub falló"
  [ -f "$GRUB_CFG" ] || fail_hard "no existe $GRUB_CFG"
  submenu=$(grep -o "'gnulinux-advanced-[^']*'" "$GRUB_CFG" | head -n1 | tr -d "'")
  entry=$(grep -o "'gnulinux-$KERNEL_VERSION-advanced-[^']*'" "$GRUB_CFG" | head -n1 | tr -d "'")
  if [ -z "$submenu" ] || [ -z "$entry" ]; then
    fail_hard "no hay entrada de GRUB para $KERNEL_VERSION en $GRUB_CFG; no se reinicia"
  fi
  mkdir -p "$(dirname "$GRUB_DEFAULT_FILE")"
  cat > "$GRUB_DEFAULT_FILE" <<EOF
# Gestionado por os-upgrade: arrancar siempre el kernel fijado. Ver docs/kernel.md.
GRUB_DEFAULT="$submenu>$entry"
EOF
  update-grub >/dev/null 2>&1 || fail_hard "update-grub falló"
  grep -qF "set default=\"$submenu>$entry\"" "$GRUB_CFG" \
    || fail_hard "grub.cfg no tomó GRUB_DEFAULT=$submenu>$entry; no se reinicia"
  info "GRUB arrancará $KERNEL_VERSION por defecto"
}

# Instala y fija KERNEL_VERSION, quita lo demás y deja GRUB apuntando a él.
ensure_kernel() {
  stage_archives
  info "Instalando kernel $KERNEL_VERSION"
  # shellcheck disable=SC2046
  apt_get install --allow-change-held-packages $(kernel_packages) \
    || fail_hard "no se pudo instalar el kernel $KERNEL_VERSION"
  # shellcheck disable=SC2046
  apt-mark hold $(kernel_packages) >/dev/null || fail_hard "apt-mark hold falló"
  apply_kernel_policy
  purge_other_kernels true
  for f in "vmlinuz-$KERNEL_VERSION" "initrd.img-$KERNEL_VERSION"; do
    [ -s "$ROOT/boot/$f" ] || fail_hard "falta /boot/$f tras instalar el kernel"
  done
  configure_grub
}

install_host_script() {
  mkdir -p "$(dirname "$HOST_SCRIPT")"
  cp "$SELF" "$HOST_SCRIPT.tmp"
  chmod 0755 "$HOST_SCRIPT.tmp"
  mv "$HOST_SCRIPT.tmp" "$HOST_SCRIPT"
}

wait_for_unit() {
  info "Release upgrade en curso (unidad $UNIT). En el nodo: journalctl -fu $UNIT"
  while unit_active; do sleep 30; done
  [ ! -f "$FAILED_FILE" ] || die "la unidad $UNIT falló: $(cat "$FAILED_FILE")"
  [ -f "$RELEASE_DONE_FILE" ] \
    || fail_hard "la unidad $UNIT terminó sin completar el release upgrade; ver journalctl -u $UNIT"
  info "Release upgrade terminado; esperando el reboot"
  sleep infinity
  die "el reboot no se produjo"
}

finalize() {
  step "7/7" "verificación y cierre: Ubuntu $TARGET_VERSION con kernel $KERNEL_VERSION"
  # Idempotente: también deja fijado el kernel en nodos que ya lo tenían arrancado.
  apply_kernel_policy
  purge_other_kernels false
  # shellcheck disable=SC2046
  apt-mark hold $(kernel_packages) >/dev/null
  configure_grub
  apt_get autoremove --purge || warn "autoremove falló (no crítico)"
  restore_host
  if [ -f "$ROOT/run/reboot-required" ]; then
    warn "hay un reboot pendiente por paquetes posteriores; no se reinicia (un solo reboot por ventana)"
  fi
  wait_rke2_active
  disabled=$(disabled_sources)
  if [ -n "$disabled" ]; then
    warn "fuentes desactivadas por el upgrade (revisar y reactivar a mano si hacen falta): $(echo "$disabled" | tr '\n' ';')"
  fi
  HOOK_RESULT=""
  run_post_upgrade_hook
  write_report "$disabled"
  rm -rf "$ARCHIVES_DIR" "$ALT_APT_DIR"
  rm -f "$REBOOTS_FILE" "$RELEASE_STARTED_FILE" "$RELEASE_DONE_FILE" "$PREDOWNLOAD_FILE" "$STARTED_AT_FILE"
  printf 'date=%s\nos=%s\nkernel=%s\n' "$(date -Is)" "$(os_version)" "$(running_kernel)" > "$DONE_FILE"
  info "OK: Ubuntu $(os_version), kernel $(running_kernel). Informe en ${REPORT_FILE#"$ROOT"}"
}

# Informe que se queda en el nodo. Solo se escribe la primera vez que el nodo termina
# (las ejecuciones posteriores del Job en un nodo ya terminado no lo pisan).
write_report() {
  [ ! -f "$DONE_FILE" ] || return 0
  started=$(cat "$STARTED_AT_FILE" 2>/dev/null || true)
  duration="?"
  if [ -n "$started" ]; then
    secs=$(( $(date +%s) - $(date -d "$started" +%s) ))
    duration="$((secs / 60)) min"
  fi
  {
    echo "os-upgrade: informe de $(hostname)"
    echo "terminado:      $(date -Is)"
    echo "inicio:         ${started:-?}"
    echo "duración:       $duration"
    echo "sistema:        Ubuntu $(os_version)"
    echo "kernel:         $(running_kernel) (fijado: $KERNEL_VERSION)"
    echo "reboots:        $(cat "$REBOOTS_FILE" 2>/dev/null || echo 0)"
    echo "hook:           ${HOOK_RESULT:-sin hook}"
    echo "fuentes desactivadas por el upgrade:"
    if [ -n "$1" ]; then echo "$1" | sed 's/^/  /'; else echo "  ninguna"; fi
    echo "paquetes retenidos (además del kernel):"
    held=$(held_packages)
    if [ -n "$held" ]; then echo "$held" | sed 's/^/  /'; else echo "  ninguno"; fi
  } > "$REPORT_FILE"
}

# ------------------------------------------------------------------ apt alternativo (predownload)
detect_mirror() {
  if [ -n "$APT_MIRROR" ]; then echo "$APT_MIRROR"; return; fi
  m=""
  if [ -f "$ROOT/etc/apt/sources.list" ]; then
    m=$(grep -E '^deb ' "$ROOT/etc/apt/sources.list" | sed 's/\[[^]]*\]//' \
      | awk '$2 !~ /security/ {print $2; exit}')
  fi
  if [ -z "$m" ] && [ -f "$ROOT/etc/apt/sources.list.d/ubuntu.sources" ]; then
    m=$(awk '/^URIs:/ && $2 !~ /security/ {print $2; exit}' "$ROOT/etc/apt/sources.list.d/ubuntu.sources")
  fi
  if [ -z "$m" ]; then
    case "$(dpkg --print-architecture)" in
      amd64|i386) m="http://archive.ubuntu.com/ubuntu" ;;
      *) m="http://ports.ubuntu.com/ubuntu-ports" ;;
    esac
  fi
  echo "$m"
}

# apt con fuentes de la versión destino y estado propio: no toca las listas ni la caché
# del sistema. Lee el estado de dpkg (solo lectura) para calcular qué falta.
alt_apt_get() {
  apt-get -y -o DPkg::Lock::Timeout=600 \
    -o Dir::Etc::SourceList="$ALT_APT_DIR/sources.list" \
    -o Dir::Etc::SourceParts="$ALT_APT_DIR/empty" \
    -o Dir::Etc::Preferences="$ALT_APT_DIR/preferences" \
    -o Dir::Etc::PreferencesParts="$ALT_APT_DIR/empty" \
    -o Dir::State::Lists="$ALT_APT_DIR/lists" \
    -o Dir::Cache="$ALT_APT_DIR/cache" \
    -o Dir::Cache::Archives="$ARCHIVES_DIR" \
    "$@"
}

setup_alt_apt() {
  mirror=$1
  arch=$(dpkg --print-architecture)
  mkdir -p "$ALT_APT_DIR/lists/partial" "$ALT_APT_DIR/cache" "$ALT_APT_DIR/empty" "$ARCHIVES_DIR/partial"
  : > "$ALT_APT_DIR/sources.list"
  for suite in "$TARGET_CODENAME" "$TARGET_CODENAME-updates" "$TARGET_CODENAME-security"; do
    echo "deb [arch=$arch] $mirror $suite main restricted universe multiverse" >> "$ALT_APT_DIR/sources.list"
  done
  write_pin_file "$ALT_APT_DIR/preferences"
}

# ------------------------------------------------------------------ subcomandos
cmd_prepare() {
  validate_config
  export_proxy_env
  mkdir -p "$STATE_DIR"
  if is_done; then
    info "Nodo ya actualizado; nada que preparar"
    return 0
  fi
  check_not_failed
  if unit_active || [ -f "$RELEASE_STARTED_FILE" ]; then
    info "Upgrade ya en curso en este nodo; continúa el contenedor upgrade"
    return 0
  fi

  version=$(os_version)
  case "$version" in
    "$SOURCE_VERSION"|"$TARGET_VERSION") ;;
    *) die "versión no soportada: $version (se espera $SOURCE_VERSION o $TARGET_VERSION)" ;;
  esac
  check_space
  check_hook_syntax
  check_sources
  check_held

  if predownload_matches; then
    info "Pre-descarga presente para $KERNEL_VERSION"
  elif is_true "$REQUIRE_PREDOWNLOAD"; then
    die "falta la pre-descarga para $KERNEL_VERSION/$TARGET_VERSION; ejecutar antes el Plan os-upgrade-predownload"
  else
    warn "sin pre-descarga: todo se descargará durante la ventana"
  fi

  apt-get -o DPkg::Lock::Timeout=600 update >/dev/null \
    || die "apt-get update falló (¿proxy o mirror inaccesibles?)"

  if [ "$version" = "$SOURCE_VERSION" ]; then
    pending=$(pending_reboot_pkgs)
    simulated=$(simulated_reboot_pkgs)
    needs=$(printf '%s\n%s\n' "$pending" "$simulated" | sed '/^$/d' | sort -u | tr '\n' ' ')
    if [ -n "$needs" ]; then
      if is_true "$SINGLE_REBOOT"; then
        die "el nodo necesitaría un reboot previo por: $needs. Parchear y reiniciar el nodo en la ventana de parches, o usar SINGLE_REBOOT=false"
      fi
      warn "habrá un reboot adicional antes del release upgrade por: $needs"
    fi
  fi
  info "Preflight OK: Ubuntu $version, kernel $(running_kernel) -> $TARGET_VERSION + $KERNEL_VERSION"
}

cmd_predownload() {
  validate_config
  export_proxy_env
  mkdir -p "$STATE_DIR"
  if is_done; then
    info "Nodo ya actualizado; nada que descargar"
    return 0
  fi
  version=$(os_version)
  case "$version" in
    "$SOURCE_VERSION"|"$TARGET_VERSION") ;;
    *) die "versión no soportada: $version" ;;
  esac
  check_space
  check_sources
  check_held

  mirror=$(detect_mirror)
  info "Pre-descargando $TARGET_VERSION ($TARGET_CODENAME) y kernel $KERNEL_VERSION desde $mirror"
  setup_alt_apt "$mirror"
  rm -f "$PREDOWNLOAD_FILE"
  alt_apt_get update || die "apt-get update de $TARGET_CODENAME falló (¿proxy o mirror inaccesibles?)"

  # Kernel: obligatorio y exacto, sin resolver dependencias.
  # shellcheck disable=SC2046
  ( cd "$ARCHIVES_DIR" && alt_apt_get download $(kernel_packages) ) \
    || die "no se pudo descargar el kernel $KERNEL_VERSION; ¿está publicado en $mirror $TARGET_CODENAME-updates?"

  # Resto del sistema: mejor esfuerzo. Lo que falte se descargará en la ventana.
  if [ "$version" = "$SOURCE_VERSION" ]; then
    if ! alt_apt_get --download-only full-upgrade >/dev/null; then
      warn "la pre-descarga completa de $TARGET_CODENAME falló; solo se dispone del kernel"
    fi
  fi
  rm -rf "$ARCHIVES_DIR/partial"/*

  count=$(find "$ARCHIVES_DIR" -maxdepth 1 -name '*.deb' | wc -l)
  size=$(du -sm "$ARCHIVES_DIR" | awk '{print $1}')
  printf 'KERNEL_VERSION=%s\nTARGET_VERSION=%s\nDATE=%s\nPACKAGES=%s\n' \
    "$KERNEL_VERSION" "$TARGET_VERSION" "$(date -Is)" "$count" > "$PREDOWNLOAD_FILE"
  info "Pre-descarga OK: $count paquetes, $size MB en $ARCHIVES_DIR"

  if [ "$version" = "$SOURCE_VERSION" ]; then
    apt-get -o DPkg::Lock::Timeout=600 update >/dev/null || warn "apt-get update de $SOURCE_VERSION falló"
    needs=$(printf '%s\n%s\n' "$(pending_reboot_pkgs)" "$(simulated_reboot_pkgs)" | sed '/^$/d' | sort -u | tr '\n' ' ')
    if [ -n "$needs" ]; then
      warn "este nodo necesitará parche + reboot previo para tener un solo reboot en la ventana: $needs"
    fi
  fi
}

cmd_upgrade() {
  validate_config
  export_proxy_env
  mkdir -p "$STATE_DIR"
  write_config
  # Inicio de un proceso nuevo (también un cambio de kernel en un nodo ya actualizado antes).
  if [ ! -f "$STARTED_AT_FILE" ] && ! is_done; then
    date -Is > "$STARTED_AT_FILE"
    rm -f "$DONE_FILE"
  fi
  info "Estado: Ubuntu $(os_version), kernel $(running_kernel); objetivo $TARGET_VERSION + $KERNEL_VERSION"

  if is_done; then
    finalize
    return 0
  fi
  check_not_failed
  if unit_active; then wait_for_unit; fi
  if release_upgrade_interrupted; then
    fail_hard "el release upgrade empezó y no terminó (¿corte o reboot a mitad?); revisar /var/log/dist-upgrade/ y journalctl -u $UNIT"
  fi

  case "$(os_version)" in
    "$SOURCE_VERSION")
      step "1/7" "preparar el host (apt, needrestart, timers de unattended-upgrades)"
      check_space
      configure_host
      recover_dpkg
      step "2/7" "quitar metapaquetes de kernel y fijar $KERNEL_VERSION"
      apply_kernel_policy
      step "3/7" "actualizar $SOURCE_VERSION al último nivel de parches"
      apt-get -o DPkg::Lock::Timeout=600 update || die "apt-get update falló"
      apt_get full-upgrade || die "apt-get full-upgrade falló"
      apt_get install update-manager-core || die "no se pudo instalar update-manager-core"
      needs=$(pending_reboot_pkgs | tr '\n' ' ')
      if [ -n "$needs" ]; then
        warn "do-release-upgrade exige reiniciar antes por: $needs"
        reboot_now "reboot previo al release upgrade"
      fi
      step "4/7" "release upgrade a $TARGET_VERSION en la unidad $UNIT del host"
      install_host_script
      systemctl reset-failed "$UNIT" >/dev/null 2>&1 || true
      systemd-run --unit="$UNIT" --description="os-upgrade: Ubuntu $SOURCE_VERSION -> $TARGET_VERSION" \
        "$HOST_SCRIPT_PATH" host-phase || die "systemd-run falló"
      wait_for_unit
      ;;
    "$TARGET_VERSION")
      # Ya en la versión destino pero sin el kernel fijado arrancado: nodo que ya estaba
      # en 24.04 (solo cambio de kernel) o GRUB arrancó otro kernel.
      step "1/7" "preparar el host"
      configure_host
      recover_dpkg
      step "5/7" "instalar y fijar el kernel $KERNEL_VERSION y GRUB"
      ensure_kernel
      step "6/7" "reboot"
      reboot_now "arrancar kernel $KERNEL_VERSION"
      ;;
    *)
      fail_hard "versión inesperada: $(os_version)"
      ;;
  esac
}

cmd_host_phase() {
  load_config
  export_proxy_env
  [ ! -f "$FAILED_FILE" ] || exit 1
  stage_archives
  date -Is > "$RELEASE_STARTED_FILE"
  third_party=""
  if is_true "$ALLOW_THIRD_PARTY"; then third_party="--allow-third-party"; fi
  info "do-release-upgrade a $TARGET_VERSION ${third_party:-(sin --allow-third-party)}"
  # shellcheck disable=SC2086 # third_party es una opción o nada
  do-release-upgrade -f DistUpgradeViewNonInteractive $third_party \
    || fail_hard "do-release-upgrade terminó con error; ver /var/log/dist-upgrade/"
  version=$(os_version)
  [ "$version" = "$TARGET_VERSION" ] || fail_hard "tras do-release-upgrade la versión es $version"
  # A partir de aquí un fallo ya no es un release upgrade interrumpido: el reintento
  # entra por la rama de la versión destino (instalar kernel + GRUB + reboot).
  date -Is > "$RELEASE_DONE_FILE"
  recover_dpkg
  step "5/7" "instalar y fijar el kernel $KERNEL_VERSION y GRUB"
  ensure_kernel
  step "6/7" "reboot"
  reboot_now "arrancar $TARGET_VERSION con kernel $KERNEL_VERSION"
}

cmd_status() {
  echo "Ubuntu:          $(os_version)"
  echo "Kernel actual:   $(running_kernel)"
  if [ -f "$CONFIG_FILE" ]; then
    echo "Kernel objetivo: $(sed -n "s/^KERNEL_VERSION='\(.*\)'$/\1/p" "$CONFIG_FILE")"
  fi
  echo "Unidad $UNIT: $(systemctl is-active "$UNIT" 2>/dev/null || true)"
  for f in "$PREDOWNLOAD_FILE" "$RELEASE_STARTED_FILE" "$RELEASE_DONE_FILE" "$DONE_FILE" "$REBOOTS_FILE" "$FAILED_FILE"; do
    [ -f "$f" ] && echo "$(basename "$f"): $(tr '\n' ' ' < "$f")"
  done
  if [ -f "$GRUB_DEFAULT_FILE" ]; then grep '^GRUB_DEFAULT=' "$GRUB_DEFAULT_FILE"; fi
  if [ -f "$REPORT_FILE" ]; then echo; cat "$REPORT_FILE"; fi
  return 0
}

cmd_reset_failed() {
  if [ -f "$FAILED_FILE" ]; then
    echo "Borrando marca de fallo: $(cat "$FAILED_FILE")"
  fi
  rm -f "$FAILED_FILE" "$REBOOTS_FILE"
  echo "Listo. El siguiente intento del Job continuará desde el estado actual."
}

main() {
  case "$PHASE" in
    prepare) cmd_prepare ;;
    predownload) cmd_predownload ;;
    upgrade) cmd_upgrade ;;
    host-phase) cmd_host_phase ;;
    status) cmd_status ;;
    reset-failed) cmd_reset_failed ;;
    *)
      echo "Uso: $0 {prepare|predownload|upgrade|host-phase|status|reset-failed}" >&2
      exit 2
      ;;
  esac
}

main
