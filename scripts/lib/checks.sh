# shellcheck shell=sh
# Checks with a verdict. Each check_* prints one [OK]/[WARN]/[FAIL] line with the details
# and returns 0 (OK or warning) or 1 (failure). Requires common.sh and k8s.sh.

ETCD_MIN_MEMBERS="${ETCD_MIN_MEMBERS:-3}"
ETCD_RAFT_MAX_LAG="${ETCD_RAFT_MAX_LAG:-100}"
ETCD_RETRIES="${ETCD_RETRIES:-3}"
SNAPSHOT_MAX_AGE_HOURS="${SNAPSHOT_MAX_AGE_HOURS:-24}"
RETRY_SLEEP="${RETRY_SLEEP:-5}"

CHECK_FAILS=0
CHECK_WARNS=0

ok() { echo "[OK]    $*"; }
warn_check() {
  echo "[WARN]  $*"
  CHECK_WARNS=$((CHECK_WARNS + 1))
}
fail_check() {
  echo "[FAIL]  $*"
  CHECK_FAILS=$((CHECK_FAILS + 1))
  return 1
}

# ------------------------------------------------------------------ cluster
check_api() {
  if k get --raw /readyz >/dev/null 2>&1; then
    ok "Kubernetes API reachable (context $(k config current-context 2>/dev/null || echo '?'))"
  else
    fail_check "cannot reach the Kubernetes API; check KUBECONFIG"
  fi
}

check_suc() {
  d=$(k -n "$NS" get deploy system-upgrade-controller -o json 2>/dev/null) \
    || { fail_check "deployment system-upgrade-controller not found in $NS"; return 1; }
  avail=$(echo "$d" | jq_ '.status.availableReplicas // 0')
  image=$(echo "$d" | jq_ '.spec.template.spec.containers[0].image')
  backoff=$(echo "$d" | jq_ '[.spec.template.spec.containers[0].env[] | select(.name == "SYSTEM_UPGRADE_JOB_BACKOFF_LIMIT") | .value][0] // "2 (default)"')
  if [ "$avail" -ge 1 ]; then
    ok "system-upgrade-controller running ($image, Job backoffLimit: $backoff)"
  else
    fail_check "system-upgrade-controller has no available replicas"
  fi
}

check_plans() {
  missing=""
  for p in "$PLAN_PREDOWNLOAD" "$PLAN_WORKERS" "$PLAN_CP"; do
    plan_json "$p" >/dev/null 2>&1 || missing="$missing $p"
  done
  if [ -n "$missing" ]; then
    fail_check "missing Plans:$missing (make render + kubectl apply)"
    return 1
  fi
  kernel=$(config_value KERNEL_VERSION || true)
  [ -n "$kernel" ] || { fail_check "the Plans ConfigMap does not define KERNEL_VERSION"; return 1; }
  ok "os-upgrade Plans present (target kernel $kernel)"
}

# Rancher's Plans (RKE2 upgrades) must not be running at the same time.
check_rancher_plans_idle() {
  busy=$(k -n "$NS" get plans -o json | jq_ '.items[] | select(.metadata.name | test("^system-agent-upgrader")) | select((.status.applying // []) | length > 0) | .metadata.name + ": " + (.status.applying | join(","))')
  if [ -n "$busy" ]; then
    fail_check "Rancher Plans are being applied; freeze RKE2 upgrades before continuing: $busy"
  else
    ok "no Rancher Plan (system-agent-upgrader) in progress"
  fi
}

# No node upgrading, except the given one (to resume).
check_os_upgrade_idle() {
  except=${1:-}
  busy=""
  for p in "$PLAN_WORKERS" "$PLAN_CP"; do
    for n in $(plan_applying "$p"); do
      [ "$n" = "$except" ] || busy="$busy $p:$n"
    done
  done
  if [ -n "$busy" ]; then
    fail_check "other nodes are being upgraded:$busy"
  else
    ok "no other node being upgraded"
  fi
}

