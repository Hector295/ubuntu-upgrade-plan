# Runbook: upgrade de un cluster

Procedimiento manual, nodo a nodo. En la iteración 2, `scripts/rollout.sh` automatizará los
pasos 4 y 5 (labels, esperas, verificaciones y confirmación entre nodos).

Convenciones: `N` es el nombre del nodo y `NS=cattle-system`.

## 0. Antes de la campaña (una vez por cluster)

1. **Reintentos de los Jobs del SUC.** Cada reboot mata el pod del Job y cuenta como un fallo.
   Por defecto el SUC v0.16 permite 2 (`backoffLimit`). Comprobad lo que configura Rancher:

   ```sh
   kubectl -n cattle-system get deploy system-upgrade-controller -o jsonpath='{..env}'; echo
   kubectl -n cattle-system get configmap -o name | grep -i upgrade
   ```

   Con el flujo normal (1 reboot) basta con el valor por defecto. Con `SINGLE_REBOOT=false` o
   reintentos manuales el margen es pequeño: tenedlo en cuenta al leer el estado de un Job.
2. **Kernel disponible:** ver [kernel.md](kernel.md#elegir-y-verificar-la-versión).
3. **Congelar los upgrades de RKE2 en Rancher** mientras dure la campaña: los Plans
   `system-agent-upgrader*` de Rancher no deben coincidir con estos.
4. **Snapshot de etcd reciente** (Rancher → cluster → Snapshots, o
   `kubectl get etcdsnapshotfiles`).
5. **Estado sano:** `sh scripts/check-cluster.sh`: todos los nodos Ready, 3 miembros de etcd
   sanos y un líder.

## 1. Generar y aplicar los Plans

```sh
make validate CLUSTER=<cluster>
kubectl apply -f out/<cluster>.yaml
kubectl -n $NS get plans
```

Aplicar los Plans no toca ningún nodo: solo actúan sobre nodos con el label `os-upgrade`.

## 2. Pre-parcheo (para tener un solo reboot)

`do-release-upgrade` exige reiniciar antes si 22.04 tiene pendiente una actualización de
`libc6`, `linux-base` o del kernel. Los metapaquetes de kernel se quitan antes del full-upgrade,
así que normalmente solo `libc6` puede provocarlo. Con `SINGLE_REBOOT=true` (por defecto), un nodo
en esa situación **no se drena**: el preflight falla con
`el nodo necesitaría un reboot previo por: ...`.

La pre-descarga (paso 3) avisa de qué nodos están en ese caso. Esos nodos se ponen al día y se
reinician en la ventana de parches habitual, antes de la ventana del upgrade.

## 3. Pre-descarga (días antes, sin impacto)

Sin drain, sin cordon y sin reboot. Por tandas, p. ej.:

```sh
kubectl label node N1 N2 N3 os-upgrade=predownload --overwrite
kubectl -n $NS get jobs -l upgrade.cattle.io/plan=os-upgrade-predownload -w
```

Resultado por nodo:

```sh
kubectl -n $NS logs job/<job> -c upgrade | tail
# ... INFO Pre-descarga OK: 734 paquetes, 812 MB en /var/lib/os-upgrade/archives
# ... WARN este nodo necesitará parche + reboot previo ...   <- ver paso 2
```

Un nodo con la pre-descarga terminada tiene el label
`plan.upgrade.cattle.io/os-upgrade-predownload` con el hash del Plan.

**Cuanto más cerca de la ventana, mejor:** lo que publique Ubuntu entre la pre-descarga y la
ventana se descargará en la ventana.

## 4. Ventana: un nodo cada vez

Orden: **workers → control plane no líderes → control plane líder**.

### 4.1 Lanzar

```sh
kubectl label node N os-upgrade=upgrade --overwrite
```

El Job ejecuta, en este orden:

1. **`prepare`**: preflight sin tocar el nodo (configuración, pre-descarga, espacio, proxy,
   reboot previo). Si falla, el nodo **no** se cordonea.
2. **`drain`**: cordon + drain (lo hace el SUC).
3. **`upgrade`**:
   - quita los metapaquetes de kernel y aplica el pin;
   - lleva 22.04 al último parche;
   - lanza en el host la unidad `os-upgrade-release` (`do-release-upgrade` con la caché
     pre-descargada, instalación del kernel fijado, GRUB);
   - reinicia **una vez**.
4. Tras el reboot el Job crea otro pod, que verifica, limpia y termina con éxito. El SUC hace el
   uncordon.

### 4.2 Seguir

```sh
kubectl -n $NS get jobs,pods -l upgrade.cattle.io/node=N -o wide -w
kubectl -n $NS logs -l upgrade.cattle.io/node=N -c prepare
kubectl -n $NS logs -l upgrade.cattle.io/node=N -c upgrade -f
```

Durante el release upgrade, el pod solo dice `Release upgrade en curso`. El detalle está en el nodo:

```sh
journalctl -fu os-upgrade-release          # unidad del host
tail -f /var/log/os-upgrade.log            # log de todas las fases (persiste entre reboots)
tail -f /var/log/dist-upgrade/main.log     # log del upgrader de Ubuntu
sh /usr/local/sbin/os-upgrade.sh status    # resumen del estado
```

### 4.3 Comprobar que terminó

```sh
PLAN=os-upgrade-workers    # u os-upgrade-cp
kubectl -n $NS get plan $PLAN -o jsonpath='{.status.latestHash}'; echo
kubectl get node N -o jsonpath="{.metadata.labels.plan\.upgrade\.cattle\.io/$PLAN}"; echo
```

Si los dos hashes coinciden, el Plan terminó en ese nodo. En el Plan de control plane, el label
aparece tras `postCompleteDelay` (10 min); el uncordon es inmediato. Verificar:

```sh
kubectl get node N -o wide                 # Ready, OS-IMAGE Ubuntu 24.04, KERNEL 6.8.0-139-generic
kubectl get pods -A -o wide --field-selector spec.nodeName=N | grep -v Running   # sin pods rotos
sh scripts/check-cluster.sh                # control plane: 3 miembros etcd sanos y un líder
```

### 4.4 Cerrar el nodo

```sh
kubectl label node N os-upgrade=done --overwrite
```

**Imprescindible:** sin este cambio, cualquier cambio futuro de los Plans (otro hash) volvería a
lanzar el proceso en ese nodo.

### 4.5 Control plane líder

Antes de lanzar el nodo líder de etcd, mover el liderazgo a otro miembro ya actualizado:

```sh
POD=etcd-<nodo-lider>
CERTS="--cacert /var/lib/rancher/rke2/server/tls/etcd/server-ca.crt \
  --cert /var/lib/rancher/rke2/server/tls/etcd/server-client.crt \
  --key /var/lib/rancher/rke2/server/tls/etcd/server-client.key"
kubectl -n kube-system exec $POD -- sh -c "etcdctl $CERTS endpoint status --cluster -w table"  # ver IS LEADER
kubectl -n kube-system exec $POD -- sh -c "etcdctl $CERTS member list -w table"              # ID del destino
kubectl -n kube-system exec $POD -- sh -c "etcdctl $CERTS move-leader <ID-hex-destino>"
```

Comprobar con `endpoint status` que el líder cambió y luego seguir con 4.1.

## 5. Final de la campaña

- Todos los nodos con `os-upgrade=done` y `sh scripts/check-cluster.sh` sano.
- Opcional: `kubectl delete -f out/<cluster>.yaml` y quitar los labels (`kubectl label node N os-upgrade-`).
  Lo que garantiza el kernel (pin, hold, GRUB) queda en los nodos.
- Reactivar los upgrades de RKE2 en Rancher.

---

## Problemas frecuentes

Regla general: el proceso deja una **marca de fallo** (`/var/lib/os-upgrade/failed`) cuando hace
falta una persona. Con la marca puesta, los reintentos no hacen nada.

```sh
cat /var/lib/os-upgrade/failed                 # motivo
sh /usr/local/sbin/os-upgrade.sh reset-failed  # tras arreglarlo: borra marca y contador de reboots
kubectl -n $NS delete job <job>                # el SUC crea un Job nuevo y el proceso continúa
```

Si `/usr/local/sbin/os-upgrade.sh` aún no existe, el fallo fue antes de copiarlo y no hay marca.

### Falla `prepare` (el nodo no se ha tocado)

| Mensaje | Causa y solución |
|---|---|
| `falta la pre-descarga para ...` | No se hizo el paso 3 o se hizo con otro `KERNEL_VERSION`. Hacerlo, o poner `REQUIRE_PREDOWNLOAD=false` |
| `el nodo necesitaría un reboot previo por: ...` | Ver paso 2. Parchear y reiniciar el nodo en la ventana de parches |
| `espacio libre insuficiente en ...` | Liberar espacio (`apt-get clean`, kernels viejos, logs) |
| `apt-get update falló` | Proxy o mirror: revisar `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` |
| `KERNEL_VERSION ...` | Configuración del overlay; corregir, `make validate` y `kubectl apply` |

Para reintentar tras arreglarlo: `kubectl -n $NS delete job <job>`. Para dejar el nodo para más
tarde: `kubectl label node N os-upgrade-` y borrar el Job.

### El Job falló después del drain (nodo cordoneado)

El SUC solo hace el uncordon si el Job termina bien. Antes de nada, comprobar si el proceso sigue
vivo en el host:

```sh
systemctl status os-upgrade-release
sh /usr/local/sbin/os-upgrade.sh status
```

- **Deadline vencido (`DeadlineExceeded`) con la unidad activa:** el upgrade sigue en el host y
  acabará reiniciando el nodo. **No hacer uncordon.** Esperar a que termine
  (`journalctl -fu os-upgrade-release`) y luego borrar el Job para que el SUC lo recree, verifique
  y haga el uncordon. Para la próxima vez, subir `jobActiveDeadlineSecs`.
- **`do-release-upgrade terminó con error`:** revisar `/var/log/dist-upgrade/main.log` y
  `apt.log`. Con frecuencia es un repositorio de terceros o un paquete retenido. Si el sistema
  sigue en 22.04 y dpkg está sano (`lsb_release -r` dice 22.04 y `dpkg --audit` sale vacío):
  arreglar la causa, `reset-failed`, `rm /var/lib/os-upgrade/release-upgrade.started` (confirma
  que no quedó nada a medias) y borrar el Job.
- **`el release upgrade empezó y no terminó`:** hubo un corte o reboot a mitad. **No se reintenta
  automáticamente.** Revisar a mano (`dpkg --configure -a`, `apt-get -f install`,
  `/var/log/dist-upgrade/`). Si el sistema queda consistente en 24.04: `reset-failed`, borrar
  `/var/lib/os-upgrade/release-upgrade.started` y borrar el Job (instalará el kernel y reiniciará).
  Si no, reinstalar el nodo.
- **`no hay entrada de GRUB para ...` / `grub.cfg no tomó GRUB_DEFAULT`:** el nodo está en 24.04
  pero **no se ha reiniciado**. Revisar `update-grub`, `/etc/default/grub` y
  `/etc/default/grub.d/`. Tras arreglarlo: `reset-failed` y borrar el Job.
- **`demasiados reboots`:** el nodo no arranca el kernel fijado. Revisar
  `grep GRUB_DEFAULT /etc/default/grub.d/*` y `uname -r`, y el menú de GRUB por la consola del
  servidor.
- **`dpkg --audit reporta paquetes a medio instalar`:** `dpkg --configure -a`, revisar y
  `reset-failed`.
- **Abandonar el nodo por ahora:** `kubectl label node N os-upgrade-`, borrar el Job y
  `kubectl uncordon N` **solo si** `systemctl is-active os-upgrade-release` dice `inactive`.

### `rke2 no está activo tras el upgrade`

No deja marca: el Job lo reintenta. Revisar `systemctl status rke2-server` (o `rke2-agent`) y
`journalctl -u rke2-server`.

### El pod del Job está en `Pending` o `ImagePullBackOff`

- **Imagen:** la de los Jobs viene de Docker Hub por defecto. En clusters sin salida, configurar
  `images:` en el overlay ([configuracion.md](configuracion.md)).
- **Drain bloqueado:** el contenedor `drain` no termina si un PodDisruptionBudget lo impide.
  `kubectl -n $NS logs <pod> -c drain`.

### etcd degradado durante el control plane

Parar: no etiquetar más nodos. `sh scripts/check-cluster.sh`. Si un miembro no vuelve tras el
reboot, revisar `journalctl -u rke2-server` en ese nodo antes de tocar etcd.
