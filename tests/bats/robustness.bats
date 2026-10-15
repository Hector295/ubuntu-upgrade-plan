#!/usr/bin/env bats
# Third-party sources, held packages, post-upgrade hook, log and report.

load helpers

setup() {
  setup_node
  fake_predownload
  export POST_UPGRADE_HOOK_FILE="$BATS_TEST_TMPDIR/post-upgrade-hook.sh"
  export POST_UPGRADE_HOOK_SLEEP=0
}

state() { echo "$ROOT/var/lib/os-upgrade/$1"; }
report() { cat "$ROOT/var/log/os-upgrade-report.txt"; }

# Full upgrade: first pass, reboot and finalize.
full_upgrade() {
  run sh "$SCRIPT" upgrade
  simulate_reboot
  run sh "$SCRIPT" upgrade
}

# ------------------------------------------------------------------ third-party sources
@test "sources: internal Ubuntu mirror without ALLOW_THIRD_PARTY -> prepare fails before the drain" {
  echo "deb http://mirror.internal.local/ubuntu jammy main" > "$ROOT/etc/apt/sources.list"
  ALLOW_THIRD_PARTY=false run sh "$SCRIPT" prepare
  [ "$status" -eq 1 ]
  [[ "$output" == *"the node Ubuntu mirror (http://mirror.internal.local/ubuntu) is not a public mirror"* ]]
  [ ! -f "$(state failed)" ]
}

@test "sources: internal mirror with ALLOW_THIRD_PARTY=true (default) passes and reports" {
  echo "deb http://mirror.internal.local/ubuntu jammy main" > "$ROOT/etc/apt/sources.list"
  run sh "$SCRIPT" prepare
  [ "$status" -eq 0 ]
  [[ "$output" == *"unofficial sources (kept if they publish noble"*"mirror.internal.local"* ]]
}

@test "sources: vendor repo with an official mirror and ALLOW_THIRD_PARTY=false only warns" {
  echo "deb http://cl.archive.ubuntu.com/ubuntu jammy main" > "$ROOT/etc/apt/sources.list"
  mkdir -p "$ROOT/etc/apt/sources.list.d"
  echo "deb [signed-by=/usr/share/keyrings/v.gpg] https://repo.vendor.example/apt jammy main" > "$ROOT/etc/apt/sources.list.d/vendor.list"
  ALLOW_THIRD_PARTY=false run sh "$SCRIPT" prepare
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN unofficial sources the upgrade will disable"*"https://repo.vendor.example/apt (jammy, /etc/apt/sources.list.d/vendor.list)"* ]]
}

@test "sources: understands the deb822 format (.sources) and Enabled: no" {
  mkdir -p "$ROOT/etc/apt/sources.list.d"
  cat > "$ROOT/etc/apt/sources.list.d/vendor.sources" <<'EOF'
Types: deb
URIs: https://repo.vendor.example/apt
Suites: jammy
Components: main

Enabled: no
Types: deb
URIs: https://other.example/apt
Suites: jammy
Components: main
EOF
  run sh "$SCRIPT" prepare
  [ "$status" -eq 0 ]
  [[ "$output" == *"repo.vendor.example/apt (jammy, /etc/apt/sources.list.d/vendor.sources)"* ]]
  [[ "$output" != *"other.example"* ]]
}

@test "sources: do-release-upgrade gets --allow-third-party by default" {
  run sh "$SCRIPT" upgrade
  called "do-release-upgrade -f DistUpgradeViewNonInteractive --allow-third-party"
}

@test "sources: with ALLOW_THIRD_PARTY=false --allow-third-party is not passed" {
  ALLOW_THIRD_PARTY=false run sh "$SCRIPT" upgrade
  called "do-release-upgrade -f DistUpgradeViewNonInteractive$"
  not_called "allow-third-party"
}

@test "sources: the ones disabled by the upgrade are warned about and listed in the report" {
  touch "$STUB_STATE/dru-disable-vendor"
  full_upgrade
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN sources disabled by the upgrade"*"http://repo.vendor.example/apt (noble, /etc/apt/sources.list.d/vendor.list)"* ]]
  report | grep -q "  http://repo.vendor.example/apt (noble"
}

@test "sources: invalid ALLOW_THIRD_PARTY is rejected" {
  ALLOW_THIRD_PARTY=si run sh "$SCRIPT" prepare
  [ "$status" -eq 1 ]
  [[ "$output" == *"ALLOW_THIRD_PARTY must be true or false"* ]]
}

