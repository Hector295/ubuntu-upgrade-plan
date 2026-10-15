#!/usr/bin/env bats
# Transition 24.04 -> 26.04 (TARGET_VERSION=26.04): source node on noble with a 6.8 kernel.

load helpers

NEW_KERNEL=7.0.0-38-generic
NOBLE_KERNEL=6.8.0-139-generic

setup() {
  setup_node
  export TARGET_VERSION=26.04 KERNEL_VERSION=$NEW_KERNEL
  set_os 24.04
  set_running "$NOBLE_KERNEL"
  # 24.04 node upgraded earlier with this tool: 6.8 kernel pinned and held.
  printf '%s\n' linux-generic-hwe-24.04 "linux-image-$NOBLE_KERNEL" "linux-modules-$NOBLE_KERNEL" \
    "linux-modules-extra-$NOBLE_KERNEL" linux-firmware update-manager-core > "$STUB_STATE/installed"
  printf '%s\n' "linux-image-$NOBLE_KERNEL" "linux-modules-$NOBLE_KERNEL" "linux-modules-extra-$NOBLE_KERNEL" > "$STUB_STATE/held"
  add_boot_kernel "$NOBLE_KERNEL"
  mkdir -p "$ROOT/etc/apt/sources.list.d"
  printf 'Types: deb\nURIs: http://archive.ubuntu.com/ubuntu\nSuites: noble noble-updates\nComponents: main\n' \
    > "$ROOT/etc/apt/sources.list.d/ubuntu.sources"
  rm -f "$ROOT/etc/apt/sources.list"
}

state() { echo "$ROOT/var/lib/os-upgrade/$1"; }
grub_default() { sed -n 's/^set default="\(.*\)"$/\1/p' "$ROOT/boot/grub/grub.cfg"; }

@test "26.04: the predownload asks for image, modules and main-modules-zfs (no modules-extra)" {
  run sh "$SCRIPT" predownload
  [ "$status" -eq 0 ]
  called "download linux-image-$NEW_KERNEL linux-modules-$NEW_KERNEL linux-main-modules-zfs-$NEW_KERNEL"
  not_called "linux-modules-extra-$NEW_KERNEL"
  grep -q "http://archive.ubuntu.com/ubuntu resolute main" "$ROOT/var/lib/os-upgrade/apt/sources.list"
  grep -qx "TARGET_VERSION=26.04" "$(state predownload.ok)"
}

@test "26.04: full upgrade with one reboot and the 7.0 kernel pinned" {
  fake_predownload
  run sh "$SCRIPT" upgrade
  called "do-release-upgrade -f DistUpgradeViewNonInteractive --allow-third-party"
  grep -q 'VERSION_ID="26.04"' "$ROOT/etc/os-release"
  for p in linux-image linux-modules linux-main-modules-zfs; do
    installed "$p-$NEW_KERNEL"
    grep -qx "$p-$NEW_KERNEL" "$STUB_STATE/held"
  done
  not_installed linux-generic-hwe-24.04
  [ "$(grub_default)" = "gnulinux-advanced-0123-abcd>gnulinux-$NEW_KERNEL-advanced-0123-abcd" ]
  [ "$(reboot_count)" -eq 1 ]
  simulate_reboot
  run sh "$SCRIPT" upgrade
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK: Ubuntu 26.04, kernel $NEW_KERNEL"* ]]
  # The (held) 6.8 kernel from 24.04 is purged entirely, modules-extra included.
  not_installed "linux-image-$NOBLE_KERNEL"
  not_installed "linux-modules-extra-$NOBLE_KERNEL"
  grep -qx "system:         Ubuntu 26.04" "$ROOT/var/log/os-upgrade-report.txt"
  [ "$(reboot_count)" -eq 1 ]
}

@test "26.04: a 22.04 node is rejected in prepare (an LTS cannot be skipped)" {
  fake_predownload
  set_os 22.04
  run sh "$SCRIPT" prepare
  [ "$status" -eq 1 ]
  [[ "$output" == *"the node is on 22.04 and the target is 26.04"*"upgrade it to 24.04 first (TARGET_VERSION=24.04)"* ]]
  [ ! -f "$(state failed)" ]
}

@test "26.04: a node already on 26.04 only changes the kernel" {
  fake_predownload
  set_os 26.04
  run sh "$SCRIPT" upgrade
  not_called "do-release-upgrade"
  installed "linux-main-modules-zfs-$NEW_KERNEL"
  [ "$(reboot_count)" -eq 1 ]
}

@test "unsupported TARGET_VERSION is rejected" {
  TARGET_VERSION=25.10 run sh "$SCRIPT" prepare
  [ "$status" -eq 1 ]
  [[ "$output" == *"unsupported TARGET_VERSION: '25.10' (supported: 24.04 26.04 )"* ]]
}

@test "24.04 is still the default target" {
  unset TARGET_VERSION
  export KERNEL_VERSION=6.8.0-139-generic
  set_os 22.04
  fake_predownload
  run sh "$SCRIPT" prepare
  [ "$status" -eq 0 ]
  [[ "$output" == *"-> 24.04 + 6.8.0-139-generic"* ]]
}
