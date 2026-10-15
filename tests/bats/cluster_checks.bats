#!/usr/bin/env bats
# preflight.sh, check-cluster.sh and the etcd checks (lib/checks.sh).

load k8s_helpers

setup() {
  setup_cluster
}

@test "preflight: a healthy cluster passes" {
  run sh "$PREFLIGHT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[OK]    etcd healthy: 3 members, 1 leader, RAFT INDEX difference 1"* ]]
  [[ "$output" == *"=== Result: 0 failure(s), 0 warning(s)"* ]]
  # Read-only.
  not_called "label "
  not_called "delete"
  not_called "uncordon"
}

@test "preflight: etcdctl runs without a shell and with the component=etcd selector" {
  run sh "$PREFLIGHT"
  called "kubectl -n kube-system get pods -l component=etcd -o json"
  called "exec etcd-cp1 -- etcdctl --cacert"
  not_called "sh -c"
}

@test "preflight: an etcd 3.6 table (other columns) is parsed the same way" {
  touch "$K8S/etcd36"
  run sh "$PREFLIGHT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"etcd healthy: 3 members, 1 leader"* ]]
}

@test "preflight: unhealthy etcd member" {
  set_etcd 2 6 false
  run sh "$PREFLIGHT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL]  etcd: members not responding or unhealthy (2/3 healthy) https://10.0.0.2:2379"* ]]
}

@test "preflight: two leaders" {
  set_etcd 2 3 true
  run sh "$PREFLIGHT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"2 leaders (there must be 1)"* ]]
}

@test "preflight: RAFT INDEX out of sync" {
  set_etcd 3 4 5000
  run sh "$PREFLIGHT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"RAFT INDEX out of sync (difference 4000 > 100)"* ]]
}

@test "preflight: fewer than 3 members" {
  sed -i 3d "$K8S/etcd.tsv"
  run sh "$PREFLIGHT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"etcd: 2 members (minimum 3)"* ]]
}

@test "preflight: active etcd alarm" {
  echo "memberID:123 alarm:NOSPACE" > "$K8S/etcd-alarms"
  run sh "$PREFLIGHT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"active alarms: memberID:123 alarm:NOSPACE"* ]]
}

@test "preflight: an old snapshot fails and without the snapshots CRD it only warns" {
  snapshot_age_hours 30
  run sh "$PREFLIGHT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"the latest etcd snapshot is 30 h old"* ]]
  rm "$K8S/snapshots.json"
  run sh "$PREFLIGHT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[WARN]  could not query etcdsnapshotfiles"* ]]
}

@test "preflight: low disk on a node of the group" {
  echo '{"node":{"fs":{"availableBytes":1048576000}}}' > "$K8S/stats/w2.json"
  run sh "$PREFLIGHT" --group 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL]  w2: 1000 MB free on / (minimum 5000)"* ]]
  [[ "$output" == *"[OK]    w1:"* ]]
  [[ "$output" != *"cp1: "*"MB libres"* ]]
}

@test "preflight: a blocked PDB is a warning" {
  echo '{"items":[{"metadata":{"namespace":"app","name":"web"},"status":{"disruptionsAllowed":0}}]}' > "$K8S/pdb.json"
  run sh "$PREFLIGHT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[WARN]  PDBs with no disruptions allowed"*"app/web"* ]]
}

@test "preflight: a node with an upgrade in progress is a warning, not a failure" {
  set_applying os-upgrade-cp cp2
  run sh "$PREFLIGHT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[WARN]  nodes with an upgrade in progress (rollout.sh resumes them first): cp2"* ]]
}

@test "preflight: os-upgrade Plans not applied" {
  echo '{"items":[]}' > "$K8S/plans.json"
  run sh "$PREFLIGHT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing Plans: os-upgrade-predownload os-upgrade-workers os-upgrade-cp"* ]]
}

@test "preflight: without API access it stops right away" {
  touch "$K8S/api-down"
  run sh "$PREFLIGHT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot reach the Kubernetes API"* ]]
  not_called "etcdctl"
}

@test "check-cluster: shows etcd without a shell and gives a verdict" {
  run sh "$CHECK_CLUSTER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"=== etcd"*"ENDPOINT"* ]]
  [[ "$output" == *"Alarms: none"* ]]
  [[ "$output" == *"=== Verdict"*"[OK]    etcd healthy"* ]]
  not_called "sh -c"
}

@test "check-cluster: degraded etcd exits with 1" {
  set_etcd 1 6 false
  run sh "$CHECK_CLUSTER"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL]  etcd"* ]]
}
