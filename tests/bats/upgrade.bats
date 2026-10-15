#!/usr/bin/env bats
# Subcomando upgrade (+ host-phase, que el stub de systemd-run ejecuta de forma síncrona).

load helpers

setup() {
  setup_node
  fake_predownload
}

state() { echo "$ROOT/var/lib/os-upgrade/$1"; }
grub_default() { sed -n 's/^set default="\(.*\)"$/\1/p' "$ROOT/boot/grub/grub.cfg"; }
expected_default() { echo "gnulinux-advanced-0123-abcd>gnulinux-$TARGET_KERNEL-advanced-0123-abcd"; }

@test "upgrade: 22.04 -> 24.04 con un solo reboot y el kernel fijado" {
  run sh "$SCRIPT" upgrade
  # El pod queda esperando el reboot; con los stubs "sleep" vuelve y el script sale con 1.
  [[ "$output" == *"Release upgrade terminado; esperando el reboot"* ]]
  [ "$(reboot_count)" -eq 1 ]
  grep -q 'VERSION_ID="24.04"' "$ROOT/etc/os-release"
  # Kernel fijado instalado y retenido.
  for p in linux-image linux-modules linux-modules-extra; do
    installed "$p-$TARGET_KERNEL"
    grep -qx "$p-$TARGET_KERNEL" "$STUB_STATE/held"
  done
  # Metapaquetes fuera y bloqueados.
  not_installed linux-generic
  not_installed linux-image-generic
  grep -q "^Package: linux-generic\* linux-image-generic\*" "$ROOT/etc/apt/preferences.d/99-os-upgrade-kernel"
  grep -qx "Pin-Priority: -1" "$ROOT/etc/apt/preferences.d/99-os-upgrade-kernel"
  grep -qx linux-firmware "$STUB_STATE/manual"
  # GRUB apunta al kernel fijado aunque el kernel arrancado siga instalado.
  installed "linux-image-$OLD_KERNEL"
  [ "$(grub_default)" = "$(expected_default)" ]
  # La release-upgrade usó la caché pre-descargada.
  [ -f "$ROOT/var/cache/apt/archives/linux-image-${TARGET_KERNEL}_1.0_amd64.deb" ]
  [ -f "$(state release-upgrade.done)" ]
  [ ! -f "$(state failed)" ]
  # Timers de unattended-upgrades desactivados durante el proceso.
  called "systemctl disable --now apt-daily-upgrade.timer"
  grep -qx "Prompt=lts" "$ROOT/etc/update-manager/release-upgrades"
}

@test "upgrade: los metapaquetes se quitan ANTES del full-upgrade" {
  run sh "$SCRIPT" upgrade
  remove_line=$(grep -n "remove --purge linux-generic" "$STUB_STATE/calls.log" | head -n1 | cut -d: -f1)
  upgrade_line=$(grep -n "apt-get .* full-upgrade$" "$STUB_STATE/calls.log" | grep -v -- ' -s ' | head -n1 | cut -d: -f1)
  [ -n "$remove_line" ] && [ -n "$upgrade_line" ]
  [ "$remove_line" -lt "$upgrade_line" ]
}

