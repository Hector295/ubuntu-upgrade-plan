#!/usr/bin/env bats
# upgrade subcommand (+ host-phase, which the systemd-run stub runs synchronously).

load helpers

setup() {
  setup_node
  fake_predownload
}

state() { echo "$ROOT/var/lib/os-upgrade/$1"; }
grub_default() { sed -n 's/^set default="\(.*\)"$/\1/p' "$ROOT/boot/grub/grub.cfg"; }
expected_default() { echo "gnulinux-advanced-0123-abcd>gnulinux-$TARGET_KERNEL-advanced-0123-abcd"; }

@test "upgrade: 22.04 -> 24.04 with a single reboot and the pinned kernel" {
  run sh "$SCRIPT" upgrade
  # The pod keeps waiting for the reboot; with the stubs "sleep" returns and the script exits 1.
  [[ "$output" == *"Release upgrade finished; waiting for the reboot"* ]]
  [ "$(reboot_count)" -eq 1 ]
  grep -q 'VERSION_ID="24.04"' "$ROOT/etc/os-release"
  # Pinned kernel installed and held.
  for p in linux-image linux-modules linux-modules-extra; do
    installed "$p-$TARGET_KERNEL"
    grep -qx "$p-$TARGET_KERNEL" "$STUB_STATE/held"
  done
  # Metapackages removed and blocked.
  not_installed linux-generic
  not_installed linux-image-generic
  grep -q "^Package: linux-generic\* linux-image-generic\*" "$ROOT/etc/apt/preferences.d/99-os-upgrade-kernel"
  grep -qx "Pin-Priority: -1" "$ROOT/etc/apt/preferences.d/99-os-upgrade-kernel"
  grep -qx linux-firmware "$STUB_STATE/manual"
  # GRUB points to the pinned kernel even though the running kernel is still installed.
  installed "linux-image-$OLD_KERNEL"
  [ "$(grub_default)" = "$(expected_default)" ]
  # The release upgrade used the predownloaded cache.
  [ -f "$ROOT/var/cache/apt/archives/linux-image-${TARGET_KERNEL}_1.0_amd64.deb" ]
  [ -f "$(state release-upgrade.done)" ]
  [ ! -f "$(state failed)" ]
  # unattended-upgrades timers disabled during the process.
  called "systemctl disable --now apt-daily-upgrade.timer"
  grep -qx "Prompt=lts" "$ROOT/etc/update-manager/release-upgrades"
}

@test "upgrade: the metapackages are removed BEFORE the full-upgrade" {
  run sh "$SCRIPT" upgrade
  remove_line=$(grep -n "remove --purge linux-generic" "$STUB_STATE/calls.log" | head -n1 | cut -d: -f1)
  upgrade_line=$(grep -n "apt-get .* full-upgrade$" "$STUB_STATE/calls.log" | grep -v -- ' -s ' | head -n1 | cut -d: -f1)
  [ -n "$remove_line" ] && [ -n "$upgrade_line" ]
  [ "$remove_line" -lt "$upgrade_line" ]
}

@test "upgrade: after the reboot it finalizes and returns 0" {
  run sh "$SCRIPT" upgrade
  simulate_reboot
  [ "$(cat "$STUB_STATE/uname-r")" = "$TARGET_KERNEL" ]
  run sh "$SCRIPT" upgrade
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK: Ubuntu 24.04, kernel $TARGET_KERNEL"* ]]
  # The old kernel is purged once it is no longer running.
  not_installed "linux-image-$OLD_KERNEL"
  not_installed "linux-modules-$OLD_KERNEL"
  # Temporary changes are restored and what guarantees the kernel is kept.
  [ ! -f "$ROOT/etc/apt/apt.conf.d/99-os-upgrade" ]
  [ ! -f "$ROOT/etc/needrestart/conf.d/99-os-upgrade.conf" ]
  [ ! -d "$(state archives)" ]
  [ -f "$ROOT/etc/apt/preferences.d/99-os-upgrade-kernel" ]
  [ -f "$ROOT/etc/default/grub.d/99-os-upgrade-kernel.cfg" ]
  [ "$(grub_default)" = "$(expected_default)" ]
  called "systemctl enable --now apt-daily-upgrade.timer"
  [ -f "$(state done)" ]
  [ "$(reboot_count)" -eq 1 ]
}

