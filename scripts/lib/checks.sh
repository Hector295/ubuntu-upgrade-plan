# shellcheck shell=sh
# Comprobaciones con veredicto. Cada check_* imprime una línea [OK]/[AVISO]/[FALLO] con el
# detalle, y devuelve 0 (OK o aviso) o 1 (fallo). Requiere common.sh y k8s.sh.

ETCD_MIN_MEMBERS="${ETCD_MIN_MEMBERS:-3}"
ETCD_RAFT_MAX_LAG="${ETCD_RAFT_MAX_LAG:-100}"
ETCD_RETRIES="${ETCD_RETRIES:-3}"
SNAPSHOT_MAX_AGE_HOURS="${SNAPSHOT_MAX_AGE_HOURS:-24}"
RETRY_SLEEP="${RETRY_SLEEP:-5}"

CHECK_FAILS=0
CHECK_WARNS=0

ok() { echo "[OK]    $*"; }
warn_check() {
  echo "[AVISO] $*"
  CHECK_WARNS=$((CHECK_WARNS + 1))
}
fail_check() {
  echo "[FALLO] $*"
  CHECK_FAILS=$((CHECK_FAILS + 1))
  return 1
}

# ------------------------------------------------------------------ cluster
check_api() {
  if k get --raw /readyz >/dev/null 2>&1; then
    ok "API de Kubernetes accesible (contexto $(k config current-context 2>/dev/null || echo '?'))"
  else
    fail_check "no se puede acceder a la API de Kubernetes; revisar KUBECONFIG"
  fi
}

check_suc() {
  d=$(k -n "$NS" get deploy system-upgrade-controller -o json 2>/dev/null) \
    || { fail_check "no existe el deployment system-upgrade-controller en $NS"; return 1; }
  avail=$(echo "$d" | jq_ '.status.availableReplicas // 0')
  image=$(echo "$d" | jq_ '.spec.template.spec.containers[0].image')
  backoff=$(echo "$d" | jq_ '[.spec.template.spec.containers[0].env[] | select(.name == "SYSTEM_UPGRADE_JOB_BACKOFF_LIMIT") | .value][0] // "2 (por defecto)"')
  if [ "$avail" -ge 1 ]; then
    ok "system-upgrade-controller en ejecución ($image, backoffLimit de los Jobs: $backoff)"
  else
    fail_check "system-upgrade-controller sin réplicas disponibles"
  fi
}

check_plans() {
  missing=""
  for p in "$PLAN_PREDOWNLOAD" "$PLAN_WORKERS" "$PLAN_CP"; do
    plan_json "$p" >/dev/null 2>&1 || missing="$missing $p"
  done
  if [ -n "$missing" ]; then
    fail_check "faltan Plans:$missing (make render + kubectl apply)"
    return 1
  fi
  kernel=$(config_value KERNEL_VERSION || true)
  [ -n "$kernel" ] || { fail_check "el ConfigMap de los Plans no define KERNEL_VERSION"; return 1; }
  ok "Plans os-upgrade presentes (kernel objetivo $kernel)"
}

# Los Plans de Rancher (upgrade de RKE2) no deben estar actuando a la vez.
check_rancher_plans_idle() {
  busy=$(k -n "$NS" get plans -o json | jq_ '.items[] | select(.metadata.name | test("^system-agent-upgrader")) | select((.status.applying // []) | length > 0) | .metadata.name + ": " + (.status.applying | join(","))')
  if [ -n "$busy" ]; then
    fail_check "hay Plans de Rancher aplicándose; congelar los upgrades de RKE2 antes de seguir: $busy"
  else
    ok "ningún Plan de Rancher (system-agent-upgrader) en curso"
  fi
}

# Ningún nodo actualizándose, salvo el indicado (para reanudar).
check_os_upgrade_idle() {
  except=${1:-}
  busy=""
  for p in "$PLAN_WORKERS" "$PLAN_CP"; do
    for n in $(plan_applying "$p"); do
      [ "$n" = "$except" ] || busy="$busy $p:$n"
    done
  done
  if [ -n "$busy" ]; then
    fail_check "hay otros nodos actualizándose:$busy"
  else
    ok "ningún otro nodo en upgrade"
  fi
}

check_nodes_ready() {
  bad=$(nodes_json | jq_ '.items[] | select([.status.conditions[] | select(.type == "Ready" and .status == "True")] | length == 0) | .metadata.name')
  if [ -n "$bad" ]; then
    fail_check "nodos no Ready: $(echo "$bad" | tr '\n' ' ')"
  else
    ok "todos los nodos Ready"
  fi
  cordoned=$(nodes_json | jq_ '.items[] | select(.spec.unschedulable == true) | .metadata.name')
  if [ -n "$cordoned" ]; then
    warn_check "nodos cordoneados: $(echo "$cordoned" | tr '\n' ' ')"
  fi
  [ -z "$bad" ]
}

