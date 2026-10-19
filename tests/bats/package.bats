#!/usr/bin/env bats
# Release tarball (tools/dist.sh) and the os-upgrade entry point, run from the unpacked
# tarball through a symlink, as it is installed in production.

load k8s_helpers

setup_file() {
  sh "$REPO/tools/dist.sh" 9.9.9 "$BATS_FILE_TMPDIR/dist" >/dev/null
  tar -xzf "$BATS_FILE_TMPDIR/dist/os-upgrade-9.9.9-linux-amd64.tar.gz" -C "$BATS_FILE_TMPDIR"
}

setup() {
  PKG="$BATS_FILE_TMPDIR/os-upgrade-9.9.9-linux-amd64"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  ln -s "$PKG/bin/os-upgrade" "$BATS_TEST_TMPDIR/bin/os-upgrade"
  OSU="$BATS_TEST_TMPDIR/bin/os-upgrade"
  cd "$BATS_TEST_TMPDIR"
}

# Minimal kubectl for the commands that only need a context, the CRD and apply.
fake_kubectl() {
  cat > "$BATS_TEST_TMPDIR/bin/kubectl" <<EOF
#!/bin/sh
echo "\$*" >> "$BATS_TEST_TMPDIR/kubectl.log"
case "\$*" in
  "config current-context") echo my-cluster ;;
  "get crd plans.upgrade.cattle.io -o json") cat "$REPO/manifests/schemas/lab/crd-plans.json" ;;
  apply*) echo applied ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"
  export KUBECTL="$BATS_TEST_TMPDIR/bin/kubectl"
}

@test "dist: checksum and contents, without tests, lab or dev tools" {
  run sh -c "cd '$BATS_FILE_TMPDIR/dist' && sha256sum -c os-upgrade-9.9.9-linux-amd64.tar.gz.sha256"
  [ "$status" -eq 0 ]
  [ -x "$PKG/bin/os-upgrade" ]
  for f in scripts/upgrade.sh scripts/rollout.sh scripts/lib/k8s.sh manifests/base/kustomization.yaml \
      manifests/components/target-version/kustomization.yaml manifests/overlays/lab/kustomization.yaml \
      tools/bin/yq tools/bin/kustomize tools/bin/kubeconform docs/runbook.md README.md; do
    [ -e "$PKG/$f" ] || { echo "missing $f"; return 1; }
  done
  for f in tests lab tools/bin/bats tools/bin/shellcheck tools/bin/kubectl manifests/schemas Makefile; do
    [ ! -e "$PKG/$f" ] || { echo "unexpected $f"; return 1; }
  done
}

@test "dist: without a version fails" {
  run sh "$REPO/tools/dist.sh"
  [ "$status" -eq 2 ]
}

@test "version: the one of the tarball" {
  run "$OSU" version
  [ "$status" -eq 0 ]
  [ "$output" = "9.9.9" ]
}

@test "help and unknown commands" {
  run "$OSU" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"os-upgrade init <dir>"* ]]
  run "$OSU" frobnicate
  [ "$status" -eq 2 ]
  [[ "$output" == *"Unknown command: frobnicate"* ]]
}

@test "init: requires --kernel and does not overwrite" {
  run "$OSU" init c1
  [ "$status" -eq 1 ]
  [[ "$output" == *"--kernel is required"* ]]
  [ ! -e c1 ]

  run "$OSU" init c1 --kernel 7.0.0-38-generic --target 26.04
  [ "$status" -eq 0 ]
  grep -qx 'KERNEL_VERSION=7.0.0-38-generic' c1/config.env
  grep -qx 'TARGET_VERSION=26.04' c1/config.env
  grep -q -- '- ../../components/target-version' c1/kustomization.yaml

  run "$OSU" init c1 --kernel 7.0.0-38-generic
  [ "$status" -eq 1 ]
  [[ "$output" == *"already exists"* ]]
}

@test "render: same manifests as the repo overlay, from any directory" {
  cp -R "$REPO/manifests/overlays/lab" lab
  "$REPO/tools/bin/kustomize" build --load-restrictor LoadRestrictionsNone \
    "$REPO/manifests/overlays/lab" > expected.yaml
  mkdir elsewhere && cd elsewhere
  run "$OSU" render ../lab
  [ "$status" -eq 0 ]
  head -1 ../lab/manifests.yaml | grep -q '^# Rendered by os-upgrade 9.9.9 from '
  tail -n +2 ../lab/manifests.yaml | diff - ../expected.yaml

  run "$OSU" render ../lab -o -
  [ "$status" -eq 0 ]
  [[ "$output" == *"kind: Plan"* ]]
}

@test "render: a directory without kustomization.yaml fails" {
  mkdir empty
  run "$OSU" render empty
  [ "$status" -eq 1 ]
  [[ "$output" == *"empty/kustomization.yaml does not exist"* ]]
  run "$OSU" render
  [ "$status" -eq 2 ]
}

@test "init + export-crd + validate: OK; a wrong value fails validation" {
  fake_kubectl
  "$OSU" init c1 --kernel 6.8.0-139-generic >/dev/null
  run "$OSU" export-crd c1
  [ "$status" -eq 0 ]
  [[ "$output" == *"context 'my-cluster'"* ]]
  run "$OSU" validate c1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Validation OK"*"Ubuntu 24.04, kernel 6.8.0-139-generic"* ]]

  echo 'SINGLE_REBOOT=maybe' >> c1/config.env
  run "$OSU" validate c1
  [ "$status" -eq 1 ]
  [[ "$output" == *"SINGLE_REBOOT must be true or false"* ]]
}

@test "validate: without the exported CRD it says how to get it" {
  "$OSU" init c1 --kernel 6.8.0-139-generic >/dev/null
  run "$OSU" validate c1
  [ "$status" -eq 2 ]
  [[ "$output" == *"crd-plans.json does not exist"* ]]
}

@test "apply: asks for the context and applies nothing without a yes" {
  fake_kubectl
  "$OSU" init c1 --kernel 6.8.0-139-generic >/dev/null
  "$OSU" export-crd c1 >/dev/null
  echo n > answers
  CONFIRM_TTY=answers run "$OSU" apply c1
  [ "$status" -eq 1 ]
  [[ "$output" == *'to context "my-cluster"?'*"aborted, nothing applied"* ]]
  run grep -q '^apply' kubectl.log
  [ "$status" -ne 0 ]

  echo y > answers
  CONFIRM_TTY=answers run "$OSU" apply c1
  [ "$status" -eq 0 ]
  grep -qx "apply -f $BATS_TEST_TMPDIR/c1/manifests.yaml" kubectl.log
}

@test "rollout and preflight from the package use its yq" {
  setup_cluster
  unset YQ
  run "$OSU" rollout status --nodes w1
  [ "$status" -eq 0 ]
  [[ "$output" == *"w1"* ]]
  run "$OSU" preflight --nodes w1
  [[ "$output" != *"not found"* ]]
}