@test "upgrade: repeated runs on a finished node are idempotent" {
  run sh "$SCRIPT" upgrade
  simulate_reboot
  run sh "$SCRIPT" upgrade
  [ "$status" -eq 0 ]
  run sh "$SCRIPT" upgrade
  [ "$status" -eq 0 ]
  [ "$(reboot_count)" -eq 1 ]
}

@test "upgrade: timers that were disabled are not re-enabled" {
  echo disabled > "$STUB_STATE/enabled.apt-daily.timer"
  run sh "$SCRIPT" upgrade
  simulate_reboot
  run sh "$SCRIPT" upgrade
  [ "$status" -eq 0 ]
  not_called "systemctl enable --now apt-daily.timer"
  called "systemctl enable --now apt-daily-upgrade.timer"
}

@test "upgrade: running 22.04 kernel with a HIGHER version than the target" {
  # e.g. jammy HWE 6.8.0-147: without GRUB_DEFAULT that one would boot.
  newer=6.8.0-147-generic
  echo "linux-image-$newer" >> "$STUB_STATE/installed"
  add_boot_kernel "$newer"
  set_running "$newer"
  run sh "$SCRIPT" upgrade
  [ "$(grub_default)" = "$(expected_default)" ]
  simulate_reboot
  [ "$(cat "$STUB_STATE/uname-r")" = "$TARGET_KERNEL" ]
  run sh "$SCRIPT" upgrade
  [ "$status" -eq 0 ]
  not_installed "linux-image-$newer"
}

@test "upgrade: non-running kernels other than the target are purged before the reboot" {
  other=5.15.0-90-generic
  printf '%s\n' "linux-image-$other" "linux-modules-$other" >> "$STUB_STATE/installed"
  add_boot_kernel "$other"
  run sh "$SCRIPT" upgrade
  not_installed "linux-image-$other"
  not_installed "linux-modules-$other"
  installed "linux-image-$OLD_KERNEL"
}

@test "upgrade: prior reboot if the full-upgrade leaves libc6 pending" {
  echo libc6 > "$STUB_STATE/full-upgrade-reboot-pkgs"
  run sh "$SCRIPT" upgrade
  [[ "$output" == *"do-release-upgrade requires a reboot first because of: libc6"* ]]
  [ "$(reboot_count)" -eq 1 ]
  not_called "do-release-upgrade"
  # After that reboot it continues with the release upgrade.
  rm "$STUB_STATE/full-upgrade-reboot-pkgs"
  simulate_reboot "$OLD_KERNEL"
  run sh "$SCRIPT" upgrade
  called "do-release-upgrade"
  [ "$(reboot_count)" -eq 2 ]
}

@test "upgrade: a failed do-release-upgrade marks the node and does not reboot" {
  touch "$STUB_STATE/fail.do-release-upgrade"
  run sh "$SCRIPT" upgrade
  [ "$status" -ne 0 ]
  [ -f "$(state failed)" ]
  grep -q "do-release-upgrade ended with an error" "$(state failed)"
  [ "$(reboot_count)" -eq 0 ]
  # The next Job attempt does nothing.
  run sh "$SCRIPT" upgrade
  [ "$status" -eq 1 ]
  [[ "$output" == *"marked as failed"* ]]
  [ "$(grep -c do-release-upgrade "$STUB_STATE/calls.log")" -eq 1 ]
}

@test "upgrade: after a failed do-release-upgrade, the retry needs human confirmation" {
  touch "$STUB_STATE/fail.do-release-upgrade"
  run sh "$SCRIPT" upgrade
  rm "$STUB_STATE/fail.do-release-upgrade"
  run sh "$SCRIPT" reset-failed
  # Without removing the "started" mark it is not relaunched.
  run sh "$SCRIPT" upgrade
  [[ "$output" == *"the release upgrade started and did not finish"* ]]
  # After confirming by hand that 22.04 is healthy (runbook), it is relaunched.
  run sh "$SCRIPT" reset-failed
  rm "$(state release-upgrade.started)"
  run sh "$SCRIPT" upgrade
  [ "$(grep -c do-release-upgrade "$STUB_STATE/calls.log")" -eq 2 ]
  [ "$(reboot_count)" -eq 1 ]
}