# For preflight: a node left halfway by a previous campaign does not block starting
# (rollout.sh resumes it before the others), but the operator must know.
check_os_upgrade_in_progress() {
  busy=""
  for p in "$PLAN_WORKERS" "$PLAN_CP"; do
    for n in $(plan_applying "$p"); do busy="$busy $n"; done
  done
  if [ -n "$busy" ]; then
    warn_check "nodes with an upgrade in progress (rollout.sh resumes them first):$busy"
  else
    ok "no node being upgraded"
  fi
}

check_nodes_ready() {
  bad=$(nodes_json | jq_ '.items[] | select([.status.conditions[] | select(.type == "Ready" and .status == "True")] | length == 0) | .metadata.name')
  if [ -n "$bad" ]; then
    fail_check "nodes not Ready: $(echo "$bad" | tr '\n' ' ')"
  else
    ok "all nodes Ready"
  fi
  cordoned=$(nodes_json | jq_ '.items[] | select(.spec.unschedulable == true) | .metadata.name')
  if [ -n "$cordoned" ]; then
    warn_check "cordoned nodes: $(echo "$cordoned" | tr '\n' ' ')"
  fi
  [ -z "$bad" ]
}

# etcd: enough members, all healthy, exactly one leader and RAFT INDEX in sync.
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
      reason="$members members (minimum $ETCD_MIN_MEMBERS)"
    elif [ "$n_status" -lt "$members" ] || [ "$n_healthy" -lt "$members" ]; then
      reason="members not responding or unhealthy ($n_healthy/$members healthy) $(echo "$unhealthy" | tr '\n' ' ')"
    elif [ -n "$errors" ]; then
      reason="errors: $errors"
    elif [ -n "$alarms" ]; then
      reason="active alarms: $(echo "$alarms" | tr '\n' ' ')"
    elif [ "$leaders" -ne 1 ]; then
      reason="$leaders leaders (there must be 1)"
    elif [ "$lag" -gt "$ETCD_RAFT_MAX_LAG" ]; then
      reason="RAFT INDEX out of sync (difference $lag > $ETCD_RAFT_MAX_LAG)"
    fi

    if [ -z "$reason" ]; then
      ok "etcd healthy: $members members, 1 leader, RAFT INDEX difference $lag"
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
    warn_check "could not query etcdsnapshotfiles; check manually that there is a recent snapshot"
    return 0
  }
  newest=$(echo "$snaps" | jq_ '[.items[] | (.status.creationTime // .metadata.creationTimestamp)] | sort | .[-1] // ""')
  if [ -z "$newest" ]; then
    fail_check "no etcd snapshots; take one before starting"
    return 1
  fi
  age_h=$(( ($(now) - $(to_epoch "$newest")) / 3600 ))
  if [ "$age_h" -gt "$SNAPSHOT_MAX_AGE_HOURS" ]; then
    fail_check "the latest etcd snapshot is ${age_h} h old ($newest); maximum ${SNAPSHOT_MAX_AGE_HOURS} h"
  else
    ok "recent etcd snapshot ($newest, ${age_h} h ago)"
  fi
}

# PDBs that currently allow no disruption: they would block the drain.
check_pdbs() {
  blocked=$(k get pdb -A -o json | jq_ '.items[] | select((.status.disruptionsAllowed // 0) == 0) | .metadata.namespace + "/" + .metadata.name')
  if [ -n "$blocked" ]; then
    warn_check "PDBs with no disruptions allowed (they may block the drain): $(echo "$blocked" | tr '\n' ' ')"
  else
    ok "no PDB blocks disruptions"
  fi
}

# Free space on the kubelet filesystem (usually /), via the node stats.
check_node_disk() {
  node=$1
  min_mb=$2
  avail=$(k get --raw "/api/v1/nodes/$node/proxy/stats/summary" 2>/dev/null | jq_ '.node.fs.availableBytes // ""')
  if [ -z "$avail" ]; then
    warn_check "$node: could not read free space"
    return 0
  fi
  mb=$((avail / 1048576))
  if [ "$mb" -lt "$min_mb" ]; then
    fail_check "$node: $mb MB free on / (minimum $min_mb)"
  else
    ok "$node: $mb MB free on /"
  fi
}

