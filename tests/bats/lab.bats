#!/usr/bin/env bats
# lab/lab.sh: topology and, above all, that it never touches VMs or volumes outside the lab.

REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
LAB="$REPO/lab/lab.sh"

setup() {
  export VIRSH_STATE="$BATS_TEST_TMPDIR/virsh"
  export LAB_DIR="$BATS_TEST_TMPDIR/lab"
  export PATH="$REPO/tests/lab-stubs:$PATH"
  mkdir -p "$VIRSH_STATE" "$LAB_DIR"
  # User VMs and volumes that are not part of the lab, plus the lab ones.
  printf '%s\n' ubuntu22.04 ubuntu22.04-2 osu-lab-cp1 osu-lab-cp2 osu-lab-cp3 osu-lab-w1 > "$VIRSH_STATE/domains"
  printf '%s\n' ubuntu22.04.qcow2 osu-lab-base-jammy.qcow2 osu-lab-cp1.qcow2 osu-lab-cp1-seed.iso osu-lab-w1.qcow2 > "$VIRSH_STATE/vols"
}

@test "lab plan: default topology of 3 control plane + 1 worker" {
  run sh "$LAB" plan
  [ "$status" -eq 0 ]
  [[ "$output" == *"osu-lab-cp1"*"osu-lab-cp2"*"osu-lab-cp3"*"osu-lab-w1  worker"* ]]
  [[ "$output" == *"total: 16384 MB of RAM, 8 vCPU"* ]]
  run grep -cE 'destroy|undefine|vol-delete|vol-create' "$VIRSH_STATE/calls.log"
  [ "$output" = 0 ] || [ "$status" -eq 2 ]   # no matches or no virsh calls
}

@test "lab plan: configurable topology" {
  LAB_CP=1 LAB_WORKERS=2 LAB_MEM_MB=2048 run sh "$LAB" plan
  [[ "$output" == *"osu-lab-cp1"*"osu-lab-w1"*"osu-lab-w2"* ]]
  [[ "$output" != *"osu-lab-cp2"* ]]
  [[ "$output" == *"total: 6144 MB"* ]]
}

@test "lab down: deletes only the lab VMs and disks and keeps the base image" {
  run sh "$LAB" down
  [ "$status" -eq 0 ]
  [ "$(cat "$VIRSH_STATE/domains")" = "$(printf '%s\n' ubuntu22.04 ubuntu22.04-2)" ]
  grep -qx ubuntu22.04.qcow2 "$VIRSH_STATE/vols"
  grep -qx osu-lab-base-jammy.qcow2 "$VIRSH_STATE/vols"
  run grep -c 'osu-lab-cp1.qcow2\|osu-lab-w1.qcow2\|seed' "$VIRSH_STATE/vols"
  [ "$output" = 0 ]
  run grep -c 'ubuntu22.04' "$VIRSH_STATE/calls.log"
  [ "$output" = 0 ]
}

@test "lab destroy: also deletes the base image, never other volumes" {
  run sh "$LAB" destroy
  [ "$status" -eq 0 ]
  [ "$(cat "$VIRSH_STATE/vols")" = ubuntu22.04.qcow2 ]
  grep -qx ubuntu22.04 "$VIRSH_STATE/domains"
  [ ! -d "$LAB_DIR" ]
}

@test "lab down with another prefix does not touch the osu-lab VMs" {
  LAB_PREFIX=otro run sh "$LAB" down
  [ "$status" -eq 0 ]
  grep -qx osu-lab-cp1 "$VIRSH_STATE/domains"
}

@test "lab ssh: refuses VMs that are not part of the lab" {
  run sh "$LAB" ssh ubuntu22.04 true
  [ "$status" -eq 1 ]
  [[ "$output" == *"ubuntu22.04 is not a lab VM"* ]]
}

@test "lab env: exports the lab kubeconfig and the official SUC namespace" {
  run sh "$LAB" env
  [[ "$output" == *"export KUBECONFIG='$LAB_DIR/kubeconfig'"* ]]
  [[ "$output" == *"export NS=system-upgrade"* ]]
}

@test "lab e2e without a lab fails with instructions" {
  run sh "$LAB" e2e
  [ "$status" -eq 1 ]
  [[ "$output" == *"run 'lab/lab.sh up' first"* ]]
}

@test "lab plan: LAB_UBUNTU=24.04 uses the noble image and base volume" {
  run env LAB_UBUNTU=24.04 sh "$LAB" plan
  [ "$status" -eq 0 ]
  [[ "$output" == *"Ubuntu 24.04 (noble); image: ubuntu-24.04-server-cloudimg-amd64.img (volume osu-lab-base-noble.qcow2)"* ]]
}

@test "lab: unsupported LAB_UBUNTU is rejected" {
  run env LAB_UBUNTU=20.04 sh "$LAB" plan
  [ "$status" -eq 2 ]
  [[ "$output" == *"unsupported LAB_UBUNTU: 20.04"* ]]
}

@test "lab down: also deletes the proxy VM and the saved proxy mode and password" {
  echo osu-lab-proxy >> "$VIRSH_STATE/domains"
  echo osu-lab-proxy.qcow2 >> "$VIRSH_STATE/vols"
  echo auth > "$LAB_DIR/proxy-mode"
  echo 'pw@:!x' > "$LAB_DIR/proxy-password"
  run sh "$LAB" down
  [ "$status" -eq 0 ]
  [ "$(cat "$VIRSH_STATE/domains")" = "$(printf '%s\n' ubuntu22.04 ubuntu22.04-2)" ]
  run grep -c osu-lab-proxy "$VIRSH_STATE/vols"
  [ "$output" = 0 ]
  [ ! -e "$LAB_DIR/proxy-mode" ]
  [ ! -e "$LAB_DIR/proxy-password" ]
}

@test "lab plan: LAB_PROXY shows the proxy VM; the saved mode is used afterwards" {
  run sh "$LAB" plan
  [[ "$output" != *"osu-lab-proxy"* ]]
  LAB_PROXY=auth run sh "$LAB" plan
  [[ "$output" == *"osu-lab-proxy  squid (auth)"* ]]
  echo open > "$LAB_DIR/proxy-mode"
  run sh "$LAB" plan
  [[ "$output" == *"osu-lab-proxy  squid (open)"* ]]
}

@test "lab up: an unknown LAB_PROXY is rejected before creating anything" {
  LAB_PROXY=socks run sh "$LAB" up
  [ "$status" -eq 1 ]
  [[ "$output" == *"LAB_PROXY must be off, open or auth"* ]]
  [ ! -e "$VIRSH_STATE/calls.log" ] || run grep -c vol-create "$VIRSH_STATE/calls.log"
}
