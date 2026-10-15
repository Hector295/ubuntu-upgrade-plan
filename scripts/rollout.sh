#!/bin/sh
# Upgrade orchestrator: launches nodes one at a time, watches every phase, verifies the
# result and asks for confirmation before the next one.
#
# Usage:
#   rollout.sh predownload (--group G | --nodes n1,n2) [--wait] [--dry-run] [--yes]
#   rollout.sh upgrade     (--group G | --nodes n1,n2) [--dry-run] [--yes]
#                          [--drain-timeout 30m] [--prepare-timeout 15m] [--node-timeout 4h]
#                          [--skip-net-test]
#   rollout.sh status      [--group G | --nodes n1,n2]
#
# upgrade:
#   order          workers -> non-leader control planes -> etcd leader (move-leader first)
#   before each    API, SUC, Plans, nodes Ready, etcd healthy, nothing else upgrading
#   during         prepare and drain with timeouts: if they fail, the node is held
#                  (os-upgrade=hold) untouched; if the upgrade fails, it stops and leaves it as is
#   after          target version + kernel, Ready, DaemonSets, pods, DNS, etcd -> os-upgrade=done
#   --dry-run      shows the plan and runs the checks, without changing anything
#   --yes          no questions (when the drain times out, the node is aborted)
set -eu

# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
# shellcheck source=lib/k8s.sh
. "$LIB_DIR/k8s.sh"
# shellcheck source=lib/checks.sh
. "$LIB_DIR/checks.sh"

POLL_SECONDS="${POLL_SECONDS:-15}"
SETTLE_TIMEOUT="${SETTLE_TIMEOUT:-5m}"
PREDOWNLOAD_TIMEOUT="${PREDOWNLOAD_TIMEOUT:-2h}"
DRAIN_TIMEOUT=30m
PREPARE_TIMEOUT=15m
NODE_TIMEOUT=4h
SKIP_NET_TEST=false
WAIT=false

usage() {
  sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

# ------------------------------------------------------------------ arguments
MODE=${1:-}
[ -n "$MODE" ] || usage
shift
GROUP=""
NODES_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --group) [ $# -ge 2 ] || usage; GROUP=$2; shift 2 ;;
    --nodes) [ $# -ge 2 ] || usage; NODES_ARG=$2; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --yes) ASSUME_YES=true; shift ;;
    --wait) WAIT=true; shift ;;
    --drain-timeout) [ $# -ge 2 ] || usage; DRAIN_TIMEOUT=$2; shift 2 ;;
    --prepare-timeout) [ $# -ge 2 ] || usage; PREPARE_TIMEOUT=$2; shift 2 ;;
    --node-timeout) [ $# -ge 2 ] || usage; NODE_TIMEOUT=$2; shift 2 ;;
    --skip-net-test) SKIP_NET_TEST=true; shift ;;
    -h|--help) usage ;;
    *) err "unknown option: $1"; usage ;;
  esac
done
seconds_of() {
  to_seconds "$2" || die "invalid duration in $1: '$2' (use e.g. 90s, 30m, 2h)"
}
DRAIN_TIMEOUT_S=$(seconds_of --drain-timeout "$DRAIN_TIMEOUT")
PREPARE_TIMEOUT_S=$(seconds_of --prepare-timeout "$PREPARE_TIMEOUT")
NODE_TIMEOUT_S=$(seconds_of --node-timeout "$NODE_TIMEOUT")
SETTLE_TIMEOUT_S=$(seconds_of SETTLE_TIMEOUT "$SETTLE_TIMEOUT")
PREDOWNLOAD_TIMEOUT_S=$(seconds_of PREDOWNLOAD_TIMEOUT "$PREDOWNLOAD_TIMEOUT")

# ------------------------------------------------------------------ node selection
selected_nodes() {
  if [ -n "$NODES_ARG" ]; then
    echo "$NODES_ARG" | tr ',' '\n' | sed '/^$/d'
  elif [ -n "$GROUP" ]; then
    nodes_by_selector "os-upgrade-group=$GROUP"
  elif [ "$MODE" = status ]; then
    nodes_json | jq_ '.items[].metadata.name' | sort
  else
    die "specify --group G or --nodes n1,n2"
  fi
}

# ------------------------------------------------------------------ node phases
# State of a pod container: "state code start" (state: running|terminated|waiting).
ctr_state() {
  list=$2
  echo "$1" | jq_ "(.status.$list // [])[] | select(.name == \"$3\") | ((.state | keys | .[0]) + \" \" + ((.state.terminated.exitCode // \"-\") | tostring) + \" \" + (.state.running.startedAt // .state.terminated.startedAt // \"-\"))"
}

