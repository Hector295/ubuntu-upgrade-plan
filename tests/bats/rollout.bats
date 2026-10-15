#!/usr/bin/env bats
# rollout.sh contra un cluster falso (tests/k8s-stubs/kubectl).

load k8s_helpers

setup() {
  setup_cluster
}

@test "rollout: sin --group ni --nodes falla" {
  run sh "$ROLLOUT" upgrade --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"indicar --group G o --nodes"* ]]
}

@test "rollout: duración inválida falla" {
  run sh "$ROLLOUT" upgrade --nodes w1 --drain-timeout 5x
  [ "$status" -ne 0 ]
  [[ "$output" == *"duración inválida en --drain-timeout"* ]]
}

@test "rollout --dry-run: orden workers -> cp no líderes -> líder, sin cambiar nada" {
  run sh "$ROLLOUT" upgrade --nodes cp1,cp2,w1 --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"1. w1"*"2. cp2"*"3. cp1"*"líder de etcd: move-leader antes"* ]]
  [[ "$output" == *"[dry-run] kubectl label node w1 os-upgrade=upgrade --overwrite"* ]]
  [[ "$output" == *"[dry-run] etcd_ctl cp1 --endpoints=https://10.0.0.1:2379 move-leader"* ]]
  not_called "label node"
  not_called "move-leader"
  not_called "uncordon"
  not_called "delete"
}

@test "rollout: worker completo con --yes queda en done" {
  scenario_success w1 os-upgrade-workers "$H_W"
  run sh "$ROLLOUT" upgrade --nodes w1 --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"w1: prepare"*"w1: drain"*"w1: upgrade en curso"*"w1: Plan os-upgrade-workers completado"* ]]
  [[ "$output" == *"[OK]    w1: Ubuntu 24.04.3 LTS, kernel $TARGET_KERNEL"* ]]
  [[ "$output" == *"DNS y red del clúster funcionan"* ]]
  [ "$(label_of w1 os-upgrade)" = done ]
  called "label node w1 os-upgrade=upgrade --overwrite"
}

@test "rollout: grupo de workers pide confirmación entre nodos y respeta el 'no'" {
  scenario_success w1 os-upgrade-workers "$H_W"
  scenario_success w2 os-upgrade-workers "$H_W"
  answers s n
  run sh "$ROLLOUT" upgrade --group 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"w1 terminado y verificado. ¿Continuar con w2?"* ]]
  [[ "$output" == *"Rollout detenido por el operador después de w1"* ]]
  [ "$(label_of w1 os-upgrade)" = done ]
  [ "$(label_of w2 os-upgrade)" = "" ]
}

@test "rollout: sin confirmación inicial no toca nada" {
  answers n
  run sh "$ROLLOUT" upgrade --nodes w1
  [ "$status" -eq 1 ]
  not_called "label node"
}

@test "rollout: líder de etcd -> move-leader a un miembro ya actualizado antes de etiquetarlo" {
  scenario_success cp2 os-upgrade-cp "$H_CP"
  scenario_success cp1 os-upgrade-cp "$H_CP"
  run sh "$ROLLOUT" upgrade --nodes cp1,cp2 --yes
  [ "$status" -eq 0 ]
  # cp2 primero; cp1 (líder) al final, con move-leader a cp2 (ya en 24.04).
  [ "$(line_of 'label node cp2 os-upgrade=upgrade')" -lt "$(line_of 'move-leader')" ]
  [ "$(line_of 'move-leader aaaa000000000002')" -lt "$(line_of 'label node cp1 os-upgrade=upgrade')" ]
  [[ "$output" == *"Nuevo líder de etcd: cp2"* ]]
  [ "$(label_of cp1 os-upgrade)" = done ]
  [ "$(label_of cp2 os-upgrade)" = done ]
}

@test "rollout: prepare fallido -> nodo apartado, sin drenar ni uncordon" {
  frame os-upgrade-workers w1 1 running "" "" active
  frame os-upgrade-workers w1 2 fail "" "" active
  echo "ERROR falta la pre-descarga" > "$K8S/logs.prepare.txt"
  run sh "$ROLLOUT" upgrade --nodes w1 --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"El nodo NO se ha drenado"* ]]
  [[ "$output" == *"falta la pre-descarga"* ]]
  [ "$(label_of w1 os-upgrade)" = hold ]
  called "delete job -l upgrade.cattle.io/plan=os-upgrade-workers,upgrade.cattle.io/node=w1"
  not_called "uncordon"
}

