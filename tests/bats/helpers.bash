# Common setup: a fake root ($ROOT) with an Ubuntu 22.04 node and stubs of the host
# commands (tests/stubs) first in PATH.

# Variables used by the .bats files:
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
  unset HTTP_PROXY HTTPS_PROXY NO_PROXY APT_MIRROR SINGLE_REBOOT REQUIRE_PREDOWNLOAD MAX_REBOOTS TARGET_VERSION

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
# In bats, "! cmd" does not fail the test; use this function for negations.
not_called() { ! grep -q -- "$1" "$STUB_STATE/calls.log" 2>/dev/null; }
reboot_count() { [ -f "$STUB_STATE/reboots.log" ] && wc -l < "$STUB_STATE/reboots.log" || echo 0; }

# Kernel package prefixes for the target release (like the TRANSITIONS table).
kernel_prefixes() {
  case "${TARGET_VERSION:-24.04}" in
    26.04) echo linux-image linux-modules linux-main-modules-zfs ;;
    *) echo linux-image linux-modules linux-modules-extra ;;
  esac
}

# Simulates a complete predownload (as the predownload subcommand leaves it).
fake_predownload() {
  local d="$ROOT/var/lib/os-upgrade/archives"
  mkdir -p "$d"
  for p in $(kernel_prefixes); do
    : > "$d/${p}-${KERNEL_VERSION}_1.0_amd64.deb"
  done
  printf 'KERNEL_VERSION=%s\nTARGET_VERSION=%s\n' "$KERNEL_VERSION" "${TARGET_VERSION:-24.04}" > "$ROOT/var/lib/os-upgrade/predownload.ok"
}

# Simulates the reboot: boots the GRUB default kernel (or the given one).
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