# Phase of the newest pod and its start time (epoch): "<phase> <start>".
# Phases: none|starting|prepare|prepare-failed|drain|drain-failed|upgrade|upgrade-ended.
# Everything is returned on stdout: the function is called inside $(...).
pod_phase() {
  pod=$1
  start=$(now)
  if [ "$(echo "$pod" | jq_ '.metadata.name // ""')" = "" ]; then echo "none $start"; return; fi
  # shellcheck disable=SC2046
  set -- $(ctr_state "$pod" initContainerStatuses prepare) - - -
  p_state=$1 p_exit=$2 p_start=$3
  # shellcheck disable=SC2046
  set -- $(ctr_state "$pod" initContainerStatuses drain) - - -
  d_state=$1 d_exit=$2 d_start=$3
  # shellcheck disable=SC2046
  set -- $(ctr_state "$pod" containerStatuses upgrade) - - -
  u_state=$1

  if [ "$p_state" = terminated ] && [ "$p_exit" != 0 ]; then echo "prepare-failed $start"; return; fi
  if [ "$p_state" = running ]; then
    [ "$p_start" = - ] || start=$(to_epoch "$p_start")
    echo "prepare $start"; return
  fi
  if [ "$d_state" = terminated ] && [ "$d_exit" != 0 ]; then echo "drain-failed $start"; return; fi
  if [ "$d_state" = running ]; then
    [ "$d_start" = - ] || start=$(to_epoch "$d_start")
    echo "drain $start"; return
  fi
  case "$u_state" in
    running) echo "upgrade $start" ;;
    terminated) echo "upgrade-ended $start" ;;
    *) echo "starting $start" ;;
  esac
}

job_failed() {
  node_jobs_json "$1" "$2" | jq_ "[.items[] | select(.metadata.labels[\"plan.upgrade.cattle.io/$2\"] == \"$3\") | select([.status.conditions[]? | select(.type == \"Failed\" and .status == \"True\")] | length > 0)] | length"
}

node_pod_name() { node_pod_json "$1" "$2" | jq_ '.metadata.name // ""'; }

# Holds the node: no Plan selects it again and its Job is deleted.
hold_node() {
  mutate k label node "$1" os-upgrade=hold --overwrite >/dev/null
  mutate k -n "$NS" delete job -l "upgrade.cattle.io/plan=$2,upgrade.cattle.io/node=$1" --ignore-not-found >/dev/null
  info "$1: held with os-upgrade=hold and Job deleted"
}

show_logs() {
  pod=$(node_pod_name "$1" "$2")
  [ -n "$pod" ] || return 0
  echo "----- last lines of $3 ($pod)"
  k -n "$NS" logs "$pod" -c "$3" --tail=25 2>&1 | sed 's/^/  /' || true
  echo "-----"
}

