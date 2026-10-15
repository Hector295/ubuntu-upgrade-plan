#!/usr/bin/env bats
# rollout.sh against a fake cluster (tests/k8s-stubs/kubectl).

load k8s_helpers

setup() {
  setup_cluster
}

@test "rollout: fails without --group or --nodes" {
  run sh "$ROLLOUT" upgrade --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"specify --group G or --nodes"* ]]
}

@test "rollout: invalid duration fails" {
  run sh "$ROLLOUT" upgrade --nodes w1 --drain-timeout 5x
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid duration in --drain-timeout"* ]]
}

@test "rollout --dry-run: order workers -> non-leader cps -> leader, changing nothing" {
  run sh "$ROLLOUT" upgrade --nodes cp1,cp2,w1 --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"1. w1"*"2. cp2"*"3. cp1"*"etcd leader: move-leader first"* ]]
  [[ "$output" == *"[dry-run] kubectl label node w1 os-upgrade=upgrade --overwrite"* ]]
  [[ "$output" == *"[dry-run] etcd_ctl cp1 --endpoints=https://10.0.0.1:2379 move-leader"* ]]
  not_called "label node"
  not_called "move-leader"
  not_called "uncordon"
  not_called "delete"
}

@test "rollout: complete worker with --yes ends up done" {
  scenario_success w1 os-upgrade-workers "$H_W"
  run sh "$ROLLOUT" upgrade --nodes w1 --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"w1: prepare"*"w1: drain"*"w1: upgrade in progress"*"w1: Plan os-upgrade-workers complete"* ]]
  [[ "$output" == *"[OK]    w1: Ubuntu 24.04.3 LTS, kernel $TARGET_KERNEL"* ]]
  [[ "$output" == *"cluster DNS and network work"* ]]
  [ "$(label_of w1 os-upgrade)" = done ]
  called "label node w1 os-upgrade=upgrade --overwrite"
}

@test "rollout: a worker group asks for confirmation between nodes and honours 'no'" {
  scenario_success w1 os-upgrade-workers "$H_W"
  scenario_success w2 os-upgrade-workers "$H_W"
  answers y n
  run sh "$ROLLOUT" upgrade --group 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Start the rollout of 2 node(s)? [y/N]"* ]]
  [[ "$output" == *"w1 finished and verified. Continue with w2?"* ]]
  [[ "$output" == *"Rollout stopped by the operator after w1"* ]]
  [ "$(label_of w1 os-upgrade)" = done ]
  [ "$(label_of w2 os-upgrade)" = "" ]
}

@test "rollout: the old Spanish answer 's' is still accepted" {
  scenario_success w1 os-upgrade-workers "$H_W"
  answers s
  run sh "$ROLLOUT" upgrade --nodes w1
  [ "$status" -eq 0 ]
  [ "$(label_of w1 os-upgrade)" = done ]
}

@test "rollout: without the initial confirmation nothing is touched" {
  answers n
  run sh "$ROLLOUT" upgrade --nodes w1
  [ "$status" -eq 1 ]
  not_called "label node"
}

@test "rollout: etcd leader -> move-leader to an upgraded member before labeling it" {
  scenario_success cp2 os-upgrade-cp "$H_CP"
  scenario_success cp1 os-upgrade-cp "$H_CP"
  run sh "$ROLLOUT" upgrade --nodes cp1,cp2 --yes
  [ "$status" -eq 0 ]
  # cp2 first; cp1 (leader) last, with move-leader to cp2 (already on 24.04).
  [ "$(line_of 'label node cp2 os-upgrade=upgrade')" -lt "$(line_of 'move-leader')" ]
  [ "$(line_of 'move-leader aaaa000000000002')" -lt "$(line_of 'label node cp1 os-upgrade=upgrade')" ]
  [[ "$output" == *"New etcd leader: cp2"* ]]
  [ "$(label_of cp1 os-upgrade)" = done ]
  [ "$(label_of cp2 os-upgrade)" = done ]
}

@test "rollout: failed prepare -> node held, not drained, no uncordon" {
  frame os-upgrade-workers w1 1 running "" "" active
  frame os-upgrade-workers w1 2 fail "" "" active
  echo "ERROR predownload missing" > "$K8S/logs.prepare.txt"
  run sh "$ROLLOUT" upgrade --nodes w1 --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"The node was NOT drained or modified"* ]]
  [[ "$output" == *"predownload missing"* ]]
  [[ "$output" == *"see docs/runbook.md, 'prepare fails'"* ]]
  [ "$(label_of w1 os-upgrade)" = hold ]
  called "delete job -l upgrade.cattle.io/plan=os-upgrade-workers,upgrade.cattle.io/node=w1"
  not_called "uncordon"
}

