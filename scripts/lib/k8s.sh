# shellcheck shell=sh
# Acceso al cluster: kubectl, Plans, nodos y etcd. Requiere common.sh.

# Constantes usadas por los scripts que cargan esta librería.
# shellcheck disable=SC2034
PLAN_PREDOWNLOAD=os-upgrade-predownload
PLAN_WORKERS=os-upgrade-workers
PLAN_CP=os-upgrade-cp
CP_LABEL=node-role.kubernetes.io/control-plane

ETCD_CERTS="--cacert /var/lib/rancher/rke2/server/tls/etcd/server-ca.crt --cert /var/lib/rancher/rke2/server/tls/etcd/server-client.crt --key /var/lib/rancher/rke2/server/tls/etcd/server-client.key"

k() { "$KUBECTL" "$@"; }

# ------------------------------------------------------------------ Plans
plan_json() { k -n "$NS" get plan "$1" -o json; }
plan_hash() { plan_json "$1" | jq_ '.status.latestHash // ""'; }
plan_applying() { plan_json "$1" | jq_ '.status.applying // [] | .[]'; }

plan_config_name() {
  plan_json "$PLAN_WORKERS" | jq_ '.spec.upgrade.envFrom[0].configMapRef.name // ""'
}

config_value() {
  cm=$(plan_config_name)
  [ -n "$cm" ] || return 1
  k -n "$NS" get configmap "$cm" -o json | jq_ ".data.$1 // \"\""
}

# Versión destino de la campaña (TARGET_VERSION del ConfigMap; 24.04 si no está definida).
target_version() {
  v=$(config_value TARGET_VERSION 2>/dev/null || true)
  echo "${v:-24.04}"
}

plan_image() { plan_json "$PLAN_WORKERS" | jq_ '.spec.upgrade.image // ""'; }

# ------------------------------------------------------------------ nodos
nodes_json() { k get nodes -o json; }
node_json() { k get node "$1" -o json; }

node_label() { node_json "$1" | jq_ ".metadata.labels[\"$2\"] // \"\""; }

node_is_cp() { [ "$(node_label "$1" "$CP_LABEL")" = "true" ]; }

plan_for_node() {
  if node_is_cp "$1"; then echo "$PLAN_CP"; else echo "$PLAN_WORKERS"; fi
}

node_ip() {
  node_json "$1" | jq_ '.status.addresses[] | select(.type == "InternalIP") | .address' | head -n1
}

# Nodos que cumplen un selector de labels, ordenados por nombre.
nodes_by_selector() {
  k get nodes -l "$1" -o json | jq_ '.items[].metadata.name' | sort
}

# ------------------------------------------------------------------ Jobs y pods de SUC
node_jobs_json() {
  k -n "$NS" get jobs -l "upgrade.cattle.io/plan=$2,upgrade.cattle.io/node=$1" -o json
}

# Pod más reciente del Job de un nodo para un Plan.
node_pod_json() {
  k -n "$NS" get pods -l "upgrade.cattle.io/plan=$2,upgrade.cattle.io/node=$1" -o json \
    | jq_ -o json -I0 '[.items[]] | sort_by(.metadata.creationTimestamp) | .[-1] // {}'
}

# ------------------------------------------------------------------ etcd
# Pod de etcd en ejecución y listo, evitando el nodo indicado (el que se va a actualizar).
etcd_pod() {
  avoid=${1:-}
  # Sin shell: el contenedor de etcd de RKE2 ya no trae /bin/sh, etcdctl se ejecuta directo.
  k -n kube-system get pods -l component=etcd -o json | jq_ "
    .items[]
    | select(.status.phase == \"Running\")
    | select([.status.containerStatuses[] | select(.ready != true)] | length == 0)
    | select(.spec.nodeName != \"$avoid\")
    | .metadata.name" | head -n1
}

# etcdctl dentro de un pod de etcd. Uso: etcd_ctl <nodo-a-evitar> <args...>
etcd_ctl() {
  avoid=$1
  shift
  pod=$(etcd_pod "$avoid")
  [ -n "$pod" ] || { err "no hay ningún pod de etcd listo (evitando '$avoid')"; return 1; }
  # shellcheck disable=SC2086 # ETCD_CERTS son varias opciones
  k -n kube-system exec "$pod" -- etcdctl $ETCD_CERTS "$@"
}

# Tabla de etcdctl (-w table) -> TSV con cabecera.
table_to_tsv() {
  awk -F'|' '/^\|/ {
    out = ""
    for (i = 2; i < NF; i++) { v = $i; gsub(/^ +| +$/, "", v); out = out (i > 2 ? "\t" : "") v }
    print out
  }'
}

# Selecciona columnas por nombre de una TSV con cabecera: tsv_select "ENDPOINT|IS LEADER".
# Funciona con las tablas de etcd 3.5 y 3.6 (cambia el orden y el número de columnas).
tsv_select() {
  awk -F'\t' -v cols="$1" '
    BEGIN { n = split(cols, want, "|") }
    NR == 1 { for (i = 1; i <= NF; i++) idx[$i] = i; next }
    {
      out = ""
      for (j = 1; j <= n; j++) out = out (j > 1 ? "\t" : "") (want[j] in idx ? $(idx[want[j]]) : "")
      print out
    }'
}

# Estado de etcd: "endpoint<TAB>id<TAB>is_leader<TAB>raft_index<TAB>errors" por miembro.
etcd_status() {
  { etcd_ctl "${1:-}" endpoint status --cluster -w table 2>/dev/null || true; } \
    | table_to_tsv | tsv_select "ENDPOINT|ID|IS LEADER|RAFT INDEX|ERRORS"
}

# Salud: "endpoint<TAB>health" por miembro.
etcd_health() {
  { etcd_ctl "${1:-}" endpoint health --cluster -w table 2>/dev/null || true; } \
    | table_to_tsv | tsv_select "ENDPOINT|HEALTH"
}

# Miembros: "id<TAB>name<TAB>client_addrs".
etcd_members() {
  { etcd_ctl "${1:-}" member list -w table 2>/dev/null || true; } \
    | table_to_tsv | tsv_select "ID|NAME|CLIENT ADDRS"
}

endpoint_ip() { echo "$1" | sed -E 's#^[a-z]+://\[?([^]/]*)\]?:[0-9]+.*#\1#'; }

# Nodo cuyo InternalIP coincide con el endpoint de etcd.
node_for_endpoint() {
  ip=$(endpoint_ip "$1")
  nodes_json | jq_ ".items[] | select(.status.addresses[] | select(.type == \"InternalIP\" and .address == \"$ip\")) | .metadata.name" | head -n1
}

# Nombre del nodo que es líder de etcd (vacío si no se puede determinar).
etcd_leader_node() {
  leader=$(etcd_status "${1:-}" | awk -F'\t' '$3 == "true" {print $1; exit}')
  [ -n "$leader" ] || return 1
  node_for_endpoint "$leader"
}