# Pods the drain has not evicted yet (excluding DaemonSets and static pods).
show_drain_blockers() {
  node=$1
  echo "Pods still on $node:"
  k get pods -A --field-selector "spec.nodeName=$node" -o json | jq_ '
    .items[]
    | select([.metadata.ownerReferences[]? | select(.kind == "DaemonSet" or .kind == "Node")] | length == 0)
    | select((.metadata.labels["upgrade.cattle.io/controller"] // "") == "")
    | "  " + .metadata.namespace + "/" + .metadata.name' || true
  check_pdbs || true
}

on_prepare_failed() {
  err "$1: the node preflight (prepare) failed. The node was NOT drained or modified."
  show_logs "$1" "$2" prepare
  hold_node "$1" "$2"
  die "Rollout stopped. Fix the cause (see docs/runbook.md, 'prepare fails') and relaunch: kubectl label node $1 os-upgrade- && $0 upgrade ..."
}

on_drain_stuck() {
  node=$1
  plan=$2
  why=$3
  warn "$node: $why"
  show_drain_blockers "$node"
  choice=$(ask_choice "[w]ait $DRAIN_TIMEOUT more / [a]bort: hold the node and uncordon [a]:" a)
  case "$choice" in
    w|W|e|E) return 0 ;;
  esac
  # Safe: the upgrade container has not started yet, the node's system is untouched.
  hold_node "$node" "$plan"
  mutate k uncordon "$node" >/dev/null
  die "Rollout stopped: drain aborted on $node (uncordon done). Resolve the pods/PDBs blocking it and relaunch."
}

on_job_failed() {
  err "$1: $3"
  node_jobs_json "$1" "$2" | jq_ '.items[] | "  Job " + .metadata.name + ": " + ([.status.conditions[]? | .type + "=" + .status + " " + (.reason // "") + " " + (.message // "")] | join("; "))' || true
  show_logs "$1" "$2" upgrade
  die "Rollout stopped. $1 is still cordoned and has os-upgrade=upgrade. On the node: sh /usr/local/sbin/os-upgrade.sh status; see docs/runbook.md, 'The Job failed after the drain'."
}

# Waits for the Plan to finish on the node. Exits the script if something fails.
wait_node() {
  node=$1
  plan=$2
  hash=$3
  started=$(now)
  drain_extra=0
  upgrade_started=false
  last=""
  while :; do
    if [ "$(node_label "$node" "plan.upgrade.cattle.io/$plan")" = "$hash" ]; then
      info "$node: Plan $plan complete"
      return 0
    fi
    phase_info=$(pod_phase "$(node_pod_json "$node" "$plan")")
    phase=${phase_info% *}
    phase_start=${phase_info#* }
    case "$phase" in upgrade|upgrade-ended) upgrade_started=true ;; esac
    if [ "$phase" != "$last" ]; then
      case "$phase" in
        none)
          if is_true "$upgrade_started"; then
            info "$node: no pod (reboot in progress or new Job)"
          else
            info "$node: waiting for the SUC to create the Job"
          fi ;;
        starting) info "$node: starting pod" ;;
        prepare) info "$node: prepare (preflight on the node)" ;;
        drain) info "$node: drain" ;;
        upgrade) info "$node: upgrade in progress (details on the node: journalctl -fu os-upgrade-release)" ;;
        upgrade-ended) info "$node: upgrade container ended (reboot or finish); waiting" ;;
      esac
      last=$phase
    fi

    if [ "$(job_failed "$node" "$plan" "$hash")" -gt 0 ]; then
      if ! is_true "$upgrade_started" && [ "$phase" = prepare-failed ]; then on_prepare_failed "$node" "$plan"; fi
      on_job_failed "$node" "$plan" "the Job of Plan $plan has failed"
    fi
    case "$phase" in
      prepare-failed)
        if is_true "$upgrade_started"; then
          on_job_failed "$node" "$plan" "prepare failed after the upgrade had started"
        fi
        on_prepare_failed "$node" "$plan" ;;
      prepare)
        if ! is_true "$upgrade_started" && [ $(( $(now) - phase_start )) -gt "$PREPARE_TIMEOUT_S" ]; then
          warn "$node: prepare has been running for more than $PREPARE_TIMEOUT"
          on_prepare_failed "$node" "$plan"
        fi ;;
      drain-failed)
        is_true "$upgrade_started" || on_drain_stuck "$node" "$plan" "the drain container failed" ;;
      drain)
        if ! is_true "$upgrade_started" && [ $(( $(now) - phase_start )) -gt $((DRAIN_TIMEOUT_S + drain_extra)) ]; then
          on_drain_stuck "$node" "$plan" "the drain has been running for more than $(( (DRAIN_TIMEOUT_S + drain_extra) / 60 )) min"
          drain_extra=$((drain_extra + DRAIN_TIMEOUT_S))
        fi ;;
    esac
    if [ $(( $(now) - started )) -gt "$NODE_TIMEOUT_S" ]; then
      on_job_failed "$node" "$plan" "not finished after $NODE_TIMEOUT"
    fi
    sleep "$POLL_SECONDS"
  done
}

# Checks after the upgrade; retries until SETTLE_TIMEOUT (DaemonSets and pods take a while
# to settle after the reboot).
verify_node() {
  node=$1
  plan=$2
  hash=$3
  kernel=$4
  deadline=$(( $(now) + SETTLE_TIMEOUT_S ))
  info "Verifying $node"
  while :; do
    if out=$(
      check_node_upgraded "$node" "$kernel" "$plan" "$hash" "$TARGET" \
        && check_node_pods "$node" \
        && check_daemonsets \
        && { [ "$plan" != "$PLAN_CP" ] || check_etcd; }
    ); then
      echo "$out"
      break
    fi
    if [ "$(now)" -ge "$deadline" ]; then
      echo "$out"
      die "Rollout stopped: $node does not pass verification after $SETTLE_TIMEOUT. Review it before continuing; the node keeps os-upgrade=upgrade."
    fi
    sleep "$POLL_SECONDS"
  done
  if ! is_true "$SKIP_NET_TEST"; then
    check_node_dns "$node" "$(plan_image)" \
      || die "Rollout stopped: the DNS/network test failed on $node."
  fi
}

