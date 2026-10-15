#!/usr/bin/env bats
# Kustomize render and validation against the real Rancher CRD (manifests/schemas/lab).

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

# Edits the documents that match the filter.
edit() { "$YQ" -i "$1" "$M"; }

@test "render lab: valid" {
  run sh "$VALIDATE" "$M" "$SCHEMA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Validation OK"*"6.8.0-139-generic"* ]]
}

@test "render lab: the Plans reference the generated hashed Secret and ConfigMap" {
  secret=$("$YQ" 'select(.kind == "Secret") | .metadata.name' "$M")
  cm=$("$YQ" 'select(.kind == "ConfigMap") | .metadata.name' "$M")
  [[ "$secret" == os-upgrade-script-* ]]
  [[ "$cm" == os-upgrade-config-* ]]
  [ "$("$YQ" ea '[select(.kind == "Plan") | .spec.secrets[0].name] | unique | .[]' "$M")" = "$secret" ]
  [ "$("$YQ" ea '[select(.kind == "Plan") | .spec.upgrade.envFrom[0].configMapRef.name] | unique | .[]' "$M")" = "$cm" ]
}

@test "render lab: the Secret contains the current upgrade.sh" {
  "$YQ" 'select(.kind == "Secret") | .data["upgrade.sh"]' "$M" | base64 -d > "$BATS_TEST_TMPDIR/u.sh"
  cmp "$BATS_TEST_TMPDIR/u.sh" "$REPO/scripts/upgrade.sh"
}

@test "render lab: prepare before the drain and only in the upgrade Plans" {
  [ "$("$YQ" 'select(.metadata.name == "os-upgrade-workers") | .spec.prepare.args[2]' "$M")" = prepare ]
  [ "$("$YQ" 'select(.metadata.name == "os-upgrade-cp") | .spec.prepare.securityContext.privileged' "$M")" = true ]
  [ "$("$YQ" 'select(.metadata.name == "os-upgrade-predownload") | .spec.drain' "$M")" = null ]
  [ "$("$YQ" 'select(.metadata.name == "os-upgrade-predownload") | .spec.prepare' "$M")" = null ]
}

@test "validation: postCompleteLabels is rejected" {
  edit '(select(.kind == "Plan") | .spec.postCompleteLabels) = {"os-upgrade": "done"}'
  run sh "$VALIDATE" "$M" "$SCHEMA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"postCompleteLabels"* ]]
}

@test "validation: drain.timeout is rejected" {
  edit '(select(.metadata.name == "os-upgrade-cp") | .spec.drain.timeout) = 1800000000000'
  run sh "$VALIDATE" "$M" "$SCHEMA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"os-upgrade-cp: spec.drain.timeout is forbidden"* ]]
}

@test "validation: a field the CRD does not know is rejected" {
  edit '(select(.metadata.name == "os-upgrade-workers") | .spec.upgrade.madeUpField) = true'
  run sh "$VALIDATE" "$M" "$SCHEMA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"madeUpField"* ]]
}

@test "validation: a wrong type according to the CRD is rejected" {
  edit '(select(.metadata.name == "os-upgrade-workers") | .spec.concurrency) = "1"'
  run sh "$VALIDATE" "$M" "$SCHEMA"
  [ "$status" -eq 1 ]
}

@test "validation: empty KERNEL_VERSION is rejected" {
  edit '(select(.kind == "ConfigMap") | .data.KERNEL_VERSION) = ""'
  run sh "$VALIDATE" "$M" "$SCHEMA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"KERNEL_VERSION is not set"* ]]
}

@test "validation: KERNEL_VERSION with an invalid format is rejected" {
  edit '(select(.kind == "ConfigMap") | .data.KERNEL_VERSION) = "6.8-0-139-generic"'
  run sh "$VALIDATE" "$M" "$SCHEMA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid KERNEL_VERSION"* ]]
}

@test "validation: an image without a tag is rejected" {
  edit '(select(.metadata.name == "os-upgrade-cp") | .spec.upgrade.image) = "registry.local:5000/ubuntu"'
  run sh "$VALIDATE" "$M" "$SCHEMA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"image without an explicit tag: registry.local:5000/ubuntu"* ]]
}

@test "validation: concurrency other than 1 with drain is rejected" {
  edit '(select(.metadata.name == "os-upgrade-workers") | .spec.concurrency) = 2'
  run sh "$VALIDATE" "$M" "$SCHEMA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"os-upgrade-workers: Plans with drain must have concurrency: 1"* ]]
}