@test "upgrade: without a GRUB entry for the kernel it does not reboot" {
  touch "$STUB_STATE/grub-no-entries"
  run sh "$SCRIPT" upgrade
  [ -f "$(state failed)" ]
  grep -q "no GRUB entry for $TARGET_KERNEL" "$(state failed)"
  [ "$(reboot_count)" -eq 0 ]
}

@test "upgrade: after fixing GRUB, reset-failed + retry finishes the kernel and reboots" {
  touch "$STUB_STATE/grub-no-entries"
  run sh "$SCRIPT" upgrade
  [ -f "$(state failed)" ]
  grep -q 'VERSION_ID="24.04"' "$ROOT/etc/os-release"
  rm "$STUB_STATE/grub-no-entries"
  run sh "$SCRIPT" reset-failed
  run sh "$SCRIPT" prepare
  [ "$status" -eq 0 ]
  run sh "$SCRIPT" upgrade
  [[ "$output" == *"Rebooting (1/3): boot kernel $TARGET_KERNEL"* ]]
  [ "$(grub_default)" = "$(expected_default)" ]
  [ "$(grep -c do-release-upgrade "$STUB_STATE/calls.log")" -eq 1 ]
  simulate_reboot
  run sh "$SCRIPT" upgrade
  [ "$status" -eq 0 ]
}

@test "upgrade: an interrupted release upgrade needs intervention" {
  set_os 24.04
  date > "$(state release-upgrade.started)"
  run sh "$SCRIPT" upgrade
  [ "$status" -eq 1 ]
  [[ "$output" == *"the release upgrade started and did not finish"* ]]
  [ -f "$(state failed)" ]
  not_called "apt-get .* install"
}

@test "upgrade: a running unit is waited for instead of relaunched" {
  touch "$STUB_STATE/active.os-upgrade-release"
  # The unit is still active: the sleep stub returns at once; it deactivates on the first sleep.
  cat > "$BATS_TEST_TMPDIR/sleep" <<'EOF'
#!/bin/sh
rm -f "$STUB_STATE/active.os-upgrade-release"
EOF
  chmod +x "$BATS_TEST_TMPDIR/sleep"
  date > "$(state release-upgrade.started)"
  date > "$(state release-upgrade.done)"
  PATH="$BATS_TEST_TMPDIR:$PATH" run sh "$SCRIPT" upgrade
  [[ "$output" == *"Release upgrade in progress"* ]]
  [[ "$output" == *"waiting for the reboot"* ]]
  not_called "systemd-run"
}

@test "upgrade: GRUB booted another kernel -> reinstall, fix and reboot" {
  run sh "$SCRIPT" upgrade
  simulate_reboot "$OLD_KERNEL"
  run sh "$SCRIPT" upgrade
  [[ "$output" == *"Rebooting (2/3): boot kernel $TARGET_KERNEL"* ]]
  [ "$(grub_default)" = "$(expected_default)" ]
}

@test "upgrade: the reboot limit marks the node" {
  echo 3 > "$(state reboots)"
  set_os 24.04
  run sh "$SCRIPT" upgrade
  [ "$status" -eq 1 ]
  [ -f "$(state failed)" ]
  grep -q "too many reboots" "$(state failed)"
  [ "$(reboot_count)" -eq 0 ]
}

@test "upgrade: a node already on 24.04 only changes the kernel, no release upgrade" {
  set_os 24.04
  run sh "$SCRIPT" upgrade
  not_called "do-release-upgrade"
  installed "linux-image-$TARGET_KERNEL"
  [ "$(grub_default)" = "$(expected_default)" ]
  [ "$(reboot_count)" -eq 1 ]
  simulate_reboot
  run sh "$SCRIPT" upgrade
  [ "$status" -eq 0 ]
}

@test "upgrade: a node already running the target kernel gets pinned without a reboot" {
  set_os 24.04
  set_running "$TARGET_KERNEL"
  add_boot_kernel "$TARGET_KERNEL"
  printf '%s\n' "linux-image-$TARGET_KERNEL" "linux-modules-$TARGET_KERNEL" "linux-modules-extra-$TARGET_KERNEL" >> "$STUB_STATE/installed"
  run sh "$SCRIPT" upgrade
  [ "$status" -eq 0 ]
  not_installed linux-generic
  [ -f "$ROOT/etc/apt/preferences.d/99-os-upgrade-kernel" ]
  [ "$(grub_default)" = "$(expected_default)" ]
  [ "$(reboot_count)" -eq 0 ]
}

