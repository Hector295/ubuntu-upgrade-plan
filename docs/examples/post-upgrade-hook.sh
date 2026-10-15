#!/bin/sh
# Example post-upgrade hook. It runs on the node (as root, on the host) at the end of the
# upgrade, with the system already on the target version and the pinned kernel booted. If it
# exits with an error it is retried (POST_UPGRADE_HOOK_RETRIES) and, if it keeps failing, the
# node is marked as failed and stays cordoned for review.
#
# Available variables: NODE_NAME, KERNEL_VERSION, TARGET_VERSION.
# To use it: copy it to manifests/overlays/<cluster>/post-upgrade-hook.sh and add to the
# overlay kustomization.yaml (see docs/configuration.md):
#   secretGenerator:
#     - name: os-upgrade-script
#       behavior: merge
#       files:
#         - post-upgrade-hook.sh
set -eu

fail=0

# 1. Every filesystem in /etc/fstab is mounted.
awk '$1 !~ /^#/ && $2 ~ /^\// && $3 != "swap" && $4 !~ /noauto/ {print $2}' /etc/fstab | while read -r mp; do
  if ! mountpoint -q "$mp"; then echo "not mounted: $mp"; exit 1; fi
done || fail=1

# 2. Site-specific services that must be active (adjust the list).
for svc in ssh chrony; do
  if systemctl list-unit-files "$svc.service" >/dev/null 2>&1 && ! systemctl is-active --quiet "$svc"; then
    echo "inactive service: $svc"
    fail=1
  fi
done

# 3. If there is an NVIDIA GPU, the driver must answer (uncomment if it applies).
# if command -v nvidia-smi >/dev/null 2>&1; then
#   nvidia-smi -L >/dev/null || { echo "nvidia-smi fails"; fail=1; }
# fi

# 4. systemd units in failed state: informational only.
failed_units=$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
[ -z "$failed_units" ] || echo "warning: failed units: $failed_units"

[ "$fail" -eq 0 ] && echo "site checks OK on $NODE_NAME ($KERNEL_VERSION)"
exit "$fail"