@test "rollout: drain que supera el timeout con --yes -> aborta, aparta y hace uncordon" {
  frame os-upgrade-workers w1 1 ok "running@2026-01-01T00:00:00Z" "" active '.spec.unschedulable = true'
  run sh "$ROLLOUT" upgrade --nodes w1 --yes --drain-timeout 10m
  [ "$status" -eq 1 ]
  [[ "$output" == *"el drain lleva más de 10 min"* ]]
  [[ "$output" == *"drain abortado en w1 (uncordon hecho)"* ]]
  [ "$(label_of w1 os-upgrade)" = hold ]
  called "uncordon w1"
}

@test "rollout: drain lento -> el operador decide esperar y el nodo termina" {
  frame os-upgrade-workers w1 1 ok "running@2026-01-01T00:00:00Z" "" active
  frame os-upgrade-workers w1 2 ok ok running active
  frame os-upgrade-workers w1 3 ok ok ok complete "$(upgraded_expr os-upgrade-workers "$H_W")"
  answers s e
  run sh "$ROLLOUT" upgrade --nodes w1 --drain-timeout 10m
  [ "$status" -eq 0 ]
  [[ "$output" == *"[e]sperar 10m más"* ]]
  not_called "uncordon"
  [ "$(label_of w1 os-upgrade)" = done ]
}

@test "rollout: Job fallido tras empezar el upgrade -> para y deja el nodo como está" {
  frame os-upgrade-workers w1 1 ok ok running active '.spec.unschedulable = true'
  frame os-upgrade-workers w1 2 ok ok fail failed
  run sh "$ROLLOUT" upgrade --nodes w1 --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"el Job del Plan os-upgrade-workers ha fallado"* ]]
  [[ "$output" == *"BackoffLimitExceeded"* ]]
  [[ "$output" == *"sigue cordoneado y con os-upgrade=upgrade"* ]]
  [ "$(label_of w1 os-upgrade)" = upgrade ]
  not_called "uncordon"
  not_called "delete job"
}

@test "rollout: verificación fallida (kernel distinto) no marca done" {
  frame os-upgrade-workers w1 1 ok ok ok complete "$(upgraded_expr os-upgrade-workers "$H_W" 6.8.0-147-generic)"
  SETTLE_TIMEOUT=0s run sh "$ROLLOUT" upgrade --nodes w1 --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"kernel '6.8.0-147-generic' (esperado $TARGET_KERNEL)"* ]]
  [ "$(label_of w1 os-upgrade)" = upgrade ]
}

@test "rollout: prueba de DNS fallida no marca done" {
  scenario_success w1 os-upgrade-workers "$H_W"
  touch "$K8S/nettest-fail"
  run sh "$ROLLOUT" upgrade --nodes w1 --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"la prueba de DNS/red falló en w1"* ]]
  [ "$(label_of w1 os-upgrade)" = upgrade ]
}

@test "rollout: --skip-net-test omite la prueba de DNS" {
  scenario_success w1 os-upgrade-workers "$H_W"
  touch "$K8S/nettest-fail"
  run sh "$ROLLOUT" upgrade --nodes w1 --yes --skip-net-test
  [ "$status" -eq 0 ]
  not_called " run "
}

@test "rollout: etcd no sano -> no se etiqueta el nodo" {
  set_etcd 3 6 false
  run sh "$ROLLOUT" upgrade --nodes w1 --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"etcd no está sano"* ]]
  not_called "label node"
}

@test "rollout: Plan de Rancher en curso -> no empieza" {
  set_applying system-agent-upgrader-x cp1
  run sh "$ROLLOUT" upgrade --nodes w1 --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"hay Plans de Rancher aplicándose"* ]]
  not_called "label node"
}

@test "rollout: snapshot de etcd antiguo -> no empieza" {
  snapshot_age_hours 48
  run sh "$ROLLOUT" upgrade --nodes w1 --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"el último snapshot de etcd tiene 48 h"* ]]
  not_called "label node"
}

