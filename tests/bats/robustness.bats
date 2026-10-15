#!/usr/bin/env bats
# Iteración 3: fuentes de terceros, paquetes retenidos, hook post-upgrade, log e informe.

load helpers

setup() {
  setup_node
  fake_predownload
  export POST_UPGRADE_HOOK_FILE="$BATS_TEST_TMPDIR/post-upgrade-hook.sh"
  export POST_UPGRADE_HOOK_SLEEP=0
}

state() { echo "$ROOT/var/lib/os-upgrade/$1"; }
report() { cat "$ROOT/var/log/os-upgrade-report.txt"; }

# Upgrade completo: primera pasada, reboot y cierre.
full_upgrade() {
  run sh "$SCRIPT" upgrade
  simulate_reboot
  run sh "$SCRIPT" upgrade
}

# ------------------------------------------------------------------ fuentes de terceros
@test "fuentes: mirror interno de Ubuntu sin ALLOW_THIRD_PARTY -> prepare falla antes del drain" {
  echo "deb http://mirror.interno.local/ubuntu jammy main" > "$ROOT/etc/apt/sources.list"
  ALLOW_THIRD_PARTY=false run sh "$SCRIPT" prepare
  [ "$status" -eq 1 ]
  [[ "$output" == *"el mirror de Ubuntu del nodo (http://mirror.interno.local/ubuntu) no es un mirror público"* ]]
  [ ! -f "$(state failed)" ]
}

@test "fuentes: mirror interno con ALLOW_THIRD_PARTY=true (por defecto) pasa e informa" {
  echo "deb http://mirror.interno.local/ubuntu jammy main" > "$ROOT/etc/apt/sources.list"
  run sh "$SCRIPT" prepare
  [ "$status" -eq 0 ]
  [[ "$output" == *"fuentes no oficiales (se mantienen si publican noble"*"mirror.interno.local"* ]]
}

@test "fuentes: repo de proveedor con mirror oficial y ALLOW_THIRD_PARTY=false solo avisa" {
  echo "deb http://cl.archive.ubuntu.com/ubuntu jammy main" > "$ROOT/etc/apt/sources.list"
  mkdir -p "$ROOT/etc/apt/sources.list.d"
  echo "deb [signed-by=/usr/share/keyrings/v.gpg] https://repo.vendor.example/apt jammy main" > "$ROOT/etc/apt/sources.list.d/vendor.list"
  ALLOW_THIRD_PARTY=false run sh "$SCRIPT" prepare
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN fuentes no oficiales que el upgrade desactivará"*"https://repo.vendor.example/apt (jammy, /etc/apt/sources.list.d/vendor.list)"* ]]
}

@test "fuentes: entiende el formato deb822 (.sources) y Enabled: no" {
  mkdir -p "$ROOT/etc/apt/sources.list.d"
  cat > "$ROOT/etc/apt/sources.list.d/vendor.sources" <<'EOF'
Types: deb
URIs: https://repo.vendor.example/apt
Suites: jammy
Components: main

Enabled: no
Types: deb
URIs: https://otro.example/apt
Suites: jammy
Components: main
EOF
  run sh "$SCRIPT" prepare
  [ "$status" -eq 0 ]
  [[ "$output" == *"repo.vendor.example/apt (jammy, /etc/apt/sources.list.d/vendor.sources)"* ]]
  [[ "$output" != *"otro.example"* ]]
}

@test "fuentes: do-release-upgrade recibe --allow-third-party por defecto" {
  run sh "$SCRIPT" upgrade
  called "do-release-upgrade -f DistUpgradeViewNonInteractive --allow-third-party"
}

@test "fuentes: con ALLOW_THIRD_PARTY=false no se pasa --allow-third-party" {
  ALLOW_THIRD_PARTY=false run sh "$SCRIPT" upgrade
  called "do-release-upgrade -f DistUpgradeViewNonInteractive$"
  not_called "allow-third-party"
}

@test "fuentes: las desactivadas por el upgrade se avisan y quedan en el informe" {
  touch "$STUB_STATE/dru-disable-vendor"
  full_upgrade
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN fuentes desactivadas por el upgrade"*"http://repo.vendor.example/apt (noble, /etc/apt/sources.list.d/vendor.list)"* ]]
  report | grep -q "  http://repo.vendor.example/apt (noble"
}

@test "fuentes: ALLOW_THIRD_PARTY inválido se rechaza" {
  ALLOW_THIRD_PARTY=si run sh "$SCRIPT" prepare
  [ "$status" -eq 1 ]
  [[ "$output" == *"ALLOW_THIRD_PARTY debe ser true o false"* ]]
}

