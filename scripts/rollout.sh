#!/bin/sh
# Orquestador del upgrade: lanza los nodos de uno en uno, supervisa cada fase, verifica el
# resultado y pide confirmación antes del siguiente.
#
# Uso:
#   rollout.sh predownload (--group G | --nodes n1,n2) [--wait] [--dry-run] [--yes]
#   rollout.sh upgrade     (--group G | --nodes n1,n2) [--dry-run] [--yes]
#                          [--drain-timeout 30m] [--prepare-timeout 15m] [--node-timeout 4h]
#                          [--skip-net-test]
#   rollout.sh status      [--group G | --nodes n1,n2]
#
# upgrade:
#   orden          workers -> control plane no líderes -> líder de etcd (move-leader antes)
#   antes de cada  API, SUC, Plans, nodos Ready, etcd sano, nada más en upgrade
#   durante        prepare y drain con timeout: si fallan, el nodo se aparta (os-upgrade=hold)
#                  sin haberse tocado; si falla el upgrade, se para y se deja como está
#   después        24.04 + kernel, Ready, DaemonSets, pods del nodo, DNS, etcd -> os-upgrade=done
#   --dry-run      muestra el plan y hace las comprobaciones, sin cambiar nada
#   --yes          sin preguntas (al vencer el drain, aborta el nodo)
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

# ------------------------------------------------------------------ argumentos
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
    *) err "opción desconocida: $1"; usage ;;
  esac
done
seconds_of() {
  to_seconds "$2" || die "duración inválida en $1: '$2' (usar p. ej. 90s, 30m, 2h)"
}
DRAIN_TIMEOUT_S=$(seconds_of --drain-timeout "$DRAIN_TIMEOUT")
PREPARE_TIMEOUT_S=$(seconds_of --prepare-timeout "$PREPARE_TIMEOUT")
NODE_TIMEOUT_S=$(seconds_of --node-timeout "$NODE_TIMEOUT")
SETTLE_TIMEOUT_S=$(seconds_of SETTLE_TIMEOUT "$SETTLE_TIMEOUT")
PREDOWNLOAD_TIMEOUT_S=$(seconds_of PREDOWNLOAD_TIMEOUT "$PREDOWNLOAD_TIMEOUT")

# ------------------------------------------------------------------ selección de nodos
selected_nodes() {
  if [ -n "$NODES_ARG" ]; then
    echo "$NODES_ARG" | tr ',' '\n' | sed '/^$/d'
  elif [ -n "$GROUP" ]; then
    nodes_by_selector "os-upgrade-group=$GROUP"
  elif [ "$MODE" = status ]; then
    nodes_json | jq_ '.items[].metadata.name' | sort
  else
    die "indicar --group G o --nodes n1,n2"
  fi
}

# ------------------------------------------------------------------ fases de un nodo
# Estado de un contenedor del pod: "estado código inicio" (estado: running|terminated|waiting).
ctr_state() {
  list=$2
  echo "$1" | jq_ "(.status.$list // [])[] | select(.name == \"$3\") | ((.state | keys | .[0]) + \" \" + ((.state.terminated.exitCode // \"-\") | tostring) + \" \" + (.state.running.startedAt // .state.terminated.startedAt // \"-\"))"
}

# Fase del pod más reciente y su hora de inicio (epoch): "<fase> <inicio>".
# Fases: none|starting|prepare|prepare-failed|drain|drain-failed|upgrade|upgrade-ended.
# Se devuelve todo por stdout: la función se llama dentro de $(...).
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

# Aparta el nodo: ningún Plan lo vuelve a seleccionar y su Job se borra.
hold_node() {
  mutate k label node "$1" os-upgrade=hold --overwrite >/dev/null
  mutate k -n "$NS" delete job -l "upgrade.cattle.io/plan=$2,upgrade.cattle.io/node=$1" --ignore-not-found >/dev/null
  info "$1: apartado con os-upgrade=hold y Job borrado"
}