@test "upgrade: inactive rke2 at finalize fails without marking the node" {
  run sh "$SCRIPT" upgrade
  simulate_reboot
  rm "$STUB_STATE/active.rke2-server"
  run sh "$SCRIPT" upgrade
  [ "$status" -eq 1 ]
  [[ "$output" == *"rke2 is not active"* ]]
  [ ! -f "$(state failed)" ]
}

@test "upgrade: after the reboot it waits for rke2 to finish starting (activating)" {
  run sh "$SCRIPT" upgrade
  simulate_reboot
  echo 3 > "$STUB_STATE/activating.rke2-server"
  RKE2_WAIT_SECONDS=60 RKE2_WAIT_INTERVAL=0 run sh "$SCRIPT" upgrade
  [ "$status" -eq 0 ]
  [[ "$output" == *"waiting for rke2 to become active"* ]]
  [[ "$output" == *"OK: Ubuntu 24.04"* ]]
}

@test "upgrade: if rke2 does not start within RKE2_WAIT_SECONDS, it fails without marking the node" {
  run sh "$SCRIPT" upgrade
  simulate_reboot
  rm "$STUB_STATE/active.rke2-server"
  RKE2_WAIT_SECONDS=0 RKE2_WAIT_INTERVAL=0 run sh "$SCRIPT" upgrade
  [ "$status" -eq 1 ]
  [[ "$output" == *"rke2 is not active after 0 s"* ]]
  [ ! -f "$(state failed)" ]
}

@test "upgrade: a half-configured dpkg is marked for review" {
  echo "package X half-configured" > "$STUB_STATE/dpkg-audit"
  run sh "$SCRIPT" upgrade
  [ "$status" -eq 1 ]
  grep -q "dpkg --audit" "$(state failed)"
  not_called "do-release-upgrade"
}

@test "upgrade: the proxy reaches the host unit" {
  HTTP_PROXY="http://proxy:3128" NO_PROXY="10.0.0.0/8,.local" run sh "$SCRIPT" upgrade
  grep -qx "HTTP_PROXY='http://proxy:3128'" "$(state config)"
  grep -qx "NO_PROXY='10.0.0.0/8,.local'" "$(state config)"
  # apt-get called from host-phase (after do-release-upgrade) sees the proxy.
  awk '/do-release-upgrade/ {f=1} f && /env http_proxy=http:\/\/proxy:3128/ {ok=1} END {exit !ok}' "$STUB_STATE/calls.log"
}

@test "upgrade: the saved configuration is only readable by root (proxy credentials)" {
  HTTP_PROXY="http://osu:s3cret@proxy:3128" run sh "$SCRIPT" upgrade
  [ "$(stat -c %a "$(state config)")" = 600 ]
  run grep -r s3cret "$ROOT/var/log"
  [ "$status" -ne 0 ]
}

@test "upgrade: values with quotes are saved without breaking the configuration" {
  HTTP_PROXY="http://us'er:pa ss@proxy:3128" run sh "$SCRIPT" upgrade
  # shellcheck disable=SC1090
  ( . "$(state config)"; [ "$HTTP_PROXY" = "http://us'er:pa ss@proxy:3128" ] )
}

@test "reset-failed clears the mark and the counter" {
  echo "x" > "$(state failed)"
  echo 3 > "$(state reboots)"
  run sh "$SCRIPT" reset-failed
  [ "$status" -eq 0 ]
  [ ! -f "$(state failed)" ]
  [ ! -f "$(state reboots)" ]
}

@test "status shows the node state" {
  run sh "$SCRIPT" upgrade
  run sh "$SCRIPT" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"Target kernel:   $TARGET_KERNEL"* ]]
  [[ "$output" == *"GRUB_DEFAULT="* ]]
}

@test "unknown subcommand" {
  run sh "$SCRIPT" foo
  [ "$status" -eq 2 ]
}
