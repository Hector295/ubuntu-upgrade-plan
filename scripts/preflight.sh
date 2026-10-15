#!/bin/sh
# Checks before an upgrade campaign. Read-only: changes nothing in the cluster.
#
# Usage: preflight.sh [--group G | --nodes n1,n2]
#   --group/--nodes limit the disk space check to those nodes (default: all nodes).
#
# Exits with 1 if any check fails; warnings do not make it fail.
set -eu

# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
# shellcheck source=lib/k8s.sh
. "$LIB_DIR/k8s.sh"
# shellcheck source=lib/checks.sh
. "$LIB_DIR/checks.sh"

usage() {
  sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

selector=""
while [ $# -gt 0 ]; do
  case "$1" in
    --group) [ $# -ge 2 ] || usage; selector="os-upgrade-group=$2"; shift 2 ;;
    --nodes) [ $# -ge 2 ] || usage; nodes_arg=$2; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

require_tools

echo "=== Preflight of cluster $(k config current-context 2>/dev/null || echo '?')"
check_api || { echo "No access to the cluster: cannot continue."; exit 1; }
check_suc || true
check_plans || true
check_rancher_plans_idle || true
check_os_upgrade_in_progress
check_nodes_ready || true
check_etcd "" || true
check_snapshot || true
check_pdbs || true

min_mb=$(config_value MIN_FREE_ROOT_MB 2>/dev/null || true)
min_mb=${min_mb:-5000}
if [ -n "${nodes_arg:-}" ]; then
  nodes=$(echo "$nodes_arg" | tr ',' '\n')
elif [ -n "$selector" ]; then
  nodes=$(nodes_by_selector "$selector")
  [ -n "$nodes" ] || fail_check "no node with label $selector" || true
else
  nodes=$(nodes_json | jq_ '.items[].metadata.name' | sort)
fi
for n in $nodes; do
  check_node_disk "$n" "$min_mb" || true
done

echo "=== Result: $CHECK_FAILS failure(s), $CHECK_WARNS warning(s)"
[ "$CHECK_FAILS" -eq 0 ]
