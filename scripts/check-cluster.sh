#!/bin/sh
# Estado del cluster: nodos, etcd, Plans/Jobs de os-upgrade y pods con problemas, y un
# veredicto final. Solo lectura. Sale con 1 si los nodos, etcd o los DaemonSets no están sanos.
# Uso: check-cluster.sh
set -eu

# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
# shellcheck source=lib/k8s.sh
. "$LIB_DIR/k8s.sh"
# shellcheck source=lib/checks.sh
. "$LIB_DIR/checks.sh"

require_tools

echo "=== Contexto: $(k config current-context 2>/dev/null || echo '?')"
echo
echo "=== Nodos"
k get nodes -o wide -L os-upgrade -L os-upgrade-group || true

echo
echo "=== etcd"
etcd_ctl "" member list -w table || true
etcd_ctl "" endpoint status --cluster -w table || true
etcd_ctl "" endpoint health --cluster -w table || true
alarms=$(etcd_ctl "" alarm list 2>/dev/null || true)
echo "Alarmas: ${alarms:-ninguna}"

echo
echo "=== Plans, Jobs y pods de upgrade ($NS)"
k -n "$NS" get plans,jobs,pods -o wide 2>&1 || true

echo
echo "=== Pods con problemas (todo el cluster)"
bad=$(k get pods -A -o json | jq_ '
  .items[]
  | select(
      (.status.phase != "Running" and .status.phase != "Succeeded")
      or ([.status.containerStatuses[]? | select(.state.waiting.reason == "CrashLoopBackOff" or .state.waiting.reason == "ImagePullBackOff" or .state.waiting.reason == "ErrImagePull")] | length > 0))
  | .metadata.namespace + "/" + .metadata.name + " " + .status.phase + " " + (.spec.nodeName // "-")')
echo "${bad:-ninguno}"

echo
echo "=== Veredicto"
check_nodes_ready || true
check_etcd "" || true
check_daemonsets || true
[ "$CHECK_FAILS" -eq 0 ]