# ------------------------------------------------------------------ paquetes retenidos
@test "retenidos: prepare y predownload avisan de paquetes en hold ajenos al kernel" {
  printf '%s\n' docker-ce "linux-image-$TARGET_KERNEL" > "$STUB_STATE/held"
  run sh "$SCRIPT" prepare
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN paquetes retenidos (apt-mark hold) que pueden bloquear el release upgrade: docker-ce "* ]]
  [[ "$output" != *"retenidos"*"linux-image-$TARGET_KERNEL"* ]]
  run sh "$SCRIPT" predownload
  [[ "$output" == *"paquetes retenidos"*"docker-ce"* ]]
}

# ------------------------------------------------------------------ hook post-upgrade
@test "hook: se ejecuta al cerrar con el entorno del nodo y queda en el informe" {
  cat > "$POST_UPGRADE_HOOK_FILE" <<'EOF'
echo "comprobando $NODE_NAME con $KERNEL_VERSION en $TARGET_VERSION"
EOF
  SYSTEM_UPGRADE_NODE_NAME=nodo-2 full_upgrade
  [ "$status" -eq 0 ]
  [[ "$output" == *"INFO hook: comprobando nodo-2 con $TARGET_KERNEL en 24.04"* ]]
  report | grep -qx "hook:           OK"
}

@test "hook: reintenta y pasa si se recupera" {
  cat > "$POST_UPGRADE_HOOK_FILE" <<EOF
n=\$(cat "$BATS_TEST_TMPDIR/n" 2>/dev/null || echo 0); n=\$((n + 1)); echo \$n > "$BATS_TEST_TMPDIR/n"
[ \$n -ge 2 ] || { echo "servicio aún no listo"; exit 1; }
echo listo
EOF
  full_upgrade
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN hook: servicio aún no listo"*"Hook post-upgrade (intento 2/3)"*"INFO hook: listo"* ]]
}

@test "hook: si falla siempre, el nodo queda marcado y no se cierra" {
  printf 'echo "GPU no detectada"\nexit 1\n' > "$POST_UPGRADE_HOOK_FILE"
  full_upgrade
  [ "$status" -eq 1 ]
  grep -q "el hook post-upgrade falló 3 veces" "$(state failed)"
  [ ! -f "$(state done)" ]
  [ ! -f "$ROOT/var/log/os-upgrade-report.txt" ]
}

@test "hook: un error de sintaxis se detecta en prepare, antes del drain" {
  printf 'if [ 1 = 1 ]; then\necho x\n' > "$POST_UPGRADE_HOOK_FILE"
  run sh "$SCRIPT" prepare
  [ "$status" -eq 1 ]
  [[ "$output" == *"el hook post-upgrade tiene errores de sintaxis"* ]]
}

# ------------------------------------------------------------------ log e informe
@test "log: archivo del host en formato clave=valor con los pasos" {
  full_upgrade
  log="$ROOT/var/log/os-upgrade.log"
  grep -q '^ts=[^ ]* node=[^ ]* phase=upgrade level=INFO msg="PASO 1/7: preparar el host' "$log"
  grep -q 'phase=host-phase level=INFO msg="PASO 5/7: instalar y fijar el kernel' "$log"
  grep -q 'msg="PASO 7/7: verificación y cierre' "$log"
  # Todas las líneas siguen el formato.
  run grep -cv '^ts=[^ ]* node=[^ ]* phase=[^ ]* level=[A-Z]* msg=".*"$' "$log"
  [ "$output" = 0 ]
}

@test "informe: se escribe una vez con duración, reboots y versiones" {
  full_upgrade
  [ "$status" -eq 0 ]
  report | grep -qx "sistema:        Ubuntu 24.04"
  report | grep -qx "kernel:         $TARGET_KERNEL (fijado: $TARGET_KERNEL)"
  report | grep -qx "reboots:        1"
  report | grep -q "^duración:       [0-9]* min"
  before=$(report)
  run sh "$SCRIPT" upgrade
  [ "$status" -eq 0 ]
  [ "$(report)" = "$before" ]
  run sh "$SCRIPT" status
  [[ "$output" == *"os-upgrade: informe de"* ]]
}

@test "informe: un cambio de kernel posterior genera un informe nuevo" {
  full_upgrade
  first=$(report)
  export KERNEL_VERSION=6.8.0-140-generic
  fake_predownload
  run sh "$SCRIPT" upgrade
  simulate_reboot
  run sh "$SCRIPT" upgrade
  [ "$status" -eq 0 ]
  report | grep -qx "kernel:         6.8.0-140-generic (fijado: 6.8.0-140-generic)"
  [ "$(report)" != "$first" ]
}

@test "log: comillas y barras del mensaje se escapan en el archivo" {
  KERNEL_VERSION='6.8"x\y' run sh "$SCRIPT" prepare
  [ "$status" -eq 1 ]
  grep -qF 'msg="KERNEL_VERSION inválido: '"'"'6.8\"x\\y'"'"' (formato esperado' "$ROOT/var/log/os-upgrade.log"
}
