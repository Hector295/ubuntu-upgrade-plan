#!/usr/bin/env bats
# Render de Kustomize y validación contra el CRD real de Rancher (manifests/schemas/lab).

REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
YQ="$REPO/tools/bin/yq"
VALIDATE="$REPO/scripts/validate-manifests.sh"
SCHEMA="$REPO/manifests/schemas/lab"

setup_file() {
  "$REPO/tools/bin/kustomize" build --load-restrictor LoadRestrictionsNone \
    "$REPO/manifests/overlays/lab" > "$BATS_FILE_TMPDIR/lab.yaml"
}

setup() {
  cp "$BATS_FILE_TMPDIR/lab.yaml" "$BATS_TEST_TMPDIR/m.yaml"
  M="$BATS_TEST_TMPDIR/m.yaml"
}

# Modifica los documentos que cumplan el filtro.
edit() { "$YQ" -i "$1" "$M"; }

@test "render lab: válido" {
  run sh "$VALIDATE" "$M" "$SCHEMA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Validación OK"*"6.8.0-139-generic"* ]]
}

@test "render lab: los Plans referencian el Secret y el ConfigMap con hash generados" {
  secret=$("$YQ" 'select(.kind == "Secret") | .metadata.name' "$M")
  cm=$("$YQ" 'select(.kind == "ConfigMap") | .metadata.name' "$M")
  [[ "$secret" == os-upgrade-script-* ]]
  [[ "$cm" == os-upgrade-config-* ]]
  [ "$("$YQ" ea '[select(.kind == "Plan") | .spec.secrets[0].name] | unique | .[]' "$M")" = "$secret" ]
  [ "$("$YQ" ea '[select(.kind == "Plan") | .spec.upgrade.envFrom[0].configMapRef.name] | unique | .[]' "$M")" = "$cm" ]
}

@test "render lab: el Secret contiene el upgrade.sh actual" {
  "$YQ" 'select(.kind == "Secret") | .data["upgrade.sh"]' "$M" | base64 -d > "$BATS_TEST_TMPDIR/u.sh"
  cmp "$BATS_TEST_TMPDIR/u.sh" "$REPO/scripts/upgrade.sh"
}

@test "render lab: prepare antes del drain y solo en los Plans de upgrade" {
  [ "$("$YQ" 'select(.metadata.name == "os-upgrade-workers") | .spec.prepare.args[2]' "$M")" = prepare ]
  [ "$("$YQ" 'select(.metadata.name == "os-upgrade-cp") | .spec.prepare.securityContext.privileged' "$M")" = true ]
  [ "$("$YQ" 'select(.metadata.name == "os-upgrade-predownload") | .spec.drain' "$M")" = null ]
  [ "$("$YQ" 'select(.metadata.name == "os-upgrade-predownload") | .spec.prepare' "$M")" = null ]
}

@test "validación: postCompleteLabels se rechaza" {
  edit '(select(.kind == "Plan") | .spec.postCompleteLabels) = {"os-upgrade": "done"}'
  run sh "$VALIDATE" "$M" "$SCHEMA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"postCompleteLabels"* ]]
}

@test "validación: drain.timeout se rechaza" {
  edit '(select(.metadata.name == "os-upgrade-cp") | .spec.drain.timeout) = 1800000000000'
  run sh "$VALIDATE" "$M" "$SCHEMA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"os-upgrade-cp: spec.drain.timeout está prohibido"* ]]
}

@test "validación: un campo que el CRD no conoce se rechaza" {
  edit '(select(.metadata.name == "os-upgrade-workers") | .spec.upgrade.inventado) = true'
  run sh "$VALIDATE" "$M" "$SCHEMA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"inventado"* ]]
}

@test "validación: tipo incorrecto según el CRD se rechaza" {
  edit '(select(.metadata.name == "os-upgrade-workers") | .spec.concurrency) = "1"'
  run sh "$VALIDATE" "$M" "$SCHEMA"
  [ "$status" -eq 1 ]
}

@test "validación: KERNEL_VERSION vacío se rechaza" {
  edit '(select(.kind == "ConfigMap") | .data.KERNEL_VERSION) = ""'
  run sh "$VALIDATE" "$M" "$SCHEMA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"KERNEL_VERSION no está definido"* ]]
}

@test "validación: KERNEL_VERSION con formato inválido se rechaza" {
  edit '(select(.kind == "ConfigMap") | .data.KERNEL_VERSION) = "6.8-0-139-generic"'
  run sh "$VALIDATE" "$M" "$SCHEMA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"KERNEL_VERSION inválido"* ]]
}

