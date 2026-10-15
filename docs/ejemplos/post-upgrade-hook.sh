#!/bin/sh
# Ejemplo de hook post-upgrade. Se ejecuta en el nodo (como root, en el host) al final del
# upgrade, con el sistema ya en 24.04 y el kernel fijado arrancado. Si sale con error, se
# reintenta (POST_UPGRADE_HOOK_RETRIES) y, si sigue fallando, el nodo queda marcado como
# fallido y cordoneado para revisarlo.
#
# Variables disponibles: NODE_NAME, KERNEL_VERSION, TARGET_VERSION.
# Para usarlo: copiarlo a manifests/overlays/<cluster>/post-upgrade-hook.sh y añadir al
# kustomization.yaml del overlay (ver docs/configuracion.md):
#   secretGenerator:
#     - name: os-upgrade-script
#       behavior: merge
#       files:
#         - post-upgrade-hook.sh
set -eu

fail=0

# 1. Todos los sistemas de archivos de /etc/fstab están montados.
awk '$1 !~ /^#/ && $2 ~ /^\// && $3 != "swap" && $4 !~ /noauto/ {print $2}' /etc/fstab | while read -r mp; do
  if ! mountpoint -q "$mp"; then echo "no montado: $mp"; exit 1; fi
done || fail=1

# 2. Servicios propios del entorno que deben estar activos (ajustar la lista).
for svc in ssh chrony; do
  if systemctl list-unit-files "$svc.service" >/dev/null 2>&1 && ! systemctl is-active --quiet "$svc"; then
    echo "servicio inactivo: $svc"
    fail=1
  fi
done

# 3. Si hay GPU NVIDIA, que el driver responda (descomentar si aplica).
# if command -v nvidia-smi >/dev/null 2>&1; then
#   nvidia-smi -L >/dev/null || { echo "nvidia-smi falla"; fail=1; }
# fi

# 4. Unidades de systemd en estado fallido: solo informativo.
failed_units=$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
[ -z "$failed_units" ] || echo "aviso: unidades fallidas: $failed_units"

[ "$fail" -eq 0 ] && echo "verificación propia OK en $NODE_NAME ($KERNEL_VERSION)"
exit "$fail"