@test "rollout: drain over the timeout with --yes -> abort, hold and uncordon" {
  frame os-upgrade-workers w1 1 ok "running@2026-01-01T00:00:00Z" "" active '.spec.unschedulable = true'
  run sh "$ROLLOUT" upgrade --nodes w1 --yes --drain-timeout 10m
  [ "$status" -eq 1 ]
  [[ "$output" == *"the drain has been running for more than 10 min"* ]]
  [[ "$output" == *"drain aborted on w1 (uncordon done)"* ]]
  [ "$(label_of w1 os-upgrade)" = hold ]
  called "uncordon w1"
}

@test "rollout: slow drain -> the operator chooses to wait and the node finishes" {
  frame os-upgrade-workers w1 1 ok "running@2026-01-01T00:00:00Z" "" active
  frame os-upgrade-workers w1 2 ok ok running active
  frame os-upgrade-workers w1 3 ok ok ok complete "$(upgraded_expr os-upgrade-workers "$H_W")"
  answers y w
  run sh "$ROLLOUT" upgrade --nodes w1 --drain-timeout 10m
  [ "$status" -eq 0 ]
  [[ "$output" == *"[w]ait 10m more"* ]]
  not_called "uncordon"
  [ "$(label_of w1 os-upgrade)" = done ]
}

@test "rollout: Job failed after the upgrade started -> stop and leave the node as is" {
  frame os-upgrade-workers w1 1 ok ok running active '.spec.unschedulable = true'
  frame os-upgrade-workers w1 2 ok ok fail failed
  run sh "$ROLLOUT" upgrade --nodes w1 --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"the Job of Plan os-upgrade-workers has failed"* ]]
  [[ "$output" == *"BackoffLimitExceeded"* ]]
  [[ "$output" == *"is still cordoned and has os-upgrade=upgrade"* ]]
  [[ "$output" == *"see docs/runbook.md, 'The Job failed after the drain'"* ]]
  [ "$(label_of w1 os-upgrade)" = upgrade ]
  not_called "uncordon"
  not_called "delete job"
}

@test "rollout: Failed SUC Job pods (killed by the reboot) do not count as a problem" {
  scenario_success w1 os-upgrade-workers "$H_W"
  cat > "$K8S/nodepods/w1.json" <<'EOF2'
{"items":[
 {"metadata":{"namespace":"cattle-system","name":"apply-os-upgrade-workers-on-w1-a","labels":{"upgrade.cattle.io/controller":"system-upgrade-controller"}},"status":{"phase":"Failed"}},
 {"metadata":{"namespace":"kube-system","name":"rke2-canal-x","ownerReferences":[{"kind":"DaemonSet"}]},"status":{"phase":"Running"}}
]}
EOF2
  run sh "$ROLLOUT" upgrade --nodes w1 --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"[OK]    w1: all its pods running"* ]]
}

@test "rollout: an application pod in CrashLoopBackOff does block verification" {
  scenario_success w1 os-upgrade-workers "$H_W"
  echo '{"items":[{"metadata":{"namespace":"app","name":"web-1"},"status":{"phase":"Running","containerStatuses":[{"state":{"waiting":{"reason":"CrashLoopBackOff"}}}]}}]}' > "$K8S/nodepods/w1.json"
  SETTLE_TIMEOUT=0s run sh "$ROLLOUT" upgrade --nodes w1 --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL]  w1: pods with problems: app/web-1"* ]]
}

@test "rollout: failed verification (different kernel) does not mark done" {
  frame os-upgrade-workers w1 1 ok ok ok complete "$(upgraded_expr os-upgrade-workers "$H_W" 6.8.0-147-generic)"
  SETTLE_TIMEOUT=0s run sh "$ROLLOUT" upgrade --nodes w1 --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"kernel '6.8.0-147-generic' (expected $TARGET_KERNEL)"* ]]
  [[ "$output" == *"does not pass verification after 0s"* ]]
  [ "$(label_of w1 os-upgrade)" = upgrade ]
}

@test "rollout: failed DNS test does not mark done" {
  scenario_success w1 os-upgrade-workers "$H_W"
  touch "$K8S/nettest-fail"
  run sh "$ROLLOUT" upgrade --nodes w1 --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"the DNS/network test failed on w1"* ]]
  [ "$(label_of w1 os-upgrade)" = upgrade ]
}

