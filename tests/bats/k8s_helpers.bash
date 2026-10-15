# Fake cluster for the rollout.sh, preflight.sh and check-cluster.sh tests.
# 3 control planes (cp1 etcd leader, cp2, cp3) and 2 workers (w1, w2), all on 22.04.

# shellcheck disable=SC2034 # variables used from the .bats files
REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
# shellcheck disable=SC2034
ROLLOUT="$REPO/scripts/rollout.sh"
# shellcheck disable=SC2034
PREFLIGHT="$REPO/scripts/preflight.sh"
# shellcheck disable=SC2034
CHECK_CLUSTER="$REPO/scripts/check-cluster.sh"
TARGET_KERNEL=6.8.0-139-generic
H_PRE=hpre1 H_W=hw1 H_CP=hcp1

y() { "$YQ" "$@"; }

setup_cluster() {
  export K8S="$BATS_TEST_TMPDIR/k8s"
  export YQ="$REPO/tools/bin/yq"
  export PATH="$REPO/tests/k8s-stubs:$PATH"
  export POLL_SECONDS=0 RETRY_SLEEP=0 ETCD_RETRIES=1
  export CONFIRM_TTY="$K8S/answers"
  unset ASSUME_YES DRY_RUN SETTLE_TIMEOUT
  mkdir -p "$K8S/frames" "$K8S/nodepods" "$K8S/stats"
  : > "$K8S/answers"
  : > "$K8S/calls.log"

  echo '{"apiVersion":"v1","kind":"List","items":[]}' > "$K8S/nodes.json"
  add_node cp1 cp 10.0.0.1 3
  add_node cp2 cp 10.0.0.2 3
  add_node cp3 cp 10.0.0.3 3
  add_node w1 worker 10.0.0.11 1
  add_node w2 worker 10.0.0.12 1

  cat > "$K8S/plans.json" <<EOF
{"items":[
 $(plan_obj os-upgrade-predownload $H_PRE),
 $(plan_obj os-upgrade-workers $H_W),
 $(plan_obj os-upgrade-cp $H_CP),
 {"metadata":{"name":"system-agent-upgrader-x"},"status":{"latestHash":"r1"}}
]}
EOF
  echo "{\"items\":[{\"metadata\":{\"name\":\"os-upgrade-config-abc\"},\"data\":{\"KERNEL_VERSION\":\"$TARGET_KERNEL\",\"MIN_FREE_ROOT_MB\":\"5000\"}}]}" > "$K8S/configmaps.json"
  echo '{"spec":{"template":{"spec":{"containers":[{"image":"rancher/system-upgrade-controller:v0.16.3","env":[]}]}}},"status":{"availableReplicas":1}}' > "$K8S/deploy.json"
  cat > "$K8S/ks-pods.json" <<'EOF'
{"items":[
 {"metadata":{"name":"etcd-cp1","labels":{"component":"etcd"}},"spec":{"nodeName":"cp1"},"status":{"phase":"Running","containerStatuses":[{"ready":true}]}},
 {"metadata":{"name":"etcd-cp2","labels":{"component":"etcd"}},"spec":{"nodeName":"cp2"},"status":{"phase":"Running","containerStatuses":[{"ready":true}]}},
 {"metadata":{"name":"etcd-cp3","labels":{"component":"etcd"}},"spec":{"nodeName":"cp3"},"status":{"phase":"Running","containerStatuses":[{"ready":true}]}}
]}
EOF
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    https://10.0.0.1:2379 aaaa000000000001 true 1000 "" true cp1-1a2b \
    https://10.0.0.2:2379 aaaa000000000002 false 1000 "" true cp2-3c4d \
    https://10.0.0.3:2379 aaaa000000000003 false 1001 "" true cp3-5e6f > "$K8S/etcd.tsv"
  snapshot_age_hours 1
}

plan_obj() {
  echo "{\"metadata\":{\"name\":\"$1\"},\"spec\":{\"upgrade\":{\"image\":\"docker.io/library/ubuntu:24.04\",\"envFrom\":[{\"configMapRef\":{\"name\":\"os-upgrade-config-abc\"}}]}},\"status\":{\"latestHash\":\"$2\",\"applying\":[]}}"
}

add_node() {
  local name=$1 role=$2 ip=$3 group=$4 cp=""
  [ "$role" = cp ] && cp=',"node-role.kubernetes.io/control-plane":"true"'
  y -i -p json -o json ".items += [{
    \"metadata\":{\"name\":\"$name\",\"labels\":{\"kubernetes.io/hostname\":\"$name\",\"os-upgrade-group\":\"$group\"$cp}},
    \"spec\":{},
    \"status\":{\"addresses\":[{\"type\":\"InternalIP\",\"address\":\"$ip\"}],
      \"nodeInfo\":{\"osImage\":\"Ubuntu 22.04.5 LTS\",\"kernelVersion\":\"5.15.0-100-generic\"},
      \"conditions\":[{\"type\":\"Ready\",\"status\":\"True\"}]}}]" "$K8S/nodes.json"
}