@test "validación: imagen sin tag se rechaza" {
  edit '(select(.metadata.name == "os-upgrade-cp") | .spec.upgrade.image) = "registry.local:5000/ubuntu"'
  run sh "$VALIDATE" "$M" "$SCHEMA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"imagen sin tag explícito: registry.local:5000/ubuntu"* ]]
}

@test "validación: concurrency distinto de 1 con drain se rechaza" {
  edit '(select(.metadata.name == "os-upgrade-workers") | .spec.concurrency) = 2'
  run sh "$VALIDATE" "$M" "$SCHEMA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"os-upgrade-workers: los Plans con drain deben tener concurrency: 1"* ]]
}

@test "validación: jobActiveDeadlineSecs fuera de rango se rechaza" {
  edit '(select(.metadata.name == "os-upgrade-cp") | .spec.jobActiveDeadlineSecs) = 100'
  run sh "$VALIDATE" "$M" "$SCHEMA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"os-upgrade-cp: jobActiveDeadlineSecs"* ]]
}

@test "validación: proxy sin esquema se rechaza" {
  edit '(select(.kind == "ConfigMap") | .data.HTTP_PROXY) = "proxy:3128"'
  run sh "$VALIDATE" "$M" "$SCHEMA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"HTTP_PROXY debe empezar por http://"* ]]
}

@test "validación: namespaces distintos se rechazan" {
  edit '(select(.metadata.name == "os-upgrade-cp") | .metadata.namespace) = "otro"'
  run sh "$VALIDATE" "$M" "$SCHEMA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"mismo namespace"* ]]
}

@test "validación: sin CRD del cluster explica cómo exportarlo" {
  run sh "$VALIDATE" "$M" "$BATS_TEST_TMPDIR/no-existe"
  [ "$status" -eq 2 ]
  [[ "$output" == *"kubectl get crd plans.upgrade.cattle.io -o json"* ]]
}

# Overlay temporal dentro del repo (kustomize no admite rutas absolutas a la base).
make_overlay_with_hook() {
  OVL="$REPO/manifests/overlays/.bats-$$"
  mkdir -p "$OVL"
  echo "KERNEL_VERSION=6.8.0-139-generic" > "$OVL/config.env"
  cp "$1" "$OVL/post-upgrade-hook.sh"
  cat > "$OVL/kustomization.yaml" <<'YAML'
resources:
  - ../../base
configMapGenerator:
  - name: os-upgrade-config
    behavior: merge
    envs: [config.env]
secretGenerator:
  - name: os-upgrade-script
    behavior: merge
    files:
      - post-upgrade-hook.sh
YAML
  "$REPO/tools/bin/kustomize" build --load-restrictor LoadRestrictionsNone "$OVL" > "$M"
  rm -rf "$OVL"
}

@test "hook: el overlay lo añade al Secret junto a upgrade.sh y se valida" {
  make_overlay_with_hook "$REPO/docs/ejemplos/post-upgrade-hook.sh"
  [ "$("$YQ" 'select(.kind == "Secret") | .data | keys | join(",")' "$M")" = "post-upgrade-hook.sh,upgrade.sh" ]
  "$YQ" 'select(.kind == "Secret") | .data["post-upgrade-hook.sh"]' "$M" | base64 -d | cmp - "$REPO/docs/ejemplos/post-upgrade-hook.sh"
  run sh "$VALIDATE" "$M" "$SCHEMA"
  [ "$status" -eq 0 ]
}

@test "hook: un error de sintaxis se detecta al validar" {
  printf 'if true; then\necho x\n' > "$BATS_TEST_TMPDIR/bad.sh"
  make_overlay_with_hook "$BATS_TEST_TMPDIR/bad.sh"
  run sh "$VALIDATE" "$M" "$SCHEMA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"post-upgrade-hook.sh tiene errores de sintaxis"* ]]
}

@test "validación: ALLOW_THIRD_PARTY y POST_UPGRADE_HOOK_RETRIES" {
  [ "$("$YQ" 'select(.kind == "ConfigMap") | .data.ALLOW_THIRD_PARTY' "$M")" = true ]
  edit '(select(.kind == "ConfigMap") | .data.ALLOW_THIRD_PARTY) = "yes"'
  edit '(select(.kind == "ConfigMap") | .data.POST_UPGRADE_HOOK_RETRIES) = "x"'
  run sh "$VALIDATE" "$M" "$SCHEMA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ALLOW_THIRD_PARTY debe ser true o false"* ]]
  [[ "$output" == *"POST_UPGRADE_HOOK_RETRIES debe ser un número entero"* ]]
}