@test "rollout: --skip-net-test skips the DNS test" {
  scenario_success w1 os-upgrade-workers "$H_W"
  touch "$K8S/nettest-fail"
  run sh "$ROLLOUT" upgrade --nodes w1 --yes --skip-net-test
  [ "$status" -eq 0 ]
  not_called " run "
}

@test "rollout: unhealthy etcd -> the node is not labeled" {
  set_etcd 3 6 false
  run sh "$ROLLOUT" upgrade --nodes w1 --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"etcd is not healthy"* ]]
  not_called "label node"
}

@test "rollout: Rancher Plan in progress -> does not start" {
  set_applying system-agent-upgrader-x cp1
  run sh "$ROLLOUT" upgrade --nodes w1 --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"Rancher Plans are being applied"* ]]
  not_called "label node"
}

@test "rollout: old etcd snapshot -> does not start" {
  snapshot_age_hours 48
  run sh "$ROLLOUT" upgrade --nodes w1 --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"the latest etcd snapshot is 48 h old"* ]]
  not_called "label node"
}

@test "rollout: another node upgrading -> the next one does not start" {
  set_applying os-upgrade-cp cp3
  run sh "$ROLLOUT" upgrade --nodes w1 --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"other nodes are being upgraded: os-upgrade-cp:cp3"* ]]
  not_called "label node"
}

@test "rollout: done and hold nodes are skipped" {
  set_label w1 os-upgrade done
  set_label w2 os-upgrade hold
  run sh "$ROLLOUT" upgrade --group 1 --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping w1 (os-upgrade=done)"* ]]
  [[ "$output" == *"skipping w2 (os-upgrade=hold)"* ]]
  [[ "$output" == *"Nothing to do"* ]]
  not_called "label node"
}

@test "rollout: resumes a node already in progress without relabeling it" {
  set_label w1 os-upgrade upgrade
  set_applying os-upgrade-workers w1
  frame os-upgrade-workers w1 1 ok ok running active
  frame os-upgrade-workers w1 2 ok ok ok complete "$(upgraded_expr os-upgrade-workers "$H_W")"
  run sh "$ROLLOUT" upgrade --nodes w1 --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"in progress: resumed"* ]]
  not_called "label node w1 os-upgrade=upgrade"
  [ "$(label_of w1 os-upgrade)" = done ]
}

@test "rollout: a blocked PDB in the namespace of a pod on the node asks for confirmation" {
  echo '{"items":[{"metadata":{"namespace":"app","name":"web"},"status":{"disruptionsAllowed":0}}]}' > "$K8S/pdb.json"
  echo '{"items":[{"metadata":{"namespace":"app","name":"web-1","ownerReferences":[{"kind":"ReplicaSet"}]},"status":{"phase":"Running"}}]}' > "$K8S/nodepods/w1.json"
  answers y n
  run sh "$ROLLOUT" upgrade --nodes w1
  [ "$status" -eq 1 ]
  [[ "$output" == *"PDBs with no disruptions allowed"*"app/web"* ]]
  [[ "$output" == *"Rollout stopped before w1 because of the PDBs."* ]]
  not_called "label node"
}

@test "predownload: labels only the eligible nodes" {
  set_label w2 os-upgrade done
  set_label cp1 os-upgrade upgrade
  run sh "$ROLLOUT" predownload --nodes w1,w2,cp1 --yes
  [ "$status" -eq 0 ]
  called "label node w1 os-upgrade=predownload"
  not_called "label node w2"
  not_called "label node cp1"
  [[ "$output" == *"skipping w2 (os-upgrade=done)"* ]]
}

@test "predownload --wait: reports each node's result and warnings" {
  frame os-upgrade-predownload w1 1 "" "" running active
  frame os-upgrade-predownload w1 2 "" "" ok complete ".metadata.labels[\"plan.upgrade.cattle.io/os-upgrade-predownload\"] = \"$H_PRE\""
  printf 'INFO Predownload OK: 700 packages\nWARN this node will need a patch + prior reboot\nINFO something else\n' > "$K8S/logs.upgrade.txt"
  run sh "$ROLLOUT" predownload --nodes w1 --yes --wait
  [ "$status" -eq 0 ]
  [[ "$output" == *"w1: downloading"*"w1: predownload finished"* ]]
  [[ "$output" == *"Predownload OK: 700 packages"* ]]
  [[ "$output" == *"WARN this node will need a patch + prior reboot"* ]]
  [[ "$output" != *"something else"* ]]
  [[ "$output" == *"Predownload complete."* ]]
}

