#!/usr/bin/env bats
# lab/lab.sh: topología y, sobre todo, que nunca toque VMs ni volúmenes ajenos al lab.

REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
LAB="$REPO/lab/lab.sh"

setup() {
  export VIRSH_STATE="$BATS_TEST_TMPDIR/virsh"
  export LAB_DIR="$BATS_TEST_TMPDIR/lab"
  export PATH="$REPO/tests/lab-stubs:$PATH"
  mkdir -p "$VIRSH_STATE" "$LAB_DIR"
  # VMs y volúmenes del usuario que no son del lab, más los del lab.
  printf '%s\n' ubuntu22.04 ubuntu22.04-2 osu-lab-cp1 osu-lab-cp2 osu-lab-cp3 osu-lab-w1 > "$VIRSH_STATE/domains"
  printf '%s\n' ubuntu22.04.qcow2 osu-lab-base-jammy.qcow2 osu-lab-cp1.qcow2 osu-lab-cp1-seed.iso osu-lab-w1.qcow2 > "$VIRSH_STATE/vols"
}

@test "lab plan: topología por defecto 3 control plane + 1 worker" {
  run sh "$LAB" plan
  [ "$status" -eq 0 ]
  [[ "$output" == *"osu-lab-cp1"*"osu-lab-cp2"*"osu-lab-cp3"*"osu-lab-w1  worker"* ]]
  [[ "$output" == *"total: 16384 MB de RAM, 8 vCPU"* ]]
  run grep -cE 'destroy|undefine|vol-delete|vol-create' "$VIRSH_STATE/calls.log"
  [ "$output" = 0 ] || [ "$status" -eq 2 ]   # sin coincidencias o sin llamadas a virsh
}

@test "lab plan: topología configurable" {
  LAB_CP=1 LAB_WORKERS=2 LAB_MEM_MB=2048 run sh "$LAB" plan
  [[ "$output" == *"osu-lab-cp1"*"osu-lab-w1"*"osu-lab-w2"* ]]
  [[ "$output" != *"osu-lab-cp2"* ]]
  [[ "$output" == *"total: 6144 MB"* ]]
}

@test "lab down: borra solo las VMs y discos del lab y conserva la imagen base" {
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

@test "lab destroy: también borra la imagen base, nunca volúmenes ajenos" {
  run sh "$LAB" destroy
  [ "$status" -eq 0 ]
  [ "$(cat "$VIRSH_STATE/vols")" = ubuntu22.04.qcow2 ]
  grep -qx ubuntu22.04 "$VIRSH_STATE/domains"
  [ ! -d "$LAB_DIR" ]
}

@test "lab down con otro prefijo no toca las VMs osu-lab" {
  LAB_PREFIX=otro run sh "$LAB" down
  [ "$status" -eq 0 ]
  grep -qx osu-lab-cp1 "$VIRSH_STATE/domains"
}

@test "lab ssh: rechaza VMs que no son del lab" {
  run sh "$LAB" ssh ubuntu22.04 true
  [ "$status" -eq 1 ]
  [[ "$output" == *"ubuntu22.04 no es una VM del lab"* ]]
}

@test "lab env: exporta kubeconfig del lab y el namespace del SUC oficial" {
  run sh "$LAB" env
  [[ "$output" == *"export KUBECONFIG='$LAB_DIR/kubeconfig'"* ]]
  [[ "$output" == *"export NS=system-upgrade"* ]]
}

@test "lab e2e sin lab creado falla con instrucciones" {
  run sh "$LAB" e2e
  [ "$status" -eq 1 ]
  [[ "$output" == *"ejecutar antes 'lab/lab.sh up'"* ]]
}
