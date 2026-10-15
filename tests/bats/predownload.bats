#!/usr/bin/env bats
# Subcomando predownload: descarga a disco local sin tocar el sistema.

load helpers

setup() {
  setup_node
}

archives() { echo "$ROOT/var/lib/os-upgrade/archives"; }

@test "predownload: descarga el kernel exacto y deja la marca" {
  run sh "$SCRIPT" predownload
  [ "$status" -eq 0 ]
  for p in linux-image linux-modules linux-modules-extra; do
    [ -f "$(archives)/${p}-${TARGET_KERNEL}_1.0_amd64.deb" ]
  done
  grep -qx "KERNEL_VERSION=$TARGET_KERNEL" "$ROOT/var/lib/os-upgrade/predownload.ok"
  grep -qx "TARGET_VERSION=24.04" "$ROOT/var/lib/os-upgrade/predownload.ok"
}

@test "predownload: usa fuentes de noble con el mirror del host" {
  run sh "$SCRIPT" predownload
  [ "$status" -eq 0 ]
  src="$ROOT/var/lib/os-upgrade/apt/sources.list"
  grep -qx "deb \[arch=amd64\] http://mirror.local/ubuntu noble main restricted universe multiverse" "$src"
  grep -q "noble-updates" "$src"
  grep -q "noble-security" "$src"
}

@test "predownload: APT_MIRROR tiene prioridad sobre el mirror del host" {
  APT_MIRROR=http://repo.interno/ubuntu run sh "$SCRIPT" predownload
  [ "$status" -eq 0 ]
  grep -q "http://repo.interno/ubuntu noble " "$ROOT/var/lib/os-upgrade/apt/sources.list"
}

@test "predownload: detecta el mirror en formato deb822" {
  rm "$ROOT/etc/apt/sources.list"
  mkdir -p "$ROOT/etc/apt/sources.list.d"
  printf 'Types: deb\nURIs: http://mirror822.local/ubuntu\nSuites: jammy\n' > "$ROOT/etc/apt/sources.list.d/ubuntu.sources"
  run sh "$SCRIPT" predownload
  [ "$status" -eq 0 ]
  grep -q "http://mirror822.local/ubuntu noble " "$ROOT/var/lib/os-upgrade/apt/sources.list"
}

@test "predownload: no usa las listas ni la caché del sistema" {
  run sh "$SCRIPT" predownload
  [ "$status" -eq 0 ]
  called "Dir::State::Lists=$ROOT/var/lib/os-upgrade/apt/lists"
  called "Dir::Cache::Archives=$(archives)"
  called "Dir::Etc::Preferences=$ROOT/var/lib/os-upgrade/apt/preferences"
  grep -q "Pin-Priority: -1" "$ROOT/var/lib/os-upgrade/apt/preferences"
  # No instala ni quita nada.
  not_called "apt-get .* install"
  not_called "remove --purge"
}

@test "predownload: si el kernel no existe falla y no deja marca" {
  touch "$STUB_STATE/fail.apt-download"
  run sh "$SCRIPT" predownload
  [ "$status" -eq 1 ]
  [[ "$output" == *"no se pudo descargar el kernel $TARGET_KERNEL"* ]]
  [ ! -f "$ROOT/var/lib/os-upgrade/predownload.ok" ]
}

@test "predownload: el fallo de la descarga completa es solo un aviso" {
  touch "$STUB_STATE/fail.apt-download-full"
  run sh "$SCRIPT" predownload
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN la pre-descarga completa"* ]]
  [ -f "$ROOT/var/lib/os-upgrade/predownload.ok" ]
}

@test "predownload: avisa si el nodo necesitará reboot previo" {
  printf 'Inst linux-base [1] (2)\n' > "$STUB_STATE/apt-sim"
  run sh "$SCRIPT" predownload
  [ "$status" -eq 0 ]
  [[ "$output" == *"necesitará parche + reboot previo"*"linux-base"* ]]
}

@test "predownload: exporta el proxy al entorno de apt" {
  HTTP_PROXY=http://proxy:3128 HTTPS_PROXY=http://proxy:3128 NO_PROXY=10.0.0.0/8 run sh "$SCRIPT" predownload
  [ "$status" -eq 0 ]
  called "env http_proxy=http://proxy:3128 https_proxy=http://proxy:3128 no_proxy=10.0.0.0/8"
}

@test "predownload: nodo ya terminado no hace nada" {
  set_os 24.04
  set_running "$TARGET_KERNEL"
  printf '%s\n' "linux-image-$TARGET_KERNEL" "linux-modules-$TARGET_KERNEL" "linux-modules-extra-$TARGET_KERNEL" >> "$STUB_STATE/installed"
  run sh "$SCRIPT" predownload
  [ "$status" -eq 0 ]
  [[ "$output" == *"nada que descargar"* ]]
  [ ! -d "$(archives)" ]
}