@test "predownload --wait: a failed Job makes the command fail" {
  frame os-upgrade-predownload w1 1 "" "" fail failed
  run sh "$ROLLOUT" predownload --nodes w1 --yes --wait
  [ "$status" -eq 1 ]
  [[ "$output" == *"w1: the predownload failed"* ]]
}

@test "status: actual state of each node, not the Plan version hash" {
  # w1: upgraded in a previous campaign (old hash) -> ok.
  set_label w1 os-upgrade done
  set_label w1 plan.upgrade.cattle.io/os-upgrade-workers old
  y -i -p json -o json "(.items[] | select(.metadata.name == \"w1\")) |= ($(upgraded_expr os-upgrade-workers old))" "$K8S/nodes.json"
  # w2: in progress, with the predownload of the current version.
  set_label w2 os-upgrade upgrade
  set_label w2 plan.upgrade.cattle.io/os-upgrade-predownload "$H_PRE"
  # cp1: predownload of a previous version.
  set_label cp1 plan.upgrade.cattle.io/os-upgrade-predownload old
  run sh "$ROLLOUT" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"NODE"*"PREDOWNLOAD"*"STATE"* ]]
  echo "$output" | grep -Eq '^w1 +worker +1 +done +- +ok +Ubuntu_24.04.3 +6.8.0-139-generic +Ready'
  echo "$output" | grep -Eq '^w2 +worker +1 +upgrade +ok +in progress '
  echo "$output" | grep -Eq '^cp1 +cp +3 +- +previous +no '
  echo "$output" | grep -Eq '^cp2 +cp +3 +- +no +no '
}

@test "status: a node on 24.04 with another kernel is not shown as upgraded" {
  y -i -p json -o json "(.items[] | select(.metadata.name == \"w1\")) |= ($(upgraded_expr os-upgrade-workers "$H_W" 6.8.0-147-generic))" "$K8S/nodes.json"
  run sh "$ROLLOUT" status --nodes w1
  echo "$output" | grep -Eq '^w1 +worker +1 +- +no +no +Ubuntu_24.04.3 +6.8.0-147-generic'
}

@test "rollout 26.04: verifies against Ubuntu 26.04 and kernel 7.0" {
  set_target_2604
  frame os-upgrade-workers w1 1 ok ok ok complete "$(upgraded_expr os-upgrade-workers "$H_W" 7.0.0-38-generic 'Ubuntu 26.04.1 LTS')"
  run sh "$ROLLOUT" upgrade --nodes w1 --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"Ubuntu 26.04 with kernel 7.0.0-38-generic"* ]]
  [[ "$output" == *"[OK]    w1: Ubuntu 26.04.1 LTS, kernel 7.0.0-38-generic"* ]]
}

@test "rollout 26.04: a node left on 24.04 does not pass verification" {
  set_target_2604
  frame os-upgrade-workers w1 1 ok ok ok complete "$(upgraded_expr os-upgrade-workers "$H_W" 7.0.0-38-generic)"
  SETTLE_TIMEOUT=0s run sh "$ROLLOUT" upgrade --nodes w1 --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"OS 'Ubuntu 24.04.3 LTS' (expected Ubuntu 26.04)"* ]]
}

@test "status 26.04: a node on 24.04 with kernel 6.8 is no longer shown as upgraded" {
  set_target_2604
  y -i -p json -o json "(.items[] | select(.metadata.name == \"w1\")) |= ($(upgraded_expr os-upgrade-workers "$H_W"))" "$K8S/nodes.json"
  y -i -p json -o json "(.items[] | select(.metadata.name == \"w2\")) |= ($(upgraded_expr os-upgrade-workers "$H_W" 7.0.0-38-generic 'Ubuntu 26.04.1 LTS'))" "$K8S/nodes.json"
  run sh "$ROLLOUT" status --group 1
  echo "$output" | grep -Eq '^w1 +worker +1 +- +no +no +Ubuntu_24.04.3'
  echo "$output" | grep -Eq '^w2 +worker +1 +- +- +ok +Ubuntu_26.04.1'
}

@test "rollout: no yq errors in the output while the Job pod does not exist yet" {
  frame os-upgrade-workers w1 1 "" "" "" active
  frame os-upgrade-workers w1 2 ok ok ok complete "$(upgraded_expr os-upgrade-workers "$H_W")"
  run sh "$ROLLOUT" upgrade --nodes w1 --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"w1: waiting for the SUC to create the Job"* ]]
  [[ "$output" != *"out of range"* ]]
}