show_logs() {
  pod=$(node_pod_name "$1" "$2")
  [ -n "$pod" ] || return 0
  echo "----- últimas líneas de $3 ($pod)"
  k -n "$NS" logs "$pod" -c "$3" --tail=25 2>&1 | sed 's/^/  /' || true
  echo "-----"
}

# Pods que el drain todavía no ha desalojado (sin DaemonSets ni pods estáticos).
show_drain_blockers() {
  node=$1
  echo "Pods que siguen en $node:"
  k get pods -A --field-selector "spec.nodeName=$node" -o json | jq_ '
    .items[]
    | select([.metadata.ownerReferences[]? | select(.kind == "DaemonSet" or .kind == "Node")] | length == 0)
    | select((.metadata.labels["upgrade.cattle.io/controller"] // "") == "")
    | "  " + .metadata.namespace + "/" + .metadata.name' || true
  check_pdbs || true
}

on_prepare_failed() {
  err "$1: el preflight del nodo (prepare) falló. El nodo NO se ha drenado ni modificado."
  show_logs "$1" "$2" prepare
  hold_node "$1" "$2"
  die "Rollout detenido. Corregir la causa (ver docs/runbook.md, 'Falla prepare'), y relanzar: kubectl label node $1 os-upgrade- && $0 upgrade ..."
}

on_drain_stuck() {
  node=$1
  plan=$2
  why=$3
  warn "$node: $why"
  show_drain_blockers "$node"
  choice=$(ask_choice "[e]sperar $DRAIN_TIMEOUT más / [a]bortar: apartar el nodo y hacer uncordon [a]:" a)
  case "$choice" in
    e|E) return 0 ;;
  esac
  # Seguro: el contenedor upgrade todavía no ha arrancado, el sistema del nodo está intacto.
  hold_node "$node" "$plan"
  mutate k uncordon "$node" >/dev/null
  die "Rollout detenido: drain abortado en $node (uncordon hecho). Resolver los pods/PDBs que lo bloquean y relanzar."
}

on_job_failed() {
  err "$1: $3"
  node_jobs_json "$1" "$2" | jq_ '.items[] | "  Job " + .metadata.name + ": " + ([.status.conditions[]? | .type + "=" + .status + " " + (.reason // "") + " " + (.message // "")] | join("; "))' || true
  show_logs "$1" "$2" upgrade
  die "Rollout detenido. $1 sigue cordoneado y con os-upgrade=upgrade. En el nodo: sh /usr/local/sbin/os-upgrade.sh status; ver docs/runbook.md, 'El Job falló después del drain'."
}

# Espera a que el Plan termine en el nodo. Sale del script si algo falla.
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
      info "$node: Plan $plan completado"
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
            info "$node: sin pod (reinicio en curso o Job nuevo)"
          else
            info "$node: esperando a que el SUC cree el Job"
          fi ;;
        starting) info "$node: arrancando pod" ;;
        prepare) info "$node: prepare (preflight en el nodo)" ;;
        drain) info "$node: drain" ;;
        upgrade) info "$node: upgrade en curso (detalle en el nodo: journalctl -fu os-upgrade-release)" ;;
        upgrade-ended) info "$node: contenedor upgrade terminado (reboot o fin); esperando" ;;
      esac
      last=$phase
    fi

    if [ "$(job_failed "$node" "$plan" "$hash")" -gt 0 ]; then
      if ! is_true "$upgrade_started" && [ "$phase" = prepare-failed ]; then on_prepare_failed "$node" "$plan"; fi
      on_job_failed "$node" "$plan" "el Job del Plan $plan ha fallado"
    fi
    case "$phase" in
      prepare-failed)
        if is_true "$upgrade_started"; then
          on_job_failed "$node" "$plan" "prepare falló después de empezar el upgrade"
        fi
        on_prepare_failed "$node" "$plan" ;;
      prepare)
        if ! is_true "$upgrade_started" && [ $(( $(now) - phase_start )) -gt "$PREPARE_TIMEOUT_S" ]; then
          warn "$node: prepare lleva más de $PREPARE_TIMEOUT"
          on_prepare_failed "$node" "$plan"
        fi ;;
      drain-failed)
        is_true "$upgrade_started" || on_drain_stuck "$node" "$plan" "el contenedor drain falló" ;;
      drain)
        if ! is_true "$upgrade_started" && [ $(( $(now) - phase_start )) -gt $((DRAIN_TIMEOUT_S + drain_extra)) ]; then
          on_drain_stuck "$node" "$plan" "el drain lleva más de $(( (DRAIN_TIMEOUT_S + drain_extra) / 60 )) min"
          drain_extra=$((drain_extra + DRAIN_TIMEOUT_S))
        fi ;;
    esac
    if [ $(( $(now) - started )) -gt "$NODE_TIMEOUT_S" ]; then
      on_job_failed "$node" "$plan" "más de $NODE_TIMEOUT sin terminar"
    fi
    sleep "$POLL_SECONDS"
  done
}