# ------------------------------------------------------------------ held packages
@test "held: prepare and predownload warn about held packages other than the kernel" {
  printf '%s\n' docker-ce "linux-image-$TARGET_KERNEL" > "$STUB_STATE/held"
  run sh "$SCRIPT" prepare
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN held packages (apt-mark hold) that can block the release upgrade: docker-ce "* ]]
  [[ "$output" != *"held packages"*"linux-image-$TARGET_KERNEL"* ]]
  run sh "$SCRIPT" predownload
  [[ "$output" == *"held packages"*"docker-ce"* ]]
}

# ------------------------------------------------------------------ post-upgrade hook
@test "hook: runs at finalize with the node environment and is listed in the report" {
  cat > "$POST_UPGRADE_HOOK_FILE" <<'EOF'
echo "checking $NODE_NAME with $KERNEL_VERSION on $TARGET_VERSION"
EOF
  SYSTEM_UPGRADE_NODE_NAME=node-2 full_upgrade
  [ "$status" -eq 0 ]
  [[ "$output" == *"INFO hook: checking node-2 with $TARGET_KERNEL on 24.04"* ]]
  report | grep -qx "hook:           OK"
}

@test "hook: retries and passes if it recovers" {
  cat > "$POST_UPGRADE_HOOK_FILE" <<EOF
n=\$(cat "$BATS_TEST_TMPDIR/n" 2>/dev/null || echo 0); n=\$((n + 1)); echo \$n > "$BATS_TEST_TMPDIR/n"
[ \$n -ge 2 ] || { echo "service not ready yet"; exit 1; }
echo ready
EOF
  full_upgrade
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN hook: service not ready yet"*"Post-upgrade hook (attempt 2/3)"*"INFO hook: ready"* ]]
}

@test "hook: if it always fails, the node is marked and not finalized" {
  printf 'echo "GPU no detectada"\nexit 1\n' > "$POST_UPGRADE_HOOK_FILE"
  full_upgrade
  [ "$status" -eq 1 ]
  grep -q "the post-upgrade hook failed 3 times" "$(state failed)"
  [ ! -f "$(state done)" ]
  [ ! -f "$ROOT/var/log/os-upgrade-report.txt" ]
}

@test "hook: a syntax error is caught in prepare, before the drain" {
  printf 'if [ 1 = 1 ]; then\necho x\n' > "$POST_UPGRADE_HOOK_FILE"
  run sh "$SCRIPT" prepare
  [ "$status" -eq 1 ]
  [[ "$output" == *"the post-upgrade hook has syntax errors"* ]]
}

# ------------------------------------------------------------------ log and report
@test "log: host file in key=value format with the steps" {
  full_upgrade
  log="$ROOT/var/log/os-upgrade.log"
  grep -q '^ts=[^ ]* node=[^ ]* phase=upgrade level=INFO msg="STEP 1/7: prepare the host' "$log"
  grep -q 'phase=host-phase level=INFO msg="STEP 5/7: install and pin kernel' "$log"
  grep -q 'msg="STEP 7/7: verification and finalize' "$log"
  # Every line follows the format.
  run grep -cv '^ts=[^ ]* node=[^ ]* phase=[^ ]* level=[A-Z]* msg=".*"$' "$log"
  [ "$output" = 0 ]
}

@test "report: written once with duration, reboots and versions" {
  full_upgrade
  [ "$status" -eq 0 ]
  report | grep -qx "system:         Ubuntu 24.04"
  report | grep -qx "kernel:         $TARGET_KERNEL (pinned: $TARGET_KERNEL)"
  report | grep -qx "reboots:        1"
  report | grep -q "^duration:       [0-9]* min"
  before=$(report)
  run sh "$SCRIPT" upgrade
  [ "$status" -eq 0 ]
  [ "$(report)" = "$before" ]
  run sh "$SCRIPT" status
  [[ "$output" == *"os-upgrade: report for"* ]]
}

@test "report: a later kernel change writes a new report" {
  full_upgrade
  first=$(report)
  export KERNEL_VERSION=6.8.0-140-generic
  fake_predownload
  run sh "$SCRIPT" upgrade
  simulate_reboot
  run sh "$SCRIPT" upgrade
  [ "$status" -eq 0 ]
  report | grep -qx "kernel:         6.8.0-140-generic (pinned: 6.8.0-140-generic)"
  [ "$(report)" != "$first" ]
}

@test "log: quotes and backslashes in the message are escaped in the file" {
  KERNEL_VERSION='6.8"x\y' run sh "$SCRIPT" prepare
  [ "$status" -eq 1 ]
  grep -qF 'msg="invalid KERNEL_VERSION: '"'"'6.8\"x\\y'"'"' (expected format' "$ROOT/var/log/os-upgrade.log"
}