@test "rollout: otro nodo en upgrade -> no empieza el siguiente" {
  set_applying os-upgrade-cp cp3
  run sh "$ROLLOUT" upgrade --nodes w1 --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"hay otros nodos actualizándose: os-upgrade-cp:cp3"* ]]
  not_called "label node"
}

@test "rollout: nodos done y hold se omiten" {
  set_label w1 os-upgrade done
  set_label w2 os-upgrade hold
  run sh "$ROLLOUT" upgrade --group 1 --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"se omite w1 (os-upgrade=done)"* ]]
  [[ "$output" == *"se omite w2 (os-upgrade=hold)"* ]]
  [[ "$output" == *"Nada que hacer"* ]]
  not_called "label node"
}

@test "rollout: retoma un nodo que ya estaba en curso sin volver a etiquetarlo" {
  set_label w1 os-upgrade upgrade
  set_applying os-upgrade-workers w1
  frame os-upgrade-workers w1 1 ok ok running active
  frame os-upgrade-workers w1 2 ok ok ok complete "$(upgraded_expr os-upgrade-workers "$H_W")"
  run sh "$ROLLOUT" upgrade --nodes w1 --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"en curso: se retoma"* ]]
  not_called "label node w1 os-upgrade=upgrade"
  [ "$(label_of w1 os-upgrade)" = done ]
}

@test "rollout: PDB bloqueado en el namespace de un pod del nodo pide confirmación" {
  echo '{"items":[{"metadata":{"namespace":"app","name":"web"},"status":{"disruptionsAllowed":0}}]}' > "$K8S/pdb.json"
  echo '{"items":[{"metadata":{"namespace":"app","name":"web-1","ownerReferences":[{"kind":"ReplicaSet"}]},"status":{"phase":"Running"}}]}' > "$K8S/nodepods/w1.json"
  answers s n
  run sh "$ROLLOUT" upgrade --nodes w1
  [ "$status" -eq 1 ]
  [[ "$output" == *"PDBs sin interrupciones permitidas"*"app/web"* ]]
  not_called "label node"
}

@test "predownload: etiqueta solo los nodos elegibles" {
  set_label w2 os-upgrade done
  set_label cp1 os-upgrade upgrade
  run sh "$ROLLOUT" predownload --nodes w1,w2,cp1 --yes
  [ "$status" -eq 0 ]
  called "label node w1 os-upgrade=predownload"
  not_called "label node w2"
  not_called "label node cp1"
  [[ "$output" == *"se omite w2 (os-upgrade=done)"* ]]
}

@test "predownload --wait: informa del resultado y de los avisos de cada nodo" {
  frame os-upgrade-predownload w1 1 "" "" running active
  frame os-upgrade-predownload w1 2 "" "" ok complete ".metadata.labels[\"plan.upgrade.cattle.io/os-upgrade-predownload\"] = \"$H_PRE\""
  printf 'INFO Pre-descarga OK: 700 paquetes\nWARN este nodo necesitará parche + reboot previo\n' > "$K8S/logs.upgrade.txt"
  run sh "$ROLLOUT" predownload --nodes w1 --yes --wait
  [ "$status" -eq 0 ]
  [[ "$output" == *"w1: descargando"*"w1: pre-descarga terminada"* ]]
  [[ "$output" == *"Pre-descarga OK: 700 paquetes"* ]]
  [[ "$output" == *"WARN este nodo necesitará parche + reboot previo"* ]]
  [[ "$output" == *"Pre-descarga completada."* ]]
}

@test "predownload --wait: un Job fallido hace fallar el comando" {
  frame os-upgrade-predownload w1 1 "" "" fail failed
  run sh "$ROLLOUT" predownload --nodes w1 --yes --wait
  [ "$status" -eq 1 ]
  [[ "$output" == *"w1: la pre-descarga falló"* ]]
}

@test "status: tabla de nodos con su estado" {
  set_label w1 os-upgrade done
  set_label w1 plan.upgrade.cattle.io/os-upgrade-workers "$H_W"
  set_label w1 plan.upgrade.cattle.io/os-upgrade-predownload "$H_PRE"
  run sh "$ROLLOUT" status --group 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"NODO"*"PREDESCARGA"* ]]
  echo "$output" | grep -Eq '^w1 +worker +1 +done +ok +ok '
  echo "$output" | grep -Eq '^w2 +worker +1 +- +no +no '
  ! echo "$output" | grep -q '^cp1'
}
