# Entorno común: una raíz falsa ($ROOT) con un nodo Ubuntu 22.04 y stubs de los
# comandos del host (tests/stubs) delante en el PATH.

# Variables usadas desde los .bats:
# shellcheck disable=SC2034
REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
# shellcheck disable=SC2034
SCRIPT="$REPO/scripts/upgrade.sh"
TARGET_KERNEL=6.8.0-139-generic
OLD_KERNEL=5.15.0-100-generic

setup_node() {
  export ROOT="$BATS_TEST_TMPDIR/root"
  export STUB_STATE="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$ROOT"/etc/apt/preferences.d "$ROOT"/etc/apt/apt.conf.d "$ROOT"/etc/default/grub.d \
    "$ROOT"/etc/update-manager "$ROOT"/boot/grub "$ROOT"/run "$ROOT"/var/lib "$ROOT"/var/log \
    "$ROOT"/var/cache/apt/archives "$ROOT"/usr/local/sbin "$STUB_STATE"
  export PATH="$REPO/tests/stubs:$PATH"
  export KERNEL_VERSION="$TARGET_KERNEL"
  unset HTTP_PROXY HTTPS_PROXY NO_PROXY APT_MIRROR SINGLE_REBOOT REQUIRE_PREDOWNLOAD MAX_REBOOTS

  set_os 22.04
  set_running "$OLD_KERNEL"
  printf '%s\n' linux-generic linux-image-generic linux-headers-generic \
    "linux-image-$OLD_KERNEL" "linux-modules-$OLD_KERNEL" linux-firmware update-manager-core \
    > "$STUB_STATE/installed"
  add_boot_kernel "$OLD_KERNEL"
  echo "deb http://mirror.local/ubuntu jammy main restricted" > "$ROOT/etc/apt/sources.list"
  echo "Prompt=normal" > "$ROOT/etc/update-manager/release-upgrades"
  touch "$STUB_STATE/active.rke2-server"
}

set_os() { printf 'NAME="Ubuntu"\nVERSION_ID="%s"\n' "$1" > "$ROOT/etc/os-release"; }
set_running() { echo "$1" > "$STUB_STATE/uname-r"; }
add_boot_kernel() {
  echo kernel > "$ROOT/boot/vmlinuz-$1"
  echo initrd > "$ROOT/boot/initrd.img-$1"
}
installed() { grep -qx "$1" "$STUB_STATE/installed"; }
not_installed() { ! grep -qx "$1" "$STUB_STATE/installed"; }
called() { grep -q -- "$1" "$STUB_STATE/calls.log"; }
# En bats, "! cmd" no hace fallar el test; usar esta función para negaciones.
not_called() { ! grep -q -- "$1" "$STUB_STATE/calls.log" 2>/dev/null; }
reboot_count() { [ -f "$STUB_STATE/reboots.log" ] && wc -l < "$STUB_STATE/reboots.log" || echo 0; }

# Simula una pre-descarga completa (como la deja el subcomando predownload).
fake_predownload() {
  local d="$ROOT/var/lib/os-upgrade/archives"
  mkdir -p "$d"
  for p in linux-image linux-modules linux-modules-extra; do
    : > "$d/${p}-${KERNEL_VERSION}_1.0_amd64.deb"
  done
  printf 'KERNEL_VERSION=%s\nTARGET_VERSION=24.04\n' "$KERNEL_VERSION" > "$ROOT/var/lib/os-upgrade/predownload.ok"
}

# Simula el reboot: arranca el kernel por defecto de GRUB (o el indicado).
simulate_reboot() {
  rm -f "$ROOT/run/reboot-required.pkgs"
  local cfg="$ROOT/boot/grub/grub.cfg" def k
  if [ -n "${1:-}" ]; then
    set_running "$1"
    return
  fi
  def=$(sed -n 's/^set default="\(.*\)"$/\1/p' "$cfg")
  k=$(echo "$def" | sed -n 's/.*>gnulinux-\(.*\)-advanced-.*/\1/p')
  if [ -z "$k" ]; then
    k=$(for f in "$ROOT"/boot/vmlinuz-*; do echo "${f##*/vmlinuz-}"; done | sort -V | tail -n1)
  fi
  set_running "$k"
}
