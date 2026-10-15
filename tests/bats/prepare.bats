#!/usr/bin/env bats
# Subcomando prepare: corre antes del drain y nunca debe dejar el nodo marcado como fallido.

load helpers

setup() {
  setup_node
  fake_predownload
}

@test "prepare: nodo listo pasa" {
  run sh "$SCRIPT" prepare
  [ "$status" -eq 0 ]
  [[ "$output" == *"Preflight OK"* ]]
}

@test "prepare: sin KERNEL_VERSION falla" {
  KERNEL_VERSION= run sh "$SCRIPT" prepare
  [ "$status" -eq 1 ]
  [[ "$output" == *"KERNEL_VERSION no está definido"* ]]
}

@test "prepare: KERNEL_VERSION con formato inválido falla" {
  KERNEL_VERSION="6.8.0-139" run sh "$SCRIPT" prepare
  [ "$status" -eq 1 ]
  [[ "$output" == *"KERNEL_VERSION inválido"* ]]
}

@test "prepare: KERNEL_VERSION con caracteres de shell se rechaza" {
  KERNEL_VERSION='6.8.0-139-generic;rm -rf /' run sh "$SCRIPT" prepare
  [ "$status" -eq 1 ]
  [[ "$output" == *"KERNEL_VERSION inválido"* ]]
}

@test "prepare: booleano inválido falla" {
  SINGLE_REBOOT=yes run sh "$SCRIPT" prepare
  [ "$status" -eq 1 ]
  [[ "$output" == *"SINGLE_REBOOT debe ser true o false"* ]]
}

@test "prepare: sin pre-descarga falla si REQUIRE_PREDOWNLOAD=true" {
  rm -rf "$ROOT/var/lib/os-upgrade/archives" "$ROOT/var/lib/os-upgrade/predownload.ok"
  run sh "$SCRIPT" prepare
  [ "$status" -eq 1 ]
  [[ "$output" == *"falta la pre-descarga"* ]]
}

@test "prepare: sin pre-descarga solo avisa si REQUIRE_PREDOWNLOAD=false" {
  rm -rf "$ROOT/var/lib/os-upgrade/archives" "$ROOT/var/lib/os-upgrade/predownload.ok"
  REQUIRE_PREDOWNLOAD=false run sh "$SCRIPT" prepare
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN sin pre-descarga"* ]]
}

@test "prepare: pre-descarga de otro kernel no vale" {
  KERNEL_VERSION=6.8.0-140-generic run sh "$SCRIPT" prepare
  [ "$status" -eq 1 ]
  [[ "$output" == *"falta la pre-descarga"* ]]
}

@test "prepare: SINGLE_REBOOT bloquea si el full-upgrade traería libc6" {
  printf 'Inst libc6 [2.35-0ubuntu3.8] (2.35-0ubuntu3.9 Ubuntu:22.04/jammy-updates)\nInst curl [1] (2)\n' > "$STUB_STATE/apt-sim"
  run sh "$SCRIPT" prepare
  [ "$status" -eq 1 ]
  [[ "$output" == *"necesitaría un reboot previo por: libc6"* ]]
  [ ! -f "$ROOT/var/lib/os-upgrade/failed" ]
}

@test "prepare: SINGLE_REBOOT bloquea si ya hay reboot pendiente por kernel" {
  echo "linux-image-5.15.0-101-generic" > "$ROOT/run/reboot-required.pkgs"
  run sh "$SCRIPT" prepare
  [ "$status" -eq 1 ]
  [[ "$output" == *"linux-image-5.15.0-101-generic"* ]]
}

@test "prepare: paquetes que no exigen reboot previo no bloquean" {
  printf 'Inst openssl [1] (2)\n' > "$STUB_STATE/apt-sim"
  echo "dbus" > "$ROOT/run/reboot-required.pkgs"
  run sh "$SCRIPT" prepare
  [ "$status" -eq 0 ]
}

@test "prepare: con SINGLE_REBOOT=false solo avisa" {
  printf 'Inst libc6 [1] (2)\n' > "$STUB_STATE/apt-sim"
  SINGLE_REBOOT=false run sh "$SCRIPT" prepare
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN habrá un reboot adicional"* ]]
}

@test "prepare: la simulación usa el pin de metapaquetes de kernel" {
  run sh "$SCRIPT" prepare
  [ "$status" -eq 0 ]
  called "apt-get -s -o Dir::Etc::Preferences=$ROOT/var/lib/os-upgrade/sim-preferences full-upgrade"
}

@test "prepare: espacio insuficiente falla sin marcar el nodo" {
  echo 100 > "$STUB_STATE/df-root"
  run sh "$SCRIPT" prepare
  [ "$status" -eq 1 ]
  [[ "$output" == *"espacio libre insuficiente en /"* ]]
  [ ! -f "$ROOT/var/lib/os-upgrade/failed" ]
}

@test "prepare: apt-get update fallido (proxy) falla" {
  touch "$STUB_STATE/fail.apt-update"
  run sh "$SCRIPT" prepare
  [ "$status" -eq 1 ]
  [[ "$output" == *"apt-get update falló"* ]]
}

@test "prepare: nodo marcado como fallido no avanza" {
  echo "motivo" > "$ROOT/var/lib/os-upgrade/failed"
  run sh "$SCRIPT" prepare
  [ "$status" -eq 1 ]
  [[ "$output" == *"marcado como fallido"* ]]
}

@test "prepare: versión no soportada falla" {
  set_os 20.04
  run sh "$SCRIPT" prepare
  [ "$status" -eq 1 ]
  [[ "$output" == *"versión no soportada: 20.04"* ]]
}

@test "prepare: con el upgrade en curso deja pasar" {
  touch "$STUB_STATE/active.os-upgrade-release"
  run sh "$SCRIPT" prepare
  [ "$status" -eq 0 ]
  [[ "$output" == *"Upgrade ya en curso"* ]]
}

@test "prepare: nodo ya terminado pasa sin comprobar nada" {
  set_os 24.04
  set_running "$TARGET_KERNEL"
  printf '%s\n' "linux-image-$TARGET_KERNEL" "linux-modules-$TARGET_KERNEL" "linux-modules-extra-$TARGET_KERNEL" >> "$STUB_STATE/installed"
  echo 1 > "$STUB_STATE/df-root"
  run sh "$SCRIPT" prepare
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nodo ya actualizado"* ]]
}

@test "prepare: nodo en 24.04 (solo cambio de kernel) no simula reboot previo" {
  set_os 24.04
  printf 'Inst libc6 [1] (2)\n' > "$STUB_STATE/apt-sim"
  run sh "$SCRIPT" prepare
  [ "$status" -eq 0 ]
}
