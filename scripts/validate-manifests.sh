#!/bin/sh
# Validates the manifests rendered for a cluster, without contacting the cluster:
#   1. Schema: the Plans against the cluster's real CRD in strict mode (a field the CRD does
#      not know, such as postCompleteLabels, fails just like on the API server).
#   2. Own rules: what the schema accepts but breaks the controller or the process.
#
# Usage: validate-manifests.sh <manifests.yaml> <cluster-schema-dir>
#   <cluster-schema-dir> contains crd-plans.json, exported with:
#   kubectl get crd plans.upgrade.cattle.io -o json > manifests/schemas/<cluster>/crd-plans.json
set -eu

TOOLS_BIN="${TOOLS_BIN:-$(cd "$(dirname "$0")/../tools/bin" && pwd)}"
YQ="$TOOLS_BIN/yq"
KUBECONFORM="$TOOLS_BIN/kubeconform"

[ $# -eq 2 ] || { echo "Usage: $0 <manifests.yaml> <cluster-schema-dir>" >&2; exit 2; }
MANIFESTS=$1
SCHEMA_DIR=$2
CRD="$SCHEMA_DIR/crd-plans.json"

[ -f "$MANIFESTS" ] || { echo "$MANIFESTS does not exist" >&2; exit 2; }
[ -f "$CRD" ] || {
  echo "$CRD does not exist. Export it from the cluster with:" >&2
  echo "  kubectl get crd plans.upgrade.cattle.io -o json > $CRD" >&2
  exit 2
}

errors=0
error() { echo "ERROR: $*"; errors=$((errors + 1)); }

# ------------------------------------------------------------------ 1. CRD schema
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# openAPIV3Schema -> strict JSON Schema: no unknown properties, and nullable honoured.
# Careful: with yq you must use "|= (.field = value)"; "(..|select()).field = value" leaves
# null in nested objects.
# The CRD schema does not declare apiVersion/kind/metadata (the API server validates them).
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
  error "the Plans do not match the schema of the CRD installed in the cluster"
fi

# ------------------------------------------------------------------ 2. own rules
plans() { "$YQ" ea "[.] | map(select(.kind == \"Plan\")) | $1" "$MANIFESTS"; }

[ "$(plans 'length')" -eq 3 ] || error "expected 3 Plans (predownload, workers, cp)"

for name in $(plans '.[] | select(.spec.postCompleteLabels != null) | .metadata.name'); do
  error "$name: spec.postCompleteLabels does not exist in the Rancher CRD and the API server rejects it"
done

for name in $(plans '.[] | select(.spec.drain.timeout != null) | .metadata.name'); do
  error "$name: spec.drain.timeout is forbidden (in SUC v0.16 it is nanoseconds in an int32 and breaks the controller)"
done

for name in $(plans '.[] | select(.metadata.name | test("^system-agent-upgrader")) | .metadata.name'); do
  error "$name: Rancher's Plans are not managed here"
done

for name in $(plans '.[] | select(.spec.drain != null and .spec.concurrency != 1) | .metadata.name'); do
  error "$name: Plans with drain must have concurrency: 1"
done

for name in $(plans '.[] | select(.spec.jobActiveDeadlineSecs == null or .spec.jobActiveDeadlineSecs < 600 or .spec.jobActiveDeadlineSecs > 86400) | .metadata.name'); do
  error "$name: jobActiveDeadlineSecs must be between 600 and 86400"
done

for img in $(plans '.[] | (.spec.upgrade.image, .spec.prepare.image) | select(. != null)' | sort -u); do
  case "$img" in
    *@sha256:*) ;;
    *) echo "$img" | grep -Eq ':[^/]+$' || error "image without an explicit tag: $img" ;;
  esac
done

ns_count=$("$YQ" ea '[.] | map(select(.kind == "Plan" or .metadata.name | test("^os-upgrade-")) | .metadata.namespace) | unique | length' "$MANIFESTS")
[ "$ns_count" -eq 1 ] || error "Plans, Secret and ConfigMap must be in the same namespace"

# Configuration (ConfigMap os-upgrade-config).
cfg() { "$YQ" ea "[.] | map(select(.kind == \"ConfigMap\" and (.metadata.name | test(\"^os-upgrade-config\")))) | .[0].data.$1 // \"\"" "$MANIFESTS"; }

kernel=$(cfg KERNEL_VERSION)
if [ -z "$kernel" ]; then
  error "KERNEL_VERSION is not set in the overlay config.env"
elif ! echo "$kernel" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-generic$'; then
  error "invalid KERNEL_VERSION: '$kernel' (expected format: 6.8.0-139-generic)"
fi
# Supported targets: the ones in the TRANSITIONS table of upgrade.sh (single source).
supported=$(awk -F'|' '/^TRANSITIONS="/ {f = 1; next} f && /^"/ {f = 0} f && NF {print $2}' \
  "$(dirname "$0")/upgrade.sh" | tr '\n' ' ')
target=$(cfg TARGET_VERSION)
case " $supported " in
  *" $target "*) ;;
  *) error "TARGET_VERSION '$target' not supported (supported: $supported)" ;;
esac
for name in $(plans ".[] | select(.spec.version != \"$target\") | .metadata.name"); do
  error "$name: spec.version does not match TARGET_VERSION ($target); does the overlay include components/target-version?"
done

for key in SINGLE_REBOOT REQUIRE_PREDOWNLOAD ALLOW_THIRD_PARTY; do
  case "$(cfg "$key")" in true|false) ;; *) error "$key must be true or false" ;; esac
done
for key in MIN_FREE_ROOT_MB MIN_FREE_BOOT_MB MAX_REBOOTS POST_UPGRADE_HOOK_RETRIES; do
  case "$(cfg "$key")" in ''|*[!0-9]*) error "$key must be an integer" ;; esac
done
for key in HTTP_PROXY HTTPS_PROXY APT_MIRROR; do
  val=$(cfg "$key")
  case "$val" in
    ''|http://*|https://*) ;;
    *) error "$key must start with http:// or https:// (value: '$val')" ;;
  esac
done

# Optional post-upgrade hook (post-upgrade-hook.sh key of the Secret): sh syntax.
hook=$("$YQ" ea '[.] | map(select(.kind == "Secret" and (.metadata.name | test("^os-upgrade-script")))) | .[0].data["post-upgrade-hook.sh"] // ""' "$MANIFESTS")
if [ -n "$hook" ]; then
  echo "$hook" | base64 -d > "$work/hook.sh"
  sh -n "$work/hook.sh" 2>"$work/hook.err" || error "post-upgrade-hook.sh has syntax errors: $(cat "$work/hook.err")"
fi

if [ "$errors" -gt 0 ]; then
  echo "Validation failed: $errors error(s) in $MANIFESTS"
  exit 1
fi
echo "Validation OK: $MANIFESTS (Ubuntu $target, kernel $kernel)"
