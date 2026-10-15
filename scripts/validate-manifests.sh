#!/bin/sh
# Valida los manifiestos generados para un cluster, sin contactar con el cluster:
#   1. Esquema: los Plans contra el CRD real del cluster en modo estricto (un campo que el
#      CRD no conoce, como postCompleteLabels, falla igual que en el API server).
#   2. Reglas propias: lo que el esquema acepta pero rompe el controller o el proceso.
#
# Uso: validate-manifests.sh <manifiestos.yaml> <dir-esquema-cluster>
#   <dir-esquema-cluster> contiene crd-plans.json, exportado con:
#   kubectl get crd plans.upgrade.cattle.io -o json > manifests/schemas/<cluster>/crd-plans.json
set -eu

TOOLS_BIN="${TOOLS_BIN:-$(cd "$(dirname "$0")/../tools/bin" && pwd)}"
YQ="$TOOLS_BIN/yq"
KUBECONFORM="$TOOLS_BIN/kubeconform"

[ $# -eq 2 ] || { echo "Uso: $0 <manifiestos.yaml> <dir-esquema-cluster>" >&2; exit 2; }
MANIFESTS=$1
SCHEMA_DIR=$2
CRD="$SCHEMA_DIR/crd-plans.json"

[ -f "$MANIFESTS" ] || { echo "No existe $MANIFESTS" >&2; exit 2; }
[ -f "$CRD" ] || {
  echo "No existe $CRD. Exportarlo del cluster con:" >&2
  echo "  kubectl get crd plans.upgrade.cattle.io -o json > $CRD" >&2
  exit 2
}

errors=0
error() { echo "ERROR: $*"; errors=$((errors + 1)); }

# ------------------------------------------------------------------ 1. esquema del CRD
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# openAPIV3Schema -> JSON Schema estricto: sin propiedades desconocidas y con nullable.
# Ojo: con yq hay que usar "|= (.campo = valor)"; "(..|select()).campo = valor" deja null
# en los objetos anidados.
# El esquema del CRD no declara apiVersion/kind/metadata (los valida el API server aparte).
"$YQ" -p json -o json '.spec.versions[] | select(.name == "v1") | .schema.openAPIV3Schema
  | .properties.apiVersion = {"type": "string"}
  | .properties.kind = {"type": "string"}
  | .properties.metadata = {"type": "object"}' "$CRD" > "$work/raw.json"
"$YQ" -p json -o json '
  (.. | select(tag == "!!map" and has("properties") and (has("additionalProperties") | not)
               and ((.["x-kubernetes-preserve-unknown-fields"] // false) | not))
  ) |= (.additionalProperties = false)
  | (.. | select(tag == "!!map" and .nullable == true and (.type | tag) == "!!str")) |= (.type = [.type, "null"])
' "$work/raw.json" > "$work/plan_v1.json"

if ! "$KUBECONFORM" -strict -summary -skip ConfigMap,Secret \
    -schema-location "$work/{{ .ResourceKind }}_{{ .ResourceAPIVersion }}.json" "$MANIFESTS"; then
  error "los Plans no cumplen el esquema del CRD instalado en el cluster"
fi

# ------------------------------------------------------------------ 2. reglas propias
plans() { "$YQ" ea "[.] | map(select(.kind == \"Plan\")) | $1" "$MANIFESTS"; }

[ "$(plans 'length')" -eq 3 ] || error "se esperaban 3 Plans (predownload, workers, cp)"

for name in $(plans '.[] | select(.spec.postCompleteLabels != null) | .metadata.name'); do
  error "$name: spec.postCompleteLabels no existe en el CRD de Rancher y el API server lo rechaza"
done

for name in $(plans '.[] | select(.spec.drain.timeout != null) | .metadata.name'); do
  error "$name: spec.drain.timeout está prohibido (en SUC v0.16 son nanosegundos en int32 y rompe el controller)"
done

for name in $(plans '.[] | select(.metadata.name | test("^system-agent-upgrader")) | .metadata.name'); do
  error "$name: no se gestionan los Plans de Rancher"
done

for name in $(plans '.[] | select(.spec.drain != null and .spec.concurrency != 1) | .metadata.name'); do
  error "$name: los Plans con drain deben tener concurrency: 1"
done

for name in $(plans '.[] | select(.spec.jobActiveDeadlineSecs == null or .spec.jobActiveDeadlineSecs < 600 or .spec.jobActiveDeadlineSecs > 86400) | .metadata.name'); do
  error "$name: jobActiveDeadlineSecs debe estar entre 600 y 86400"
done

for img in $(plans '.[] | (.spec.upgrade.image, .spec.prepare.image) | select(. != null)' | sort -u); do
  case "$img" in
    *@sha256:*) ;;
    *) echo "$img" | grep -Eq ':[^/]+$' || error "imagen sin tag explícito: $img" ;;
  esac
done

ns_count=$("$YQ" ea '[.] | map(select(.kind == "Plan" or .metadata.name | test("^os-upgrade-")) | .metadata.namespace) | unique | length' "$MANIFESTS")
[ "$ns_count" -eq 1 ] || error "Plans, Secret y ConfigMap deben estar en el mismo namespace"

# Configuración (ConfigMap os-upgrade-config).
cfg() { "$YQ" ea "[.] | map(select(.kind == \"ConfigMap\" and (.metadata.name | test(\"^os-upgrade-config\")))) | .[0].data.$1 // \"\"" "$MANIFESTS"; }

kernel=$(cfg KERNEL_VERSION)
if [ -z "$kernel" ]; then
  error "KERNEL_VERSION no está definido en config.env del overlay"
elif ! echo "$kernel" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-generic$'; then
  error "KERNEL_VERSION inválido: '$kernel' (formato esperado: 6.8.0-139-generic)"
fi
# Destinos soportados: los de la tabla TRANSITIONS de upgrade.sh (una sola fuente).
supported=$(awk -F'|' '/^TRANSITIONS="/ {f = 1; next} f && /^"/ {f = 0} f && NF {print $2}' \
  "$(dirname "$0")/upgrade.sh" | tr '\n' ' ')
target=$(cfg TARGET_VERSION)
case " $supported " in
  *" $target "*) ;;
  *) error "TARGET_VERSION '$target' no soportado (soportados: $supported)" ;;