# Moves etcd leadership off the node, preferably to an already upgraded member.
move_leader_off() {
  node=$1
  status=$(etcd_status "$node")
  leader_ep=$(echo "$status" | awk -F'\t' '$3 == "true" {print $1; exit}')
  target_id=""
  target_node=""
  for line in $(echo "$status" | awk -F'\t' '$3 == "false" {print $1 "|" $2}'); do
    ep=${line%|*}
    id=${line#*|}
    n=$(node_for_endpoint "$ep")
    [ "$n" != "$node" ] || continue
    case "$(node_json "$n" | jq_ '.status.nodeInfo.osImage')" in
      *"Ubuntu $TARGET"*) target_id=$id; target_node=$n; break ;;
    esac
    if [ -z "$target_id" ]; then target_id=$id; target_node=$n; fi
  done
  if [ -z "$leader_ep" ] || [ -z "$target_id" ]; then
    die "could not pick an etcd member to move the leadership to"
  fi
  info "$node is the etcd leader: move-leader to $target_node ($target_id)"
  mutate etcd_ctl "$node" --endpoints="$leader_ep" move-leader "$target_id" >/dev/null \
    || die "move-leader failed"
  is_true "$DRY_RUN" && return 0
  i=0
  while [ $i -lt 10 ]; do
    if [ "$(etcd_leader_node "$node" || true)" = "$target_node" ]; then
      info "New etcd leader: $target_node"
      return 0
    fi
    i=$((i + 1))
    sleep "$RETRY_SLEEP"
  done
  die "etcd leadership did not move to $target_node"
}

# Warns about blocked PDBs in the namespaces that have pods on the node.
warn_pdbs_for_node() {
  node=$1
  nss=$(k get pods -A --field-selector "spec.nodeName=$node" -o json \
    | jq_ '.items[] | select([.metadata.ownerReferences[]? | select(.kind == "DaemonSet" or .kind == "Node")] | length == 0) | .metadata.namespace' | sort -u)
  [ -n "$nss" ] || return 0
  blocked=$(k get pdb -A -o json | jq_ '.items[] | select((.status.disruptionsAllowed // 0) == 0) | .metadata.namespace + "/" + .metadata.name')
  hit=""
  for b in $blocked; do
    case " $(echo "$nss" | tr '\n' ' ') " in *" ${b%%/*} "*) hit="$hit $b" ;; esac
  done
  [ -n "$hit" ] || return 0
  warn "$node: PDBs with no disruptions allowed in namespaces with pods on the node:$hit (the drain may block)"
  confirm "Launch $node anyway? (the drain has a $DRAIN_TIMEOUT timeout)" \
    || die "Rollout stopped before $node because of the PDBs."
}

