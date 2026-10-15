#!/usr/bin/env bats
# predownload subcommand: downloads to local disk without touching the system.

load helpers

setup() {
  setup_node
}

archives() { echo "$ROOT/var/lib/os-upgrade/archives"; }

@test "predownload: downloads the exact kernel and leaves the mark" {
  run sh "$SCRIPT" predownload
  [ "$status" -eq 0 ]
  for p in linux-image linux-modules linux-modules-extra; do
    [ -f "$(archives)/${p}-${TARGET_KERNEL}_1.0_amd64.deb" ]
  done
  grep -qx "KERNEL_VERSION=$TARGET_KERNEL" "$ROOT/var/lib/os-upgrade/predownload.ok"
  grep -qx "TARGET_VERSION=24.04" "$ROOT/var/lib/os-upgrade/predownload.ok"
}

@test "predownload: uses noble sources with the host mirror" {
  run sh "$SCRIPT" predownload
  [ "$status" -eq 0 ]
  src="$ROOT/var/lib/os-upgrade/apt/sources.list"
  grep -qx "deb \[arch=amd64\] http://mirror.local/ubuntu noble main restricted universe multiverse" "$src"
  grep -q "noble-updates" "$src"
  grep -q "noble-security" "$src"
}

@test "predownload: APT_MIRROR takes precedence over the host mirror" {
  APT_MIRROR=http://repo.internal/ubuntu run sh "$SCRIPT" predownload
  [ "$status" -eq 0 ]
  grep -q "http://repo.internal/ubuntu noble " "$ROOT/var/lib/os-upgrade/apt/sources.list"
}

@test "predownload: detects the mirror in deb822 format" {
  rm "$ROOT/etc/apt/sources.list"
  mkdir -p "$ROOT/etc/apt/sources.list.d"
  printf 'Types: deb\nURIs: http://mirror822.local/ubuntu\nSuites: jammy\n' > "$ROOT/etc/apt/sources.list.d/ubuntu.sources"
  run sh "$SCRIPT" predownload
  [ "$status" -eq 0 ]
  grep -q "http://mirror822.local/ubuntu noble " "$ROOT/var/lib/os-upgrade/apt/sources.list"
}

@test "predownload: does not use the system lists or cache" {
  run sh "$SCRIPT" predownload
  [ "$status" -eq 0 ]
  called "Dir::State::Lists=$ROOT/var/lib/os-upgrade/apt/lists"
  called "Dir::Cache::Archives=$(archives)"
  called "Dir::Etc::Preferences=$ROOT/var/lib/os-upgrade/apt/preferences"
  grep -q "Pin-Priority: -1" "$ROOT/var/lib/os-upgrade/apt/preferences"
  # Installs and removes nothing.
  not_called "apt-get .* install"
  not_called "remove --purge"
}

@test "predownload: a missing kernel fails and leaves no mark" {
  touch "$STUB_STATE/fail.apt-download"
  run sh "$SCRIPT" predownload
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not download kernel $TARGET_KERNEL"* ]]
  [ ! -f "$ROOT/var/lib/os-upgrade/predownload.ok" ]
}

@test "predownload: a failed full download is only a warning" {
  touch "$STUB_STATE/fail.apt-download-full"
  run sh "$SCRIPT" predownload
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN the full noble predownload failed"* ]]
  [ -f "$ROOT/var/lib/os-upgrade/predownload.ok" ]
}

@test "predownload: warns if the node will need a prior reboot" {
  printf 'Inst linux-base [1] (2)\n' > "$STUB_STATE/apt-sim"
  run sh "$SCRIPT" predownload
  [ "$status" -eq 0 ]
  [[ "$output" == *"this node will need patching + a prior reboot"*"linux-base"* ]]
}

@test "predownload: exports the proxy to the apt environment" {
  HTTP_PROXY=http://proxy:3128 HTTPS_PROXY=http://proxy:3128 NO_PROXY=10.0.0.0/8 run sh "$SCRIPT" predownload
  [ "$status" -eq 0 ]
  called "env http_proxy=http://proxy:3128 https_proxy=http://proxy:3128 no_proxy=10.0.0.0/8"
}

@test "predownload: an already finished node does nothing" {
  set_os 24.04
  set_running "$TARGET_KERNEL"
  printf '%s\n' "linux-image-$TARGET_KERNEL" "linux-modules-$TARGET_KERNEL" "linux-modules-extra-$TARGET_KERNEL" >> "$STUB_STATE/installed"
  run sh "$SCRIPT" predownload
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to download"* ]]
  [ ! -d "$(archives)" ]
}