@test "validation: jobActiveDeadlineSecs out of range is rejected" {
  edit '(select(.metadata.name == "os-upgrade-cp") | .spec.jobActiveDeadlineSecs) = 100'
  run sh "$VALIDATE" "$M" "$SCHEMA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"os-upgrade-cp: jobActiveDeadlineSecs"* ]]
}

@test "validation: a proxy without a scheme is rejected" {
  edit '(select(.kind == "ConfigMap") | .data.HTTP_PROXY) = "proxy:3128"'
  run sh "$VALIDATE" "$M" "$SCHEMA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"HTTP_PROXY must start with http://"* ]]
}

@test "validation: different namespaces are rejected" {
  edit '(select(.metadata.name == "os-upgrade-cp") | .metadata.namespace) = "otro"'
  run sh "$VALIDATE" "$M" "$SCHEMA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be in the same namespace"* ]]
}

@test "validation: without the cluster CRD it explains how to export it" {
  run sh "$VALIDATE" "$M" "$BATS_TEST_TMPDIR/no-existe"
  [ "$status" -eq 2 ]
  [[ "$output" == *"kubectl get crd plans.upgrade.cattle.io -o json"* ]]
}

# Temporary overlay inside the repo (kustomize does not accept absolute paths to the base).
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

@test "hook: the overlay adds it to the Secret next to upgrade.sh and it validates" {
  make_overlay_with_hook "$REPO/docs/examples/post-upgrade-hook.sh"
  [ "$("$YQ" 'select(.kind == "Secret") | .data | keys | join(",")' "$M")" = "post-upgrade-hook.sh,upgrade.sh" ]
  "$YQ" 'select(.kind == "Secret") | .data["post-upgrade-hook.sh"]' "$M" | base64 -d | cmp - "$REPO/docs/examples/post-upgrade-hook.sh"
  run sh "$VALIDATE" "$M" "$SCHEMA"
  [ "$status" -eq 0 ]
}

@test "hook: a syntax error is caught by the validation" {
  printf 'if true; then\necho x\n' > "$BATS_TEST_TMPDIR/bad.sh"
  make_overlay_with_hook "$BATS_TEST_TMPDIR/bad.sh"
  run sh "$VALIDATE" "$M" "$SCHEMA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"post-upgrade-hook.sh has syntax errors"* ]]
}

@test "validation: ALLOW_THIRD_PARTY and POST_UPGRADE_HOOK_RETRIES" {
  [ "$("$YQ" 'select(.kind == "ConfigMap") | .data.ALLOW_THIRD_PARTY' "$M")" = true ]
  edit '(select(.kind == "ConfigMap") | .data.ALLOW_THIRD_PARTY) = "yes"'
  edit '(select(.kind == "ConfigMap") | .data.POST_UPGRADE_HOOK_RETRIES) = "x"'
  run sh "$VALIDATE" "$M" "$SCHEMA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ALLOW_THIRD_PARTY must be true or false"* ]]
  [[ "$output" == *"POST_UPGRADE_HOOK_RETRIES must be an integer"* ]]
}

@test "validation: an unsupported TARGET_VERSION is rejected" {
  edit '(select(.kind == "ConfigMap") | .data.TARGET_VERSION) = "25.10"'
  edit '(select(.kind == "Plan") | .spec.version) = "25.10"'
  run sh "$VALIDATE" "$M" "$SCHEMA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TARGET_VERSION '25.10' not supported (supported: 24.04 26.04 )"* ]]
}

@test "validation: the Plans spec.version must match TARGET_VERSION" {
  edit '(select(.kind == "ConfigMap") | .data.TARGET_VERSION) = "26.04"'
  run sh "$VALIDATE" "$M" "$SCHEMA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"os-upgrade-cp: spec.version does not match TARGET_VERSION (26.04)"*"components/target-version"* ]]
}

@test "render: an overlay with TARGET_VERSION=26.04 sets 26.04 on the Plans and validates" {
  OVL="$REPO/manifests/overlays/.bats-2604-$$"
  mkdir -p "$OVL"
  printf 'TARGET_VERSION=26.04\nKERNEL_VERSION=7.0.0-38-generic\n' > "$OVL/config.env"
  cp "$REPO/manifests/overlays/lab/kustomization.yaml" "$OVL/"
  "$REPO/tools/bin/kustomize" build --load-restrictor LoadRestrictionsNone "$OVL" > "$M"
  rm -rf "$OVL"
  [ "$("$YQ" ea '[select(.kind == "Plan") | .spec.version] | unique | .[]' "$M")" = "26.04" ]
  run sh "$VALIDATE" "$M" "$SCHEMA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Ubuntu 26.04, kernel 7.0.0-38-generic"* ]]
}