has_control_plane() {
  [ -n "$(nodes_json | jq_ ".items[] | select(.metadata.labels[\"$CP_LABEL\"] == \"true\") | .metadata.name")" ]
}

upgrade_one() {
  node=$1
  idx=$2
  total=$3
  kernel=$4
  plan=$(plan_for_node "$node")
  hash=$(plan_hash "$plan")
  [ -n "$hash" ] || die "Plan $plan has no latestHash; is it applied?"
  echo
  info "=== [$idx/$total] $node ($plan)"

  if [ "$(node_label "$node" "plan.upgrade.cattle.io/$plan")" = "$hash" ]; then
    info "$node: the Plan is already marked as complete; only verifying"
  elif [ "$(node_label "$node" os-upgrade)" = upgrade ]; then
    info "$node: already in progress; resuming"
    check_os_upgrade_idle "$node" >/dev/null || die "other nodes are being upgraded at the same time as $node"
  else
    check_nodes_ready || die "Rollout stopped: there are nodes not Ready."
    check_os_upgrade_idle || die "Rollout stopped: another node is being upgraded."
    if has_control_plane; then check_etcd "$node" || die "Rollout stopped: etcd is not healthy."; fi
    warn_pdbs_for_node "$node"
    if [ "$plan" = "$PLAN_CP" ] && [ "$(etcd_leader_node "$node" || true)" = "$node" ]; then
      move_leader_off "$node"
    fi
    mutate k label node "$node" os-upgrade=upgrade --overwrite >/dev/null
    info "$node: os-upgrade=upgrade"
  fi

  if is_true "$DRY_RUN"; then
    echo "$(ts) [dry-run] wait for Plan $plan, verify and: kubectl label node $node os-upgrade=done --overwrite"
    return 0
  fi
  wait_node "$node" "$plan" "$hash"
  verify_node "$node" "$plan" "$hash" "$kernel"
  k label node "$node" os-upgrade=done --overwrite >/dev/null
  info "$node: OK, os-upgrade=done"
}

# ------------------------------------------------------------------ modes
cmd_upgrade() {
  candidates=$(selected_nodes)
  [ -n "$candidates" ] || die "no node selected"
  resume="" workers="" cps=""
  for n in $candidates; do
    state=$(node_label "$n" os-upgrade)
    case "$state" in
      done|hold) info "skipping $n (os-upgrade=$state)"; continue ;;
      upgrade) resume="$resume $n"; continue ;;
    esac
    if node_is_cp "$n"; then cps="$cps $n"; else workers="$workers $n"; fi
  done

  leader=""
  if [ -n "$cps" ]; then
    leader=$(etcd_leader_node || true)
    [ -n "$leader" ] || is_true "$DRY_RUN" || die "could not determine the etcd leader"
  fi
  others="" last=""
  for n in $cps; do
    if [ "$n" = "$leader" ]; then last=$n; else others="$others $n"; fi
  done
  # shellcheck disable=SC2086
  set -- $resume $workers $others $last
  [ $# -gt 0 ] || { info "Nothing to do: all selected nodes are done/hold."; return 0; }
  total=$#

  kernel=$(config_value KERNEL_VERSION || true)
  TARGET=$(target_version)
  echo "Rollout in context '$(k config current-context 2>/dev/null)', Ubuntu $TARGET with kernel ${kernel:-?}:"
  i=1
  for n in "$@"; do
    note=""
    case " $resume " in *" $n "*) note=" [in progress: resumed]" ;; esac
    [ "$n" = "$last" ] && note=" [etcd leader: move-leader first]"
    printf '  %d. %-30s %s%s\n' "$i" "$n" "$(plan_for_node "$n")" "$note"
    i=$((i + 1))
  done
  echo

  check_api || die "no access to the cluster"
  check_suc || die "Rollout stopped."
  check_plans || die "Rollout stopped."
  check_rancher_plans_idle || die "Rollout stopped."
  check_snapshot || die "Rollout stopped."
  [ -n "$kernel" ] || die "KERNEL_VERSION not set"

  if ! is_true "$DRY_RUN"; then
    confirm "Start the rollout of $total node(s)?" || die "Cancelled."
  fi
  i=1
  for n in "$@"; do
    upgrade_one "$n" "$i" "$total" "$kernel"
    if [ "$i" -lt "$total" ] && ! is_true "$DRY_RUN"; then
      eval "next=\${$((i + 1))}"
      # shellcheck disable=SC2154 # next is assigned with eval
      if ! confirm "$n finished and verified. Continue with $next?"; then
        info "Rollout stopped by the operator after $n. To continue, relaunch the same command."
        return 0
      fi
    fi
    i=$((i + 1))
  done
  echo
  info "Rollout complete: $total node(s)."
  if [ -z "$GROUP" ]; then return 0; fi
  sh "$(dirname "$0")/check-cluster.sh" >/dev/null 2>&1 || warn "check-cluster.sh reports problems; review it"
}