# ------------------------------------------------------------------ upgraded node
check_node_upgraded() {
  node=$1
  kernel=$2
  plan=$3
  hash=$4
  target=$5
  j=$(node_json "$node")
  os=$(echo "$j" | jq_ '.status.nodeInfo.osImage')
  kv=$(echo "$j" | jq_ '.status.nodeInfo.kernelVersion')
  ready=$(echo "$j" | jq_ '.status.conditions[] | select(.type == "Ready") | .status')
  unsched=$(echo "$j" | jq_ '.spec.unschedulable // false')
  label=$(echo "$j" | jq_ ".metadata.labels[\"plan.upgrade.cattle.io/$plan\"] // \"\"")
  problems=""
  case "$os" in *"Ubuntu $target"*) ;; *) problems="$problems; OS '$os' (expected Ubuntu $target)" ;; esac
  [ "$kv" = "$kernel" ] || problems="$problems; kernel '$kv' (expected $kernel)"
  [ "$ready" = "True" ] || problems="$problems; not Ready"
  [ "$unsched" != "true" ] || problems="$problems; still cordoned"
  [ "$label" = "$hash" ] || problems="$problems; Plan $plan not marked as complete"
  if [ -n "$problems" ]; then
    fail_check "$node:${problems#;}"
  else
    ok "$node: $os, kernel $kv, Ready and schedulable"
  fi
}

check_daemonsets() {
  bad=$(k get ds -A -o json | jq_ '.items[] | select((.status.numberReady // 0) < (.status.desiredNumberScheduled // 0)) | .metadata.namespace + "/" + .metadata.name + " (" + ((.status.numberReady // 0) | tostring) + "/" + ((.status.desiredNumberScheduled // 0) | tostring) + ")"')
  if [ -n "$bad" ]; then
    fail_check "incomplete DaemonSets: $(echo "$bad" | tr '\n' ' ')"
  else
    ok "all DaemonSets complete"
  fi
}

# Pods on the node in a bad state (failed, pending or crash looping). SUC Job pods are not
# counted: the ones running during the reboot always end up Failed.
check_node_pods() {
  node=$1
  bad=$(k get pods -A --field-selector "spec.nodeName=$node" -o json | jq_ '
    .items[]
    | select((.metadata.labels["upgrade.cattle.io/controller"] // "") == "")
    | select(
        (.status.phase != "Running" and .status.phase != "Succeeded")
        or ([.status.containerStatuses[]? | select(.state.waiting.reason == "CrashLoopBackOff" or .state.waiting.reason == "ImagePullBackOff" or .state.waiting.reason == "ErrImagePull")] | length > 0))
    | .metadata.namespace + "/" + .metadata.name + " (" + .status.phase + ")"')
  if [ -n "$bad" ]; then
    fail_check "$node: pods with problems: $(echo "$bad" | tr '\n' ' ')"
  else
    ok "$node: all its pods running"
  fi
}

# DNS and network test from the node: a pod on that node resolves the API service.
check_node_dns() {
  node=$1
  image=$2
  # DNS-1123 name: printf (no trailing newline), only [a-z0-9-] and no trailing dash.
  pod="os-upgrade-nettest-$(printf '%s' "$node" | tr -c 'a-z0-9-' '-' | cut -c1-40 | sed 's/-*$//')"
  k -n "$NS" delete pod "$pod" --ignore-not-found >/dev/null 2>&1 || true
  overrides="{\"spec\":{\"nodeName\":\"$node\",\"tolerations\":[{\"operator\":\"Exists\"}]}}"
  if ! k -n "$NS" run "$pod" --image="$image" --restart=Never --overrides="$overrides" \
      --command -- getent hosts kubernetes.default.svc.cluster.local >/dev/null 2>&1; then
    fail_check "$node: could not create the network test pod"
    return 1
  fi
  if k -n "$NS" wait "pod/$pod" --for=jsonpath='{.status.phase}'=Succeeded --timeout=120s >/dev/null 2>&1; then
    ok "$node: cluster DNS and network work ($(k -n "$NS" logs "$pod" 2>/dev/null | head -n1))"
    rc=0
  else
    fail_check "$node: the DNS test failed: $(k -n "$NS" logs "$pod" 2>&1 | head -n3 | tr '\n' ' ')"
    rc=1
  fi
  k -n "$NS" delete pod "$pod" --ignore-not-found >/dev/null 2>&1 || true
  return $rc
}