# Verificaciones tras el upgrade; reintenta hasta SETTLE_TIMEOUT (DaemonSets y pods tardan en
# estabilizarse tras el reboot).
verify_node() {
  node=$1
  plan=$2
  hash=$3
  kernel=$4
  deadline=$(( $(now) + SETTLE_TIMEOUT_S ))
  info "Verificando $node"
  while :; do
    if out=$(
      check_node_upgraded "$node" "$kernel" "$plan" "$hash" \
        && check_node_pods "$node" \
        && check_daemonsets \
        && { [ "$plan" != "$PLAN_CP" ] || check_etcd; }
    ); then
      echo "$out"
      break
    fi
    if [ "$(now)" -ge "$deadline" ]; then
      echo "$out"
      die "Rollout detenido: $node no pasa la verificación tras $SETTLE_TIMEOUT. Revisar antes de seguir; el nodo queda con os-upgrade=upgrade."
    fi
    sleep "$POLL_SECONDS"
  done
  if ! is_true "$SKIP_NET_TEST"; then
    check_node_dns "$node" "$(plan_image)" \
      || die "Rollout detenido: la prueba de DNS/red falló en $node."
  fi
}

# Mueve el liderazgo de etcd fuera del nodo, preferiblemente a un miembro ya actualizado.
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
      *"Ubuntu 24.04"*) target_id=$id; target_node=$n; break ;;
    esac
    if [ -z "$target_id" ]; then target_id=$id; target_node=$n; fi
  done
  if [ -z "$leader_ep" ] || [ -z "$target_id" ]; then
    die "no se pudo elegir un miembro de etcd al que mover el liderazgo"
  fi
  info "$node es el líder de etcd: move-leader a $target_node ($target_id)"
  mutate etcd_ctl "$node" --endpoints="$leader_ep" move-leader "$target_id" >/dev/null \
    || die "move-leader falló"
  is_true "$DRY_RUN" && return 0
  i=0
  while [ $i -lt 10 ]; do
    if [ "$(etcd_leader_node "$node" || true)" = "$target_node" ]; then
      info "Nuevo líder de etcd: $target_node"
      return 0
    fi
    i=$((i + 1))
    sleep "$RETRY_SLEEP"
  done
  die "el liderazgo de etcd no se movió a $target_node"
}