# etcd: miembros suficientes, todos sanos, un único líder y RAFT INDEX igualado.
check_etcd() {
  avoid=${1:-}
  attempt=1
  while :; do
    members=$(etcd_members "$avoid" | sed '/^$/d' | wc -l)
    status=$(etcd_status "$avoid")
    health=$(etcd_health "$avoid")
    reason=""
    n_status=$(echo "$status" | sed '/^$/d' | wc -l)
    leaders=$(echo "$status" | awk -F'\t' '$3 == "true"' | wc -l)
    unhealthy=$(echo "$health" | awk -F'\t' 'NF && $2 != "true" {print $1}')
    n_healthy=$(echo "$health" | awk -F'\t' '$2 == "true"' | wc -l)
    lag=$(echo "$status" | awk -F'\t' 'NF {v = $4 + 0; if (min == "" || v < min) min = v; if (v > max) max = v} END {print max - min}')
    errors=$(echo "$status" | awk -F'\t' '$5 != "" {print $1 ": " $5}')
    alarms=$(etcd_ctl "$avoid" alarm list 2>/dev/null | sed '/^$/d' || true)

    if [ "$members" -lt "$ETCD_MIN_MEMBERS" ]; then
      reason="$members miembros (mínimo $ETCD_MIN_MEMBERS)"
    elif [ "$n_status" -lt "$members" ] || [ "$n_healthy" -lt "$members" ]; then
      reason="miembros que no responden o no sanos ($n_healthy/$members sanos) $(echo "$unhealthy" | tr '\n' ' ')"
    elif [ -n "$errors" ]; then
      reason="errores: $errors"
    elif [ -n "$alarms" ]; then
      reason="alarmas activas: $(echo "$alarms" | tr '\n' ' ')"
    elif [ "$leaders" -ne 1 ]; then
      reason="$leaders líderes (debe haber 1)"
    elif [ "$lag" -gt "$ETCD_RAFT_MAX_LAG" ]; then
      reason="RAFT INDEX desigualado (diferencia $lag > $ETCD_RAFT_MAX_LAG)"
    fi

    if [ -z "$reason" ]; then
      ok "etcd sano: $members miembros, 1 líder, diferencia de RAFT INDEX $lag"
      return 0
    fi
    if [ "$attempt" -ge "$ETCD_RETRIES" ]; then
      fail_check "etcd: $reason"
      return 1
    fi
    attempt=$((attempt + 1))
    sleep "$RETRY_SLEEP"
  done
}

check_snapshot() {
  snaps=$(k get etcdsnapshotfiles -o json 2>/dev/null) || {
    warn_check "no se pudo consultar etcdsnapshotfiles; comprobar a mano que hay un snapshot reciente"
    return 0
  }
  newest=$(echo "$snaps" | jq_ '[.items[] | (.status.creationTime // .metadata.creationTimestamp)] | sort | .[-1] // ""')
  if [ -z "$newest" ]; then
    fail_check "no hay snapshots de etcd; hacer uno antes de empezar"
    return 1
  fi
  age_h=$(( ($(now) - $(to_epoch "$newest")) / 3600 ))
  if [ "$age_h" -gt "$SNAPSHOT_MAX_AGE_HOURS" ]; then
    fail_check "el último snapshot de etcd tiene ${age_h} h ($newest); máximo ${SNAPSHOT_MAX_AGE_HOURS} h"
  else
    ok "snapshot de etcd reciente ($newest, hace ${age_h} h)"
  fi
}

# PDBs que ahora mismo no permiten ninguna interrupción: bloquearían el drain.
check_pdbs() {
  blocked=$(k get pdb -A -o json | jq_ '.items[] | select((.status.disruptionsAllowed // 0) == 0) | .metadata.namespace + "/" + .metadata.name')
  if [ -n "$blocked" ]; then
    warn_check "PDBs sin interrupciones permitidas (pueden bloquear el drain): $(echo "$blocked" | tr '\n' ' ')"
  else
    ok "ningún PDB bloquea interrupciones"
  fi
}

# Espacio libre del sistema de archivos del kubelet (normalmente /), vía stats del nodo.
check_node_disk() {
  node=$1
  min_mb=$2
  avail=$(k get --raw "/api/v1/nodes/$node/proxy/stats/summary" 2>/dev/null | jq_ '.node.fs.availableBytes // ""')
  if [ -z "$avail" ]; then
    warn_check "$node: no se pudo leer el espacio libre"
    return 0
  fi
  mb=$((avail / 1048576))
  if [ "$mb" -lt "$min_mb" ]; then
    fail_check "$node: $mb MB libres en / (mínimo $min_mb)"
  else
    ok "$node: $mb MB libres en /"
  fi
}