esac
for name in $(plans ".[] | select(.spec.version != \"$target\") | .metadata.name"); do
  error "$name: spec.version no coincide con TARGET_VERSION ($target); ¿el overlay incluye components/target-version?"
done

for key in SINGLE_REBOOT REQUIRE_PREDOWNLOAD ALLOW_THIRD_PARTY; do
  case "$(cfg "$key")" in true|false) ;; *) error "$key debe ser true o false" ;; esac
done
for key in MIN_FREE_ROOT_MB MIN_FREE_BOOT_MB MAX_REBOOTS POST_UPGRADE_HOOK_RETRIES; do
  case "$(cfg "$key")" in ''|*[!0-9]*) error "$key debe ser un número entero" ;; esac
done
for key in HTTP_PROXY HTTPS_PROXY APT_MIRROR; do
  val=$(cfg "$key")
  case "$val" in
    ''|http://*|https://*) ;;
    *) error "$key debe empezar por http:// o https:// (valor: '$val')" ;;
  esac
done

# Hook post-upgrade opcional (clave post-upgrade-hook.sh del Secret): sintaxis de sh.
hook=$("$YQ" ea '[.] | map(select(.kind == "Secret" and (.metadata.name | test("^os-upgrade-script")))) | .[0].data["post-upgrade-hook.sh"] // ""' "$MANIFESTS")
if [ -n "$hook" ]; then
  echo "$hook" | base64 -d > "$work/hook.sh"
  sh -n "$work/hook.sh" 2>"$work/hook.err" || error "post-upgrade-hook.sh tiene errores de sintaxis: $(cat "$work/hook.err")"
fi

if [ "$errors" -gt 0 ]; then
  echo "Validación fallida: $errors error(es) en $MANIFESTS"
  exit 1
fi
echo "Validación OK: $MANIFESTS (Ubuntu $target, kernel $kernel)"