# Avisa si hay PDBs bloqueados en los namespaces que tienen pods en el nodo.
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
  warn "$node: PDBs sin interrupciones permitidas en namespaces con pods en el nodo:$hit (el drain puede bloquearse)"
  confirm "¿Lanzar $node igualmente? (el drain tiene timeout de $DRAIN_TIMEOUT)" \
    || die "Rollout detenido antes de $node por los PDBs."
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
  [ -n "$hash" ] || die "el Plan $plan no tiene latestHash; ¿está aplicado?"
  echo
  info "=== [$idx/$total] $node ($plan)"

  if [ "$(node_label "$node" "plan.upgrade.cattle.io/$plan")" = "$hash" ]; then
    info "$node: el Plan ya figura como terminado; solo se verifica"
  elif [ "$(node_label "$node" os-upgrade)" = upgrade ]; then
    info "$node: ya estaba en curso; se retoma el seguimiento"
    check_os_upgrade_idle "$node" >/dev/null || die "hay otros nodos en upgrade a la vez que $node"
  else
    check_nodes_ready || die "Rollout detenido: hay nodos no Ready."
    check_os_upgrade_idle || die "Rollout detenido: hay otro nodo en upgrade."
    if has_control_plane; then check_etcd "$node" || die "Rollout detenido: etcd no está sano."; fi
    warn_pdbs_for_node "$node"
    if [ "$plan" = "$PLAN_CP" ] && [ "$(etcd_leader_node "$node" || true)" = "$node" ]; then
      move_leader_off "$node"
    fi
    mutate k label node "$node" os-upgrade=upgrade --overwrite >/dev/null
    info "$node: os-upgrade=upgrade"
  fi

  if is_true "$DRY_RUN"; then
    echo "$(ts) [dry-run] esperar Plan $plan, verificar y: kubectl label node $node os-upgrade=done --overwrite"
    return 0
  fi
  wait_node "$node" "$plan" "$hash"
  verify_node "$node" "$plan" "$hash" "$kernel"
  k label node "$node" os-upgrade=done --overwrite >/dev/null
  info "$node: OK, os-upgrade=done"
}

# ------------------------------------------------------------------ modos
cmd_upgrade() {
  candidates=$(selected_nodes)
  [ -n "$candidates" ] || die "ningún nodo seleccionado"
  resume="" workers="" cps=""
  for n in $candidates; do
    state=$(node_label "$n" os-upgrade)
    case "$state" in
      done|hold) info "se omite $n (os-upgrade=$state)"; continue ;;
      upgrade) resume="$resume $n"; continue ;;
    esac
    if node_is_cp "$n"; then cps="$cps $n"; else workers="$workers $n"; fi
  done

  leader=""
  if [ -n "$cps" ]; then
    leader=$(etcd_leader_node || true)
    [ -n "$leader" ] || is_true "$DRY_RUN" || die "no se pudo determinar el líder de etcd"
  fi
  others="" last=""
  for n in $cps; do
    if [ "$n" = "$leader" ]; then last=$n; else others="$others $n"; fi
  done
  # shellcheck disable=SC2086
  set -- $resume $workers $others $last
  [ $# -gt 0 ] || { info "Nada que hacer: todos los nodos seleccionados están en done/hold."; return 0; }
  total=$#

  kernel=$(config_value KERNEL_VERSION || true)
  echo "Rollout en el contexto '$(k config current-context 2>/dev/null)', kernel objetivo ${kernel:-?}:"
  i=1
  for n in "$@"; do
    note=""
    case " $resume " in *" $n "*) note=" [en curso: se retoma]" ;; esac
    [ "$n" = "$last" ] && note=" [líder de etcd: move-leader antes]"
    printf '  %d. %-30s %s%s\n' "$i" "$n" "$(plan_for_node "$n")" "$note"
    i=$((i + 1))
  done
  echo

  check_api || die "sin acceso al cluster"
  check_suc || die "Rollout detenido."
  check_plans || die "Rollout detenido."
  check_rancher_plans_idle || die "Rollout detenido."
  check_snapshot || die "Rollout detenido."
  [ -n "$kernel" ] || die "KERNEL_VERSION no definido"

  if ! is_true "$DRY_RUN"; then
    confirm "¿Empezar el rollout de $total nodo(s)?" || die "Cancelado."
  fi
  i=1
  for n in "$@"; do
    upgrade_one "$n" "$i" "$total" "$kernel"
    if [ "$i" -lt "$total" ] && ! is_true "$DRY_RUN"; then
      eval "next=\${$((i + 1))}"
      # shellcheck disable=SC2154 # next se asigna con eval
      if ! confirm "$n terminado y verificado. ¿Continuar con $next?"; then
        info "Rollout detenido por el operador después de $n. Para seguir, relanzar el mismo comando."
        return 0
      fi
    fi
    i=$((i + 1))
  done
  echo
  info "Rollout completado: $total nodo(s)."
  if [ -z "$GROUP" ]; then return 0; fi
  sh "$(dirname "$0")/check-cluster.sh" >/dev/null 2>&1 || warn "check-cluster.sh reporta problemas; revisarlo"
}