# ------------------------------------------------------------------ nodo actualizado
check_node_upgraded() {
  node=$1
  kernel=$2
  plan=$3
  hash=$4
  j=$(node_json "$node")
  os=$(echo "$j" | jq_ '.status.nodeInfo.osImage')
  kv=$(echo "$j" | jq_ '.status.nodeInfo.kernelVersion')
  ready=$(echo "$j" | jq_ '.status.conditions[] | select(.type == "Ready") | .status')
  unsched=$(echo "$j" | jq_ '.spec.unschedulable // false')
  label=$(echo "$j" | jq_ ".metadata.labels[\"plan.upgrade.cattle.io/$plan\"] // \"\"")
  problems=""
  case "$os" in *"Ubuntu 24.04"*) ;; *) problems="$problems; sistema '$os'" ;; esac
  [ "$kv" = "$kernel" ] || problems="$problems; kernel '$kv' (esperado $kernel)"
  [ "$ready" = "True" ] || problems="$problems; no Ready"
  [ "$unsched" != "true" ] || problems="$problems; sigue cordoneado"
  [ "$label" = "$hash" ] || problems="$problems; el Plan $plan no figura como terminado"
  if [ -n "$problems" ]; then
    fail_check "$node:${problems#;}"
  else
    ok "$node: $os, kernel $kv, Ready y schedulable"
  fi
}

check_daemonsets() {
  bad=$(k get ds -A -o json | jq_ '.items[] | select((.status.numberReady // 0) < (.status.desiredNumberScheduled // 0)) | .metadata.namespace + "/" + .metadata.name + " (" + ((.status.numberReady // 0) | tostring) + "/" + ((.status.desiredNumberScheduled // 0) | tostring) + ")"')
  if [ -n "$bad" ]; then
    fail_check "DaemonSets incompletos: $(echo "$bad" | tr '\n' ' ')"
  else
    ok "todos los DaemonSets completos"
  fi
}

# Pods del nodo en mal estado (fallidos, pendientes o en bucle de reinicios).
check_node_pods() {
  node=$1
  bad=$(k get pods -A --field-selector "spec.nodeName=$node" -o json | jq_ '
    .items[]
    | select(
        (.status.phase != "Running" and .status.phase != "Succeeded")
        or ([.status.containerStatuses[]? | select(.state.waiting.reason == "CrashLoopBackOff" or .state.waiting.reason == "ImagePullBackOff" or .state.waiting.reason == "ErrImagePull")] | length > 0))
    | .metadata.namespace + "/" + .metadata.name + " (" + .status.phase + ")"')
  if [ -n "$bad" ]; then
    fail_check "$node: pods con problemas: $(echo "$bad" | tr '\n' ' ')"
  else
    ok "$node: todos sus pods en marcha"
  fi
}

# Prueba de DNS y red desde el nodo: un pod en ese nodo resuelve el servicio de la API.
check_node_dns() {
  node=$1
  image=$2
  # Nombre DNS-1123: printf (sin salto de línea final), solo [a-z0-9-] y sin guion al final.
  pod="os-upgrade-nettest-$(printf '%s' "$node" | tr -c 'a-z0-9-' '-' | cut -c1-40 | sed 's/-*$//')"
  k -n "$NS" delete pod "$pod" --ignore-not-found >/dev/null 2>&1 || true
  overrides="{\"spec\":{\"nodeName\":\"$node\",\"tolerations\":[{\"operator\":\"Exists\"}]}}"
  if ! k -n "$NS" run "$pod" --image="$image" --restart=Never --overrides="$overrides" \
      --command -- getent hosts kubernetes.default.svc.cluster.local >/dev/null 2>&1; then
    fail_check "$node: no se pudo crear el pod de prueba de red"
    return 1
  fi
  if k -n "$NS" wait "pod/$pod" --for=jsonpath='{.status.phase}'=Succeeded --timeout=120s >/dev/null 2>&1; then
    ok "$node: DNS y red del clúster funcionan ($(k -n "$NS" logs "$pod" 2>/dev/null | head -n1))"
    rc=0
  else
    fail_check "$node: la prueba de DNS falló: $(k -n "$NS" logs "$pod" 2>&1 | head -n3 | tr '\n' ' ')"
    rc=1
  fi
  k -n "$NS" delete pod "$pod" --ignore-not-found >/dev/null 2>&1 || true
  return $rc
}