cmd_predownload() {
  candidates=$(selected_nodes)
  nodes=""
  for n in $candidates; do
    state=$(node_label "$n" os-upgrade)
    case "$state" in
      done|hold|upgrade) info "skipping $n (os-upgrade=$state)" ;;
      *) nodes="$nodes $n" ;;
    esac
  done
  [ -n "$nodes" ] || { info "No node to predownload."; return 0; }
  check_api || die "no access to the cluster"
  check_plans || die "Stopped."
  echo "Predownload on:$nodes"
  is_true "$DRY_RUN" || confirm "Launch the predownload?" || die "Cancelled."
  for n in $nodes; do
    mutate k label node "$n" os-upgrade=predownload --overwrite >/dev/null
  done
  if is_true "$DRY_RUN" || ! is_true "$WAIT"; then return 0; fi

  hash=$(plan_hash "$PLAN_PREDOWNLOAD")
  deadline=$(( $(now) + PREDOWNLOAD_TIMEOUT_S ))
  pending=$nodes
  failed=""
  started_dl=""
  while [ -n "$(echo "$pending" | tr -d ' ')" ]; do
    still=""
    for n in $pending; do
      phase=$(pod_phase "$(node_pod_json "$n" "$PLAN_PREDOWNLOAD")")
      case " $started_dl " in
        *" $n "*) ;;
        *) if [ "${phase% *}" = upgrade ]; then info "$n: downloading"; started_dl="$started_dl $n"; fi ;;
      esac
      if [ "$(node_label "$n" "plan.upgrade.cattle.io/$PLAN_PREDOWNLOAD")" = "$hash" ]; then
        info "$n: predownload finished"
        k -n "$NS" logs -l "upgrade.cattle.io/plan=$PLAN_PREDOWNLOAD,upgrade.cattle.io/node=$n" -c upgrade --tail=50 2>/dev/null \
          | grep -E 'WARN|Predownload OK' | sed 's/^/    /' || true
      elif [ "$(job_failed "$n" "$PLAN_PREDOWNLOAD" "$hash")" -gt 0 ]; then
        err "$n: the predownload failed"
        show_logs "$n" "$PLAN_PREDOWNLOAD" upgrade
        failed="$failed $n"
      else
        still="$still $n"
      fi
    done
    pending=$still
    [ -n "$(echo "$pending" | tr -d ' ')" ] || break
    [ "$(now)" -lt "$deadline" ] || die "predownload not finished after $PREDOWNLOAD_TIMEOUT on:$pending"
    sleep "$POLL_SECONDS"
  done
  [ -z "$failed" ] || die "predownload failed on:$failed"
  info "Predownload complete."
}

# Actual state of each node:
#   UPGRADE      ok (target version with the current KERNEL_VERSION) | in progress (os-upgrade=upgrade) | no
#   PREDOWNLOAD  ok (current Plan version) | previous (another version) | no | - (already upgraded)
cmd_status() {
  hp=$(plan_hash "$PLAN_PREDOWNLOAD" 2>/dev/null || true)
  kernel=$(config_value KERNEL_VERSION 2>/dev/null || true)
  TARGET=$(target_version)
  wanted=" $(selected_nodes | tr '\n' ' ') "
  printf '%-28s %-6s %-6s %-12s %-11s %-11s %-20s %-24s %s\n' NODE ROLE GROUP OS-UPGRADE PREDOWNLOAD UPGRADE OS KERNEL STATE
  nodes_json | jq_ "
    .items[] | [
      .metadata.name,
      .metadata.labels[\"$CP_LABEL\"] // \"-\",
      .metadata.labels[\"os-upgrade-group\"] // \"-\",
      .metadata.labels[\"os-upgrade\"] // \"-\",
      .metadata.labels[\"plan.upgrade.cattle.io/$PLAN_PREDOWNLOAD\"] // \"-\",
      (.status.nodeInfo.osImage | sub(\" LTS\", \"\") | sub(\" \", \"_\")),
      .status.nodeInfo.kernelVersion,
      ([.status.conditions[] | select(.type == \"Ready\") | .status][0] // \"Unknown\"),
      ((.spec.unschedulable // false) | tostring)
    ] | join(\" \")" | while read -r name cp group state ph os kv ready unsched; do
      case "$wanted" in *" $name "*) ;; *) continue ;; esac
      role="worker"; [ "$cp" != true ] || role="cp"
      [ "$ready" = True ] && ready=Ready || ready=NotReady
      cordon=""; [ "$unsched" != true ] || cordon=cordon
      case "$os" in
        *"$TARGET"*) [ -n "$kernel" ] && [ "$kv" = "$kernel" ] && ud="ok" || ud="no" ;;
        *) ud="no" ;;
      esac
      [ "$ud" = ok ] || [ "$state" != upgrade ] || ud="in progress"
      if [ "$ud" = ok ]; then pd="-"
      elif [ "$ph" = "-" ]; then pd="no"
      elif [ "$ph" = "$hp" ]; then pd="ok"
      else pd="previous"
      fi
      printf '%-28s %-6s %-6s %-12s %-11s %-11s %-20s %-24s %s\n' "$name" "$role" "$group" "$state" "$pd" "$ud" "$os" "$kv" "$ready${cordon:+,$cordon}"
    done
}

require_tools
open_answers
case "$MODE" in
  upgrade) cmd_upgrade ;;
  predownload) cmd_predownload ;;
  status) cmd_status ;;
  -h|--help) usage ;;
  *) err "unknown mode: $MODE"; usage ;;
esac