cmd_predownload() {
  candidates=$(selected_nodes)
  nodes=""
  for n in $candidates; do
    state=$(node_label "$n" os-upgrade)
    case "$state" in
      done|hold|upgrade) info "se omite $n (os-upgrade=$state)" ;;
      *) nodes="$nodes $n" ;;
    esac
  done
  [ -n "$nodes" ] || { info "Ningún nodo para pre-descargar."; return 0; }
  check_api || die "sin acceso al cluster"
  check_plans || die "Detenido."
  echo "Pre-descarga en:$nodes"
  is_true "$DRY_RUN" || confirm "¿Lanzar la pre-descarga?" || die "Cancelado."
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
        *) if [ "${phase% *}" = upgrade ]; then info "$n: descargando"; started_dl="$started_dl $n"; fi ;;
      esac
      if [ "$(node_label "$n" "plan.upgrade.cattle.io/$PLAN_PREDOWNLOAD")" = "$hash" ]; then
        info "$n: pre-descarga terminada"
        k -n "$NS" logs -l "upgrade.cattle.io/plan=$PLAN_PREDOWNLOAD,upgrade.cattle.io/node=$n" -c upgrade --tail=50 2>/dev/null \
          | grep -E 'WARN|Pre-descarga OK' | sed 's/^/    /' || true
      elif [ "$(job_failed "$n" "$PLAN_PREDOWNLOAD" "$hash")" -gt 0 ]; then
        err "$n: la pre-descarga falló"
        show_logs "$n" "$PLAN_PREDOWNLOAD" upgrade
        failed="$failed $n"
      else
        still="$still $n"
      fi
    done
    pending=$still
    [ -n "$(echo "$pending" | tr -d ' ')" ] || break
    [ "$(now)" -lt "$deadline" ] || die "pre-descarga sin terminar tras $PREDOWNLOAD_TIMEOUT en:$pending"
    sleep "$POLL_SECONDS"
  done
  [ -z "$failed" ] || die "pre-descarga fallida en:$failed"
  info "Pre-descarga completada."
}

# Estado real de cada nodo:
#   UPGRADE      ok (24.04 con el KERNEL_VERSION actual) | en curso (os-upgrade=upgrade) | no
#   PREDESCARGA  ok (versión actual del Plan) | anterior (otra versión) | no | - (ya actualizado)
cmd_status() {
  hp=$(plan_hash "$PLAN_PREDOWNLOAD" 2>/dev/null || true)
  kernel=$(config_value KERNEL_VERSION 2>/dev/null || true)
  wanted=" $(selected_nodes | tr '\n' ' ') "
  printf '%-28s %-6s %-6s %-12s %-11s %-8s %-20s %-24s %s\n' NODO ROL GRUPO OS-UPGRADE PREDESCARGA UPGRADE SO KERNEL ESTADO
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
        *24.04*) [ -n "$kernel" ] && [ "$kv" = "$kernel" ] && ud="ok" || ud="no" ;;
        *) ud="no" ;;
      esac
      [ "$ud" = ok ] || [ "$state" != upgrade ] || ud="en curso"
      if [ "$ud" = ok ]; then pd="-"
      elif [ "$ph" = "-" ]; then pd="no"
      elif [ "$ph" = "$hp" ]; then pd="ok"
      else pd="anterior"
      fi
      printf '%-28s %-6s %-6s %-12s %-11s %-8s %-20s %-24s %s\n' "$name" "$role" "$group" "$state" "$pd" "$ud" "$os" "$kv" "$ready${cordon:+,$cordon}"
    done
}

require_tools
open_answers
case "$MODE" in
  upgrade) cmd_upgrade ;;
  predownload) cmd_predownload ;;
  status) cmd_status ;;
  -h|--help) usage ;;
  *) err "modo desconocido: $MODE"; usage ;;
esac
