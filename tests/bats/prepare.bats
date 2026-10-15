#!/usr/bin/env bats
# prepare subcommand: runs before the drain and must never leave the node marked as failed.

load helpers

setup() {
  setup_node
  fake_predownload
}

@test "prepare: a ready node passes" {
  run sh "$SCRIPT" prepare
  [ "$status" -eq 0 ]
  [[ "$output" == *"Preflight OK"* ]]
}

@test "prepare: missing KERNEL_VERSION fails" {
  KERNEL_VERSION= run sh "$SCRIPT" prepare
  [ "$status" -eq 1 ]
  [[ "$output" == *"KERNEL_VERSION is not set"* ]]
}

@test "prepare: KERNEL_VERSION with an invalid format fails" {
  KERNEL_VERSION="6.8.0-139" run sh "$SCRIPT" prepare
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid KERNEL_VERSION"* ]]
}

@test "prepare: KERNEL_VERSION with shell characters is rejected" {
  KERNEL_VERSION='6.8.0-139-generic;rm -rf /' run sh "$SCRIPT" prepare
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid KERNEL_VERSION"* ]]
}

@test "prepare: invalid boolean fails" {
  SINGLE_REBOOT=yes run sh "$SCRIPT" prepare
  [ "$status" -eq 1 ]
  [[ "$output" == *"SINGLE_REBOOT must be true or false"* ]]
}

@test "prepare: without predownload fails if REQUIRE_PREDOWNLOAD=true" {
  rm -rf "$ROOT/var/lib/os-upgrade/archives" "$ROOT/var/lib/os-upgrade/predownload.ok"
  run sh "$SCRIPT" prepare
  [ "$status" -eq 1 ]
  [[ "$output" == *"predownload missing"* ]]
}

@test "prepare: without predownload only warns if REQUIRE_PREDOWNLOAD=false" {
  rm -rf "$ROOT/var/lib/os-upgrade/archives" "$ROOT/var/lib/os-upgrade/predownload.ok"
  REQUIRE_PREDOWNLOAD=false run sh "$SCRIPT" prepare
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN no predownload"* ]]
}

@test "prepare: a predownload for another kernel does not count" {
  KERNEL_VERSION=6.8.0-140-generic run sh "$SCRIPT" prepare
  [ "$status" -eq 1 ]
  [[ "$output" == *"predownload missing"* ]]
}

@test "prepare: SINGLE_REBOOT blocks if the full-upgrade would bring libc6" {
  printf 'Inst libc6 [2.35-0ubuntu3.8] (2.35-0ubuntu3.9 Ubuntu:22.04/jammy-updates)\nInst curl [1] (2)\n' > "$STUB_STATE/apt-sim"
  run sh "$SCRIPT" prepare
  [ "$status" -eq 1 ]
  [[ "$output" == *"would need a prior reboot because of: libc6"* ]]
  [ ! -f "$ROOT/var/lib/os-upgrade/failed" ]
}

@test "prepare: SINGLE_REBOOT blocks if a reboot is already pending for a kernel" {
  echo "linux-image-5.15.0-101-generic" > "$ROOT/run/reboot-required.pkgs"
  run sh "$SCRIPT" prepare
  [ "$status" -eq 1 ]
  [[ "$output" == *"linux-image-5.15.0-101-generic"* ]]
}

@test "prepare: packages that do not require a prior reboot do not block" {
  printf 'Inst openssl [1] (2)\n' > "$STUB_STATE/apt-sim"
  echo "dbus" > "$ROOT/run/reboot-required.pkgs"
  run sh "$SCRIPT" prepare
  [ "$status" -eq 0 ]
}

@test "prepare: with SINGLE_REBOOT=false it only warns" {
  printf 'Inst libc6 [1] (2)\n' > "$STUB_STATE/apt-sim"
  SINGLE_REBOOT=false run sh "$SCRIPT" prepare
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN there will be an extra reboot"* ]]
}

@test "prepare: the simulation uses the kernel metapackage pin" {
  run sh "$SCRIPT" prepare
  [ "$status" -eq 0 ]
  called "apt-get -s -o Dir::Etc::Preferences=$ROOT/var/lib/os-upgrade/sim-preferences full-upgrade"
}

@test "prepare: not enough space fails without marking the node" {
  echo 100 > "$STUB_STATE/df-root"
  run sh "$SCRIPT" prepare
  [ "$status" -eq 1 ]
  [[ "$output" == *"not enough free space on /"* ]]
  [ ! -f "$ROOT/var/lib/os-upgrade/failed" ]
}

@test "prepare: failed apt-get update (proxy) fails" {
  touch "$STUB_STATE/fail.apt-update"
  run sh "$SCRIPT" prepare
  [ "$status" -eq 1 ]
  [[ "$output" == *"apt-get update failed"* ]]
}

@test "prepare: a node marked as failed does not proceed" {
  echo "reason" > "$ROOT/var/lib/os-upgrade/failed"
  run sh "$SCRIPT" prepare
  [ "$status" -eq 1 ]
  [[ "$output" == *"marked as failed"* ]]
}

@test "prepare: unsupported release fails" {
  set_os 20.04
  run sh "$SCRIPT" prepare
  [ "$status" -eq 1 ]
  [[ "$output" == *"unsupported release: 20.04"* ]]
}

@test "prepare: with the upgrade in progress it lets it through" {
  touch "$STUB_STATE/active.os-upgrade-release"
  run sh "$SCRIPT" prepare
  [ "$status" -eq 0 ]
  [[ "$output" == *"Upgrade already in progress"* ]]
}

@test "prepare: an already finished node passes without checking anything" {
  set_os 24.04
  set_running "$TARGET_KERNEL"
  printf '%s\n' "linux-image-$TARGET_KERNEL" "linux-modules-$TARGET_KERNEL" "linux-modules-extra-$TARGET_KERNEL" >> "$STUB_STATE/installed"
  echo 1 > "$STUB_STATE/df-root"
  run sh "$SCRIPT" prepare
  [ "$status" -eq 0 ]
  [[ "$output" == *"Node already upgraded"* ]]
}

@test "prepare: a node on 24.04 (kernel change only) does not simulate a prior reboot" {
  set_os 24.04
  printf 'Inst libc6 [1] (2)\n' > "$STUB_STATE/apt-sim"
  run sh "$SCRIPT" prepare
  [ "$status" -eq 0 ]
}