@test "upgrade: tras el reboot, cierra y devuelve 0" {
  run sh "$SCRIPT" upgrade
  simulate_reboot
  [ "$(cat "$STUB_STATE/uname-r")" = "$TARGET_KERNEL" ]
  run sh "$SCRIPT" upgrade
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK: Ubuntu 24.04, kernel $TARGET_KERNEL"* ]]
  # El kernel antiguo se purga una vez que ya no está arrancado.
  not_installed "linux-image-$OLD_KERNEL"
  not_installed "linux-modules-$OLD_KERNEL"
  # Se restaura lo temporal y se mantiene lo que garantiza el kernel.
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

@test "upgrade: la ejecución repetida en un nodo terminado es idempotente" {
  run sh "$SCRIPT" upgrade
  simulate_reboot
  run sh "$SCRIPT" upgrade
  [ "$status" -eq 0 ]
  run sh "$SCRIPT" upgrade
  [ "$status" -eq 0 ]
  [ "$(reboot_count)" -eq 1 ]
}

@test "upgrade: los timers que estaban desactivados no se reactivan" {
  echo disabled > "$STUB_STATE/enabled.apt-daily.timer"
  run sh "$SCRIPT" upgrade
  simulate_reboot
  run sh "$SCRIPT" upgrade
  [ "$status" -eq 0 ]
  not_called "systemctl enable --now apt-daily.timer"
  called "systemctl enable --now apt-daily-upgrade.timer"
}

@test "upgrade: kernel arrancado de 22.04 con versión MAYOR que el objetivo" {
  # p. ej. HWE de jammy 6.8.0-147: sin GRUB_DEFAULT arrancaría ese.
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

@test "upgrade: kernels no arrancados distintos del objetivo se purgan antes del reboot" {
  other=5.15.0-90-generic
  printf '%s\n' "linux-image-$other" "linux-modules-$other" >> "$STUB_STATE/installed"
  add_boot_kernel "$other"
  run sh "$SCRIPT" upgrade
  not_installed "linux-image-$other"
  not_installed "linux-modules-$other"
  installed "linux-image-$OLD_KERNEL"
}

@test "upgrade: reboot previo si el full-upgrade deja libc6 pendiente" {
  echo libc6 > "$STUB_STATE/full-upgrade-reboot-pkgs"
  run sh "$SCRIPT" upgrade
  [[ "$output" == *"do-release-upgrade exige reiniciar antes por: libc6"* ]]
  [ "$(reboot_count)" -eq 1 ]
  not_called "do-release-upgrade"
  # Tras ese reboot, sigue con el release upgrade.
  rm "$STUB_STATE/full-upgrade-reboot-pkgs"
  simulate_reboot "$OLD_KERNEL"
  run sh "$SCRIPT" upgrade
  called "do-release-upgrade"
  [ "$(reboot_count)" -eq 2 ]
}

@test "upgrade: do-release-upgrade fallido marca el nodo y no reinicia" {
  touch "$STUB_STATE/fail.do-release-upgrade"
  run sh "$SCRIPT" upgrade
  [ "$status" -ne 0 ]
  [ -f "$(state failed)" ]
  grep -q "do-release-upgrade terminó con error" "$(state failed)"
  [ "$(reboot_count)" -eq 0 ]
  # El siguiente intento del Job no hace nada.
  run sh "$SCRIPT" upgrade
  [ "$status" -eq 1 ]
  [[ "$output" == *"marcado como fallido"* ]]
  [ "$(grep -c do-release-upgrade "$STUB_STATE/calls.log")" -eq 1 ]
}

@test "upgrade: tras un do-release-upgrade fallido, el reintento exige confirmación humana" {
  touch "$STUB_STATE/fail.do-release-upgrade"
  run sh "$SCRIPT" upgrade
  rm "$STUB_STATE/fail.do-release-upgrade"
  run sh "$SCRIPT" reset-failed
  # Sin borrar la marca "started" no se relanza.
  run sh "$SCRIPT" upgrade
  [[ "$output" == *"el release upgrade empezó y no terminó"* ]]
  # Tras confirmar a mano que 22.04 está sano (runbook), se relanza.
  run sh "$SCRIPT" reset-failed
  rm "$(state release-upgrade.started)"
  run sh "$SCRIPT" upgrade
  [ "$(grep -c do-release-upgrade "$STUB_STATE/calls.log")" -eq 2 ]
  [ "$(reboot_count)" -eq 1 ]
}

@test "upgrade: sin entrada de GRUB para el kernel no reinicia" {
  touch "$STUB_STATE/grub-no-entries"
  run sh "$SCRIPT" upgrade
  [ -f "$(state failed)" ]
  grep -q "no hay entrada de GRUB para $TARGET_KERNEL" "$(state failed)"
  [ "$(reboot_count)" -eq 0 ]
}

@test "upgrade: tras arreglar GRUB, reset-failed + reintento termina el kernel y reinicia" {
  touch "$STUB_STATE/grub-no-entries"
  run sh "$SCRIPT" upgrade
  [ -f "$(state failed)" ]
  grep -q 'VERSION_ID="24.04"' "$ROOT/etc/os-release"
  rm "$STUB_STATE/grub-no-entries"
  run sh "$SCRIPT" reset-failed
  run sh "$SCRIPT" prepare
  [ "$status" -eq 0 ]
  run sh "$SCRIPT" upgrade
  [[ "$output" == *"Reiniciando (1/3): arrancar kernel $TARGET_KERNEL"* ]]
  [ "$(grub_default)" = "$(expected_default)" ]
  [ "$(grep -c do-release-upgrade "$STUB_STATE/calls.log")" -eq 1 ]
  simulate_reboot
  run sh "$SCRIPT" upgrade
  [ "$status" -eq 0 ]
}

@test "upgrade: release upgrade interrumpido requiere intervención" {
  set_os 24.04
  date > "$(state release-upgrade.started)"
  run sh "$SCRIPT" upgrade
  [ "$status" -eq 1 ]
  [[ "$output" == *"el release upgrade empezó y no terminó"* ]]
  [ -f "$(state failed)" ]
  not_called "apt-get .* install"
}

@test "upgrade: la unidad en curso se espera en vez de relanzarla" {
  touch "$STUB_STATE/active.os-upgrade-release"
  # La unidad sigue activa: el stub de sleep vuelve enseguida; se desactiva al primer sleep.
  cat > "$BATS_TEST_TMPDIR/sleep" <<'EOF'
#!/bin/sh
rm -f "$STUB_STATE/active.os-upgrade-release"
EOF
  chmod +x "$BATS_TEST_TMPDIR/sleep"
  date > "$(state release-upgrade.started)"
  date > "$(state release-upgrade.done)"
  PATH="$BATS_TEST_TMPDIR:$PATH" run sh "$SCRIPT" upgrade
  [[ "$output" == *"Release upgrade en curso"* ]]
  [[ "$output" == *"esperando el reboot"* ]]
  not_called "systemd-run"
}

@test "upgrade: GRUB arrancó otro kernel -> reinstala, corrige y reinicia" {
  run sh "$SCRIPT" upgrade
  simulate_reboot "$OLD_KERNEL"
  run sh "$SCRIPT" upgrade
  [[ "$output" == *"Reiniciando (2/3): arrancar kernel $TARGET_KERNEL"* ]]
  [ "$(grub_default)" = "$(expected_default)" ]
}

@test "upgrade: límite de reboots marca el nodo" {
  echo 3 > "$(state reboots)"
  set_os 24.04
  run sh "$SCRIPT" upgrade
  [ "$status" -eq 1 ]
  [ -f "$(state failed)" ]
  grep -q "demasiados reboots" "$(state failed)"
  [ "$(reboot_count)" -eq 0 ]
}

@test "upgrade: nodo ya en 24.04 solo cambia el kernel, sin release upgrade" {
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

@test "upgrade: nodo que ya arranca el kernel objetivo queda fijado sin reboot" {
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

@test "upgrade: rke2 inactivo al cerrar falla sin marcar el nodo" {
  run sh "$SCRIPT" upgrade
  simulate_reboot
  rm "$STUB_STATE/active.rke2-server"
  run sh "$SCRIPT" upgrade
  [ "$status" -eq 1 ]
  [[ "$output" == *"rke2 no está activo"* ]]
  [ ! -f "$(state failed)" ]
}

@test "upgrade: tras el reboot espera a que rke2 termine de arrancar (activating)" {
  run sh "$SCRIPT" upgrade
  simulate_reboot
  echo 3 > "$STUB_STATE/activating.rke2-server"
  RKE2_WAIT_SECONDS=60 RKE2_WAIT_INTERVAL=0 run sh "$SCRIPT" upgrade
  [ "$status" -eq 0 ]
  [[ "$output" == *"esperando a que rke2 esté activo"* ]]
  [[ "$output" == *"OK: Ubuntu 24.04"* ]]
}

@test "upgrade: si rke2 no arranca en RKE2_WAIT_SECONDS, falla sin marcar el nodo" {
  run sh "$SCRIPT" upgrade
  simulate_reboot
  rm "$STUB_STATE/active.rke2-server"
  RKE2_WAIT_SECONDS=0 RKE2_WAIT_INTERVAL=0 run sh "$SCRIPT" upgrade
  [ "$status" -eq 1 ]
  [[ "$output" == *"rke2 no está activo tras 0 s"* ]]
  [ ! -f "$(state failed)" ]
}

@test "upgrade: dpkg a medio configurar se marca para revisión" {
  echo "paquete X a medio configurar" > "$STUB_STATE/dpkg-audit"
  run sh "$SCRIPT" upgrade
  [ "$status" -eq 1 ]
  grep -q "dpkg --audit" "$(state failed)"
  not_called "do-release-upgrade"
}

@test "upgrade: el proxy llega a la unidad del host" {
  HTTP_PROXY="http://proxy:3128" NO_PROXY="10.0.0.0/8,.local" run sh "$SCRIPT" upgrade
  grep -qx "HTTP_PROXY='http://proxy:3128'" "$(state config)"
  grep -qx "NO_PROXY='10.0.0.0/8,.local'" "$(state config)"
  # apt-get llamado desde host-phase (tras do-release-upgrade) ve el proxy.
  awk '/do-release-upgrade/ {f=1} f && /env http_proxy=http:\/\/proxy:3128/ {ok=1} END {exit !ok}' "$STUB_STATE/calls.log"
}

@test "upgrade: valores con comillas se guardan sin romper la configuración" {
  HTTP_PROXY="http://us'er:pa ss@proxy:3128" run sh "$SCRIPT" upgrade
  # shellcheck disable=SC1090
  ( . "$(state config)"; [ "$HTTP_PROXY" = "http://us'er:pa ss@proxy:3128" ] )
}

@test "reset-failed borra la marca y el contador" {
  echo "x" > "$(state failed)"
  echo 3 > "$(state reboots)"
  run sh "$SCRIPT" reset-failed
  [ "$status" -eq 0 ]
  [ ! -f "$(state failed)" ]
  [ ! -f "$(state reboots)" ]
}

@test "status muestra el estado del nodo" {
  run sh "$SCRIPT" upgrade
  run sh "$SCRIPT" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"Kernel objetivo: $TARGET_KERNEL"* ]]
  [[ "$output" == *"GRUB_DEFAULT="* ]]
}

@test "subcomando desconocido" {
  run sh "$SCRIPT" foo
  [ "$status" -eq 2 ]
}
