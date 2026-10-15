#!/usr/bin/env bats
# preflight.sh, check-cluster.sh y las comprobaciones de etcd (lib/checks.sh).

load k8s_helpers

setup() {
  setup_cluster
}

@test "preflight: cluster sano pasa" {
  run sh "$PREFLIGHT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[OK]    etcd sano: 3 miembros, 1 líder, diferencia de RAFT INDEX 1"* ]]
  [[ "$output" == *"0 fallo(s)"* ]]
  # Solo lectura.
  not_called "label "
  not_called "delete"
  not_called "uncordon"
}

@test "preflight: etcdctl se ejecuta sin shell y con el selector component=etcd" {
  run sh "$PREFLIGHT"
  called "kubectl -n kube-system get pods -l component=etcd -o json"
  called "exec etcd-cp1 -- etcdctl --cacert"
  not_called "sh -c"
}

@test "preflight: tabla de etcd 3.6 (otras columnas) se interpreta igual" {
  touch "$K8S/etcd36"
  run sh "$PREFLIGHT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"etcd sano: 3 miembros, 1 líder"* ]]
}

@test "preflight: miembro de etcd no sano" {
  set_etcd 2 6 false
  run sh "$PREFLIGHT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FALLO] etcd: miembros que no responden o no sanos (2/3 sanos) https://10.0.0.2:2379"* ]]
}

@test "preflight: dos líderes" {
  set_etcd 2 3 true
  run sh "$PREFLIGHT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"2 líderes (debe haber 1)"* ]]
}

@test "preflight: RAFT INDEX desigualado" {
  set_etcd 3 4 5000
  run sh "$PREFLIGHT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"RAFT INDEX desigualado (diferencia 4000 > 100)"* ]]
}

@test "preflight: menos de 3 miembros" {
  sed -i 3d "$K8S/etcd.tsv"
  run sh "$PREFLIGHT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"etcd: 2 miembros (mínimo 3)"* ]]
}

@test "preflight: alarma de etcd activa" {
  echo "memberID:123 alarm:NOSPACE" > "$K8S/etcd-alarms"
  run sh "$PREFLIGHT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"alarmas activas: memberID:123 alarm:NOSPACE"* ]]
}

@test "preflight: snapshot antiguo falla y sin CRD de snapshots solo avisa" {
  snapshot_age_hours 30
  run sh "$PREFLIGHT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"el último snapshot de etcd tiene 30 h"* ]]
  rm "$K8S/snapshots.json"
  run sh "$PREFLIGHT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[AVISO] no se pudo consultar etcdsnapshotfiles"* ]]
}

@test "preflight: poco disco en un nodo del grupo" {
  echo '{"node":{"fs":{"availableBytes":1048576000}}}' > "$K8S/stats/w2.json"
  run sh "$PREFLIGHT" --group 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FALLO] w2: 1000 MB libres en / (mínimo 5000)"* ]]
  [[ "$output" == *"[OK]    w1:"* ]]
  [[ "$output" != *"cp1: "*"MB libres"* ]]
}

@test "preflight: PDB bloqueado es un aviso" {
  echo '{"items":[{"metadata":{"namespace":"app","name":"web"},"status":{"disruptionsAllowed":0}}]}' > "$K8S/pdb.json"
  run sh "$PREFLIGHT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[AVISO] PDBs sin interrupciones permitidas"*"app/web"* ]]
}

@test "preflight: Plans de os-upgrade no aplicados" {
  echo '{"items":[]}' > "$K8S/plans.json"
  run sh "$PREFLIGHT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"faltan Plans: os-upgrade-predownload os-upgrade-workers os-upgrade-cp"* ]]
}

@test "preflight: sin acceso a la API para enseguida" {
  touch "$K8S/api-down"
  run sh "$PREFLIGHT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no se puede acceder a la API"* ]]
  not_called "etcdctl"
}

@test "check-cluster: muestra etcd sin shell y da veredicto" {
  run sh "$CHECK_CLUSTER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"=== etcd"*"ENDPOINT"* ]]
  [[ "$output" == *"Alarmas: ninguna"* ]]
  [[ "$output" == *"=== Veredicto"*"[OK]    etcd sano"* ]]
  not_called "sh -c"
}

@test "check-cluster: etcd degradado sale con 1" {
  set_etcd 1 6 false
  run sh "$CHECK_CLUSTER"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FALLO] etcd"* ]]
}
