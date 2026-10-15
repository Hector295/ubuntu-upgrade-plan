# Rollback

Ubuntu **no permite volver a la LTS anterior** (de 24.04 a 22.04, o de 26.04 a 24.04) en el mismo
sistema. Los ejemplos son de la campaña a 24.04. "Rollback" aquí significa
devolver el nodo (y el cluster) a un estado sano por una de estas vías:

| Vía | Cuándo | Impacto |
|---|---|---|
| [A. Arreglar en 24.04](#a-arreglar-el-nodo-en-2404) | El sistema arranca; falla algo concreto (un servicio, un repo, el hook) | Solo ese nodo, sin reinstalar |
| [B. Cambiar de kernel](#b-volver-a-otro-kernel) | El problema es el kernel fijado (driver, rendimiento, hardware) | Un reboot por nodo |
| [C. Reconstruir un worker](#c-reconstruir-un-worker) | El worker no arranca o no merece la pena arreglarlo | Reinstalar SO y volver a registrar en Rancher |
| [D. Reconstruir un control plane](#d-reconstruir-un-control-plane--etcd) | Igual, en un nodo control plane + etcd | Como C, cuidando el quórum de etcd |
| [E. Restaurar etcd desde snapshot](#e-pérdida-de-quórum-de-etcd-último-recurso) | Se ha perdido el quórum de etcd | **Todo el cluster**; último recurso |

En cualquier caso, **primero parar la campaña**: no lanzar más nodos y, si `rollout.sh` está en
marcha, responder "no" o interrumpirlo. El nodo afectado se aparta con
`kubectl label node N os-upgrade=hold --overwrite`.

## Antes de la campaña: lo que hace posible el rollback

Las vías C, D y E dependen de cosas que hay que tener **antes** de empezar:

1. **Snapshot de etcd reciente y fuera de los nodos.** `preflight.sh` comprueba que exista uno
   de menos de 24 h. Debe estar copiado fuera del cluster (S3 configurado en Rancher, o copia
   manual de `/var/lib/rancher/rke2/server/db/snapshots/`).
2. **Comando de registro del cluster** en Rancher (*Cluster Management → el cluster →
   Registration*) y los roles de cada nodo (`kubectl get nodes -L os-upgrade-group` y los
   labels `node-role.kubernetes.io/*`).
3. **Medio de instalación** de los servidores (ISO o PXE de Ubuntu 22.04 o 24.04) y acceso a su
   consola remota (iDRAC/iLO/IPMI): un bare metal que no arranca solo se arregla desde ahí.
4. **Configuración propia de cada nodo** que no recrea el registro en Rancher: red (bonding,
   VLANs), montajes, `/etc/rancher/rke2/config.yaml` y `registries.yaml` si los hay, agentes de
   monitorización. Vuestro `post-upgrade-hook.sh` es una buena lista de lo que hay que comprobar.
5. **Un kernel alternativo disponible** en el archivo (ver [kernel.md](kernel.md)), por si hay
   que usar la vía B.

## A. Arreglar el nodo en 24.04

El caso más habitual: el nodo arranca en 24.04 pero el Job falló o el hook no pasa. Ver
[Problemas frecuentes del runbook](runbook.md#problemas-frecuentes). Tras arreglarlo:

```sh
sh /usr/local/sbin/os-upgrade.sh reset-failed   # en el nodo
kubectl -n $NS delete job -l upgrade.cattle.io/node=N
kubectl label node N os-upgrade=upgrade --overwrite   # si estaba en hold
```

El Job se recrea, termina el cierre (sin reboot si el kernel fijado ya está arrancado) y el SUC
hace el uncordon.

## B. Volver a otro kernel

**El sistema arranca** (aunque sea con problemas): se cambia a otra versión con el flujo normal
de la herramienta. Es un reboot por nodo, sin release upgrade:

1. Elegir una ABI publicada y comprobarla ([kernel.md](kernel.md#elegir-y-verificar-la-versión)).
2. `KERNEL_VERSION=<otra>` en `config.env`, `make validate` y `kubectl apply`.
3. `rollout.sh predownload` y `rollout.sh upgrade` para los nodos afectados. Antes, quitar el
   `done` de esos nodos: `kubectl label node N os-upgrade-`.

**El nodo no arranca con el kernel fijado:**

- **Antes del cierre** (justo tras el reboot del upgrade), el kernel de 22.04 sigue instalado. Desde la
  consola remota, en el menú de GRUB, *Advanced options for Ubuntu* → el kernel anterior. En
  servidores el menú suele estar oculto: pulsar `Esc` (UEFI) o mantener `Shift` (BIOS) al
  arrancar. Con el
  nodo arrancado, aplicar la vía B normal (otra `KERNEL_VERSION`).
- **Después del cierre** solo queda el kernel fijado (el proceso purga los demás). Hay que
  arrancar desde un medio de rescate (ISO de 24.04 → *Rescue*), hacer `chroot` en el sistema e
  instalar otro kernel:

  ```sh
  # desde el sistema de rescate, con / del nodo montado en /mnt (y /boot, /boot/efi si aplica)
  for d in dev proc sys run; do mount --bind /$d /mnt/$d; done
  chroot /mnt
  V=6.8.0-NNN-generic                                     # el kernel alternativo
  apt-mark unhold $(apt-mark showhold | grep '^linux-')
  apt-get install linux-image-$V linux-modules-$V linux-modules-extra-$V
  apt-mark hold linux-image-$V linux-modules-$V linux-modules-extra-$V
  rm /etc/default/grub.d/99-os-upgrade-kernel.cfg         # el siguiente cierre lo regenera
  update-grub
  ```

  Si no compensa, reconstruir el nodo (vía C o D).

> La herramienta no conserva un kernel de respaldo: tras el cierre solo queda el kernel fijado.
> Así ningún otro kernel puede arrancar por sorpresa, pero un fallo de arranque posterior
> obliga a usar el medio de rescate.

## C. Reconstruir un worker

1. **Sacarlo del cluster**:

   ```sh
   kubectl label node N os-upgrade=hold --overwrite
   kubectl drain N --ignore-daemonsets --delete-emptydir-data --timeout=30m
   ```

   En Rancher: *Cluster Management → el cluster → Machines → N → Delete*. Esperar a que el nodo
   desaparezca de `kubectl get nodes`.
2. **Reinstalar el sistema** desde el medio de instalación:
   - **Ubuntu 24.04 directamente** (recomendado): ya no hay release upgrade pendiente.
   - **22.04**: el nodo vuelve a la campaña desde el principio.

   Restaurar la configuración propia del nodo (red, montajes, `registries.yaml`...).
3. **Volver a registrarlo** con el comando de registro de Rancher y el rol **worker**. Esperar a que
   esté Ready y volver a poner sus labels:
   `kubectl label node N os-upgrade-group=<G>`.
4. **Si se instaló 24.04:** fijar el kernel con la herramienta. Un nodo que ya está en 24.04 solo
   instala el kernel, aplica el pin y GRUB, y hace un reboot:

   ```sh
   kubectl label node N os-upgrade-
   sh scripts/rollout.sh predownload --nodes N --wait
   sh scripts/rollout.sh upgrade --nodes N
   ```

Si se reutiliza el disco sin reinstalar (p. ej. para volver a registrarlo tras un fallo de
RKE2), limpiar antes RKE2 y el agente de Rancher en el nodo:

```sh
sudo /usr/local/bin/rancher-system-agent-uninstall.sh   # si existe (clusters creados desde Rancher)
sudo /usr/local/bin/rke2-uninstall.sh
```

## D. Reconstruir un control plane + etcd

Igual que la vía C, con estas reglas **obligatorias** para no perder el quórum de etcd:

1. **Solo un control plane a la vez**, y solo si los otros dos miembros de etcd están sanos:
   `sh scripts/check-cluster.sh` debe dar 3 miembros, todos sanos, y un líder.
2. Si el nodo es el **líder de etcd**, mover antes el liderazgo (runbook, 5.5).
3. Borrar la máquina en Rancher y **comprobar que su miembro de etcd desaparece**:

   ```sh
   POD=$(kubectl -n kube-system get pod -l component=etcd -o name | head -n1)
   CERTS="--cacert /var/lib/rancher/rke2/server/tls/etcd/server-ca.crt --cert /var/lib/rancher/rke2/server/tls/etcd/server-client.crt --key /var/lib/rancher/rke2/server/tls/etcd/server-client.key"
   kubectl -n kube-system exec $POD -- etcdctl $CERTS member list -w table
   ```

   Si el miembro sigue en la lista, quitarlo desde un pod de etcd sano:
   `kubectl -n kube-system exec $POD -- etcdctl $CERTS member remove <ID-hex>`.
4. Reinstalar y volver a registrar con los roles que tenía (**etcd + control plane**, y **worker**
   si el nodo tenía todos los roles).
5. **No seguir** hasta que `check-cluster.sh` vuelva a dar 3 miembros sanos y un líder.

## E. Pérdida de quórum de etcd (último recurso)

Si dos de los tres miembros de etcd se pierden a la vez, el API server deja de funcionar. Solo
queda **restaurar el cluster desde un snapshot** en Rancher (*Cluster Management → el cluster →
Snapshots → Restore*). La restauración afecta a **todo el cluster** y pierde los cambios
posteriores al snapshot. Seguir la documentación de Rancher de vuestra versión antes de hacerlo.

La campaña está diseñada para no llegar aquí:
- un solo nodo cada vez;
- etcd sano antes de cada nodo;
- `move-leader` antes de tocar al líder;
- `postCompleteDelay` entre control planes.

## Limpieza de los cambios de os-upgrade en un nodo

Lo que la herramienta deja **a propósito** para garantizar el kernel, y cómo quitarlo si se
abandona el kernel fijado (detalle en [kernel.md](kernel.md#deshacer-el-pin-volver-a-kernels-gestionados-por-ubuntu)):

| Archivo / estado | Para qué |
|---|---|
| `/etc/apt/preferences.d/99-os-upgrade-kernel` | Bloquea los metapaquetes de kernel |
| `/etc/default/grub.d/99-os-upgrade-kernel.cfg` | `GRUB_DEFAULT` al kernel fijado |
| `apt-mark hold` de los 3 paquetes del kernel | Que no se quite ni se cambie |
| `/usr/local/sbin/os-upgrade.sh` | Copia del script (status, reset-failed) |
| `/var/lib/os-upgrade/` | Estado del proceso (`done`, `config`) |
| `/var/log/os-upgrade.log`, `/var/log/os-upgrade-report.txt` | Log e informe |