set_label() { y -i -p json -o json "(.items[] | select(.metadata.name == \"$1\")).metadata.labels[\"$2\"] = \"$3\"" "$K8S/nodes.json"; }
label_of() { y -p json ".items[] | select(.metadata.name == \"$1\") | .metadata.labels[\"$2\"] // \"\"" "$K8S/nodes.json"; }
set_applying() { y -i -p json -o json "(.items[] | select(.metadata.name == \"$1\")).status.applying = [\"$2\"]" "$K8S/plans.json"; }
snapshot_age_hours() {
  echo "{\"items\":[{\"metadata\":{\"name\":\"s1\",\"creationTimestamp\":\"$(date -u -d "-$1 hour" +%FT%TZ)\"}}]}" > "$K8S/snapshots.json"
}
set_etcd() { # set_etcd <row 1-3> <column 1-7> <value>
  awk -F'\t' -v OFS='\t' -v r="$1" -v c="$2" -v v="$3" 'NR == r {$c = v} {print}' "$K8S/etcd.tsv" > "$K8S/etcd.tmp"
  mv "$K8S/etcd.tmp" "$K8S/etcd.tsv"
}
answers() { printf '%s\n' "$@" > "$K8S/answers"; }
called() { grep -q -- "$1" "$K8S/calls.log"; }
not_called() { ! grep -q -- "$1" "$K8S/calls.log"; }
line_of() { grep -n -- "$1" "$K8S/calls.log" | head -n1 | cut -d: -f1; }

# ------------------------------------------------------------------ Job frames
# Container state: running | ok | fail | (empty: does not exist)
ctr() {
  local name=$1 st=$2
  case "$st" in
    running) echo "{\"name\":\"$name\",\"state\":{\"running\":{\"startedAt\":\"${3:-$(date -u +%FT%TZ)}\"}}}" ;;
    ok) echo "{\"name\":\"$name\",\"state\":{\"terminated\":{\"exitCode\":0,\"startedAt\":\"2026-01-01T00:00:00Z\"}}}" ;;
    fail) echo "{\"name\":\"$name\",\"state\":{\"terminated\":{\"exitCode\":1,\"startedAt\":\"2026-01-01T00:00:00Z\"}}}" ;;
  esac
}
join_ctrs() { local IFS=,; echo "$*"; }

# frame <plan> <node> <n> <prepare> <drain> <upgrade> <job: active|complete|failed> [yq expr for the node]
# States accept "running@date" to set the start time.
frame() {
  local plan=$1 node=$2 n=$3 p=$4 d=$5 u=$6 job=$7 expr=${8:-}
  local dir="$K8S/frames/$plan/$node" hash init main pods cond
  mkdir -p "$dir"
  case "$plan" in os-upgrade-workers) hash=$H_W ;; os-upgrade-cp) hash=$H_CP ;; *) hash=$H_PRE ;; esac
  init=() main=()
  [ -z "$p" ] || init+=("$(ctr prepare "${p%%@*}" "$( [[ $p == *@* ]] && echo "${p#*@}")")")
  [ -z "$d" ] || init+=("$(ctr drain "${d%%@*}" "$( [[ $d == *@* ]] && echo "${d#*@}")")")
  [ -z "$u" ] || main+=("$(ctr upgrade "${u%%@*}")")
  if [ "$p$d$u" = "none" ] || [ -z "$p$d$u" ]; then
    pods='{"items":[]}'
  else
    pods="{\"items\":[{\"metadata\":{\"name\":\"apply-$node-$n\",\"creationTimestamp\":\"2026-10-15T10:00:0${n}Z\"},\"status\":{\"initContainerStatuses\":[$(join_ctrs "${init[@]}")],\"containerStatuses\":[$(join_ctrs "${main[@]}")]}}]}"
  fi
  case "$job" in
    complete) cond='[{"type":"Complete","status":"True"}]' ;;
    failed) cond='[{"type":"Failed","status":"True","reason":"BackoffLimitExceeded"}]' ;;
    *) cond='[]' ;;
  esac
  echo "$pods" > "$dir/$n.pods.json"
  echo "{\"items\":[{\"metadata\":{\"name\":\"apply-$plan-on-$node\",\"labels\":{\"plan.upgrade.cattle.io/$plan\":\"$hash\"}},\"status\":{\"conditions\":$cond}}]}" > "$dir/$n.jobs.json"
  [ -z "$expr" ] || echo "$expr" > "$dir/$n.node"
}

# yq expression that leaves the node as upgraded by the Plan.
upgraded_expr() {
  local plan=$1 hash=$2 kernel=${3:-$TARGET_KERNEL} os=${4:-Ubuntu 24.04.3 LTS}
  echo ".metadata.labels[\"plan.upgrade.cattle.io/$plan\"] = \"$hash\" | .status.nodeInfo.osImage = \"$os\" | .status.nodeInfo.kernelVersion = \"$kernel\" | .spec.unschedulable = false"
}

# 24.04 -> 26.04 campaign in the Plans ConfigMap.
set_target_2604() {
  y -i -p json -o json '.items[0].data.TARGET_VERSION = "26.04" | .items[0].data.KERNEL_VERSION = "7.0.0-38-generic"' "$K8S/configmaps.json"
}

# Complete, successful upgrade of a node.
scenario_success() {
  local node=$1 plan=$2 hash=$3
  frame "$plan" "$node" 1 running "" "" active
  frame "$plan" "$node" 2 ok running "" active '.spec.unschedulable = true'
  frame "$plan" "$node" 3 ok ok running active
  frame "$plan" "$node" 4 "" "" "" active
  frame "$plan" "$node" 5 ok ok ok complete "$(upgraded_expr "$plan" "$hash")"
}
