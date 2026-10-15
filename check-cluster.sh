#!/bin/sh
# Verificación entre nodos: estado de nodos, etcd y Jobs de SUC.
# Uso: ./check-cluster.sh
set -eu

ETCDCTL="etcdctl --cacert /var/lib/rancher/rke2/server/tls/etcd/server-ca.crt \
  --cert /var/lib/rancher/rke2/server/tls/etcd/server-client.crt \
  --key /var/lib/rancher/rke2/server/tls/etcd/server-client.key"

echo "=== Nodos"
kubectl get nodes -o wide -L os-upgrade

# Usar un pod etcd que esté Running
POD=$(kubectl -n kube-system get pods --field-selector=status.phase=Running -o name \
  | grep '^pod/etcd-' | head -n1 | cut -d/ -f2)
[ -n "$POD" ] || { echo "No hay pods etcd Running"; exit 1; }
echo
echo "=== etcd (consultado desde $POD)"
kubectl -n kube-system exec "$POD" -- sh -c "$ETCDCTL member list -w table"
kubectl -n kube-system exec "$POD" -- sh -c "$ETCDCTL endpoint status --cluster -w table"
kubectl -n kube-system exec "$POD" -- sh -c "$ETCDCTL endpoint health --cluster"

echo
echo "=== system-upgrade-controller"
kubectl -n cattle-system get plans,jobs,pods -o wide 2>/dev/null || true

echo
echo "=== Pods no sanos"
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded || true
