# Runbook: upgrade de un cluster

La ventana se hace con **`scripts/rollout.sh`** ([paso 4](#4-ventana-con-rolloutsh-recomendado)),
que lanza los nodos de uno en uno, supervisa cada fase, verifica el resultado y pide
confirmación antes del siguiente. Los procedimientos manuales, nodo a nodo
([paso 5](#5-ventana-manual-un-nodo-cada-vez)) o por grupos
([paso 6](#6-ventana-manual-por-grupos)), quedan como alternativa y como referencia de lo que
hace el orquestador.

Convenciones: `N` es el nombre del nodo, `G` el número de grupo y `NS=cattle-system`.

## Acceso al cluster (kubeconfig)

`make render` y `make validate` funcionan sin cluster. **Todo lo demás necesita un kubeconfig**
del cluster downstream (no el del cluster de Rancher) con permisos de **cluster-admin**. Hacen
falta para:

- exportar el CRD;
- crear los Plans, el Secret y el ConfigMap en `cattle-system`;
- poner labels a los nodos;
- leer Jobs y logs;
- hacer `exec` en los pods de etcd (`preflight.sh`, `rollout.sh`, `check-cluster.sh`).

Los scripts del operador necesitan además `make tools` (usan `tools/bin/yq`) y `date` de GNU.

Cómo obtenerlo:

- **Desde Rancher:** cluster → *Download KubeConfig*. Pasa por Rancher (por el
  `cattle-cluster-agent`): mientras se drena el nodo donde corre ese agente, la conexión se corta
  unos segundos y hay que relanzar los comandos con `-w` o `-f`.
- **Desde un nodo control plane:** `/etc/rancher/rke2/rke2.yaml`, cambiando `server:
  https://127.0.0.1:6443` por la IP o el FQDN de un control plane. Mejor uno que **no** se
  esté actualizando en ese momento, o un balanceador delante de los tres.

Con varios clusters, usa un archivo por cluster y comprueba **siempre** a cuál apuntas antes de
aplicar o etiquetar nada:

```sh
export KUBECONFIG=~/.kube/<cluster>.yaml
kubectl config current-context
kubectl get nodes -o wide          # ¿son los nodos que esperas?
NS=cattle-system
```

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
5. **Estado sano:** `sh scripts/preflight.sh` (solo lectura) comprueba de una vez el SUC, los
   Plans, que no haya Plans de Rancher en curso, nodos Ready, etcd (miembros, salud, un líder,
   RAFT INDEX igualado, alarmas), la antigüedad del último snapshot, PDBs que bloquearían el
   drain y el espacio libre de los nodos. Sale con 1 si algo falla.
   `sh scripts/check-cluster.sh` muestra el detalle (tablas de etcd, Jobs, pods con problemas).
6. **Definir los grupos** (para pre-descargar y actualizar por tandas):
   un label `os-upgrade-group` por nodo. Sirve para pre-descargar y actualizar por grupos.

   ```sh
   kubectl label node w1 w2 os-upgrade-group=1        # canario: 1-2 workers
   kubectl label node w3 w4 w5 w6 os-upgrade-group=2
   kubectl label node cp2 cp3 os-upgrade-group=3      # control plane no líderes
   kubectl label node cp1 os-upgrade-group=4          # control plane líder, siempre solo
   kubectl get nodes -L os-upgrade-group,os-upgrade
   ```

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

Sin drain, sin cordon y sin reboot. Se puede lanzar por nodos o por grupos; el Plan descarga
en 2 nodos a la vez (`concurrency`, ajustable en el overlay). Con el orquestador:

```sh
sh scripts/rollout.sh predownload --group G --wait   # etiqueta, espera y resume avisos por nodo
```

Omite los nodos `done`, `hold` y los que están en `upgrade`. Sin `--wait` solo etiqueta. A mano:

```sh
kubectl label node N1 N2 N3 os-upgrade=predownload --overwrite      # por nodos
kubectl label node -l os-upgrade-group=G os-upgrade=predownload --overwrite   # por grupo
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

## 4. Ventana con `rollout.sh` (recomendado)

```sh
sh scripts/preflight.sh --group G                     # solo lectura
sh scripts/rollout.sh upgrade --group G --dry-run     # plan, orden y comprobaciones, sin cambiar nada
sh scripts/rollout.sh upgrade --group G               # la ventana
sh scripts/rollout.sh status --group G                # estado de los nodos del grupo
```

En vez de `--group G` se puede usar `--nodes n1,n2`. La ventana dura horas: ejecútalo dentro de
`tmux` o `screen`. Si la sesión se corta, **relanzar el mismo comando** retoma el nodo en curso
y omite los terminados (`done`) y los apartados (`hold`).

### Qué hace

1. Ordena los nodos: **workers → control plane no líderes → líder de etcd**, y muestra el plan.
   Un grupo puede mezclar workers y control plane: el orquestador los hace de uno en uno.
2. Comprueba el cluster: API, SUC, Plans aplicados, ningún Plan de Rancher en curso y snapshot
   de etcd reciente. Pide confirmación para empezar.
3. Para cada nodo:
   1. **Antes:** nodos Ready, ningún otro nodo en upgrade, etcd sano (miembros, salud, un líder,
      RAFT INDEX igualado, sin alarmas). Avisa si hay PDBs bloqueados en namespaces con pods en
      el nodo. Si el nodo es el líder de etcd, hace `move-leader` a otro miembro (preferiblemente
      ya actualizado) y comprueba que el liderazgo cambió.
   2. **Lanza** el nodo (`os-upgrade=upgrade`) y **supervisa** las fases del Job: prepare, drain,
      upgrade, reboot.
   3. **Verifica** (reintentando hasta 5 min mientras se estabiliza): Ubuntu 24.04, kernel
      objetivo, Ready, schedulable, Plan terminado, pods del nodo sanos, todos los DaemonSets
      completos, etcd sano (si es control plane) y una prueba de DNS/red con un pod en ese nodo.
   4. Marca el nodo `os-upgrade=done` y **pide confirmación** antes del siguiente.

### Qué hace cuando algo va mal

| Situación | Reacción | Estado del nodo |
|---|---|---|
| `prepare` falla o supera `--prepare-timeout` | Muestra el log de prepare, aparta el nodo y para | **Intacto**: ni cordoneado ni drenado. `os-upgrade=hold` |
| El drain supera `--drain-timeout` | Muestra los pods que quedan y los PDBs bloqueados. Pregunta **[e]sperar** otro intervalo o **[a]bortar** (con `--yes`, aborta) | Al abortar: `hold` y **uncordon** (seguro: el upgrade no había empezado) |
| El Job falla después de empezar el upgrade, o se supera `--node-timeout` | Muestra condiciones del Job y log, y para | **Cordoneado** y en `upgrade`: ver *Problemas frecuentes* |
| La verificación no pasa | Para | En `upgrade` (no se marca `done`) |
| Respondes "no" entre nodos | Para limpiamente | Los terminados quedan en `done` |

Para reintentar un nodo apartado tras arreglar la causa: `kubectl label node N os-upgrade-` y
relanzar el comando.

### Opciones

| Opción | Por defecto | Descripción |
|---|---|---|
| `--dry-run` | — | No cambia nada: muestra el plan, las acciones (`[dry-run] kubectl ...`) y hace las comprobaciones |
| `--yes` | — | Sin preguntas. Ante un drain lento, aborta el nodo |
| `--drain-timeout` | `30m` | Tiempo máximo de drain antes de preguntar |
| `--prepare-timeout` | `15m` | Tiempo máximo del preflight del nodo |
| `--node-timeout` | `4h` | Tiempo máximo por nodo (de etiquetar a Plan terminado) |
| `--skip-net-test` | — | Omite la prueba de DNS (p. ej. si la imagen del Plan no está disponible para pods normales) |

Variables de entorno: `SETTLE_TIMEOUT` (`5m`), `POLL_SECONDS` (`15`), `ETCD_MIN_MEMBERS` (`3`),
`ETCD_RAFT_MAX_LAG` (`100`), `SNAPSHOT_MAX_AGE_HOURS` (`24`), `NS` (`cattle-system`).

La prueba de DNS crea un pod temporal `os-upgrade-nettest-<nodo>` en `cattle-system`, con la
imagen de los Plans, que ejecuta `getent hosts kubernetes.default.svc.cluster.local`.

## 5. Ventana manual: un nodo cada vez

Orden: **workers → control plane no líderes → control plane líder**.

### 5.1 Lanzar

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

### 5.2 Seguir

```sh
kubectl -n $NS get jobs,pods -l upgrade.cattle.io/node=N -o wide -w
kubectl -n $NS logs -l upgrade.cattle.io/node=N -c prepare
kubectl -n $NS logs -l upgrade.cattle.io/node=N -c upgrade -f
```

Los logs del pod marcan cada paso (`PASO 1/7` ... `PASO 7/7`). Durante el release upgrade, el
pod solo dice `Release upgrade en curso`. El detalle está en el nodo:

```sh
journalctl -fu os-upgrade-release          # unidad del host
tail -f /var/log/os-upgrade.log            # todas las fases, una línea ts=... node=... phase=... level=... msg="..."
grep 'level=WARN\|level=ERROR' /var/log/os-upgrade.log
tail -f /var/log/dist-upgrade/main.log     # log del upgrader de Ubuntu
sh /usr/local/sbin/os-upgrade.sh status    # resumen del estado (incluye el informe final)
```

Al terminar, cada nodo guarda un informe en `/var/log/os-upgrade-report.txt`:
- duración y número de reboots;
- versiones de sistema y kernel;
- resultado del hook;
- fuentes de apt que el upgrade desactivó;
- paquetes retenidos.

### 5.3 Comprobar que terminó

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

### 5.4 Cerrar el nodo

```sh
kubectl label node N os-upgrade=done --overwrite
```

**Imprescindible:** sin este cambio, cualquier cambio futuro de los Plans (otro hash) volvería a
lanzar el proceso en ese nodo.

### 5.5 Control plane líder

Antes de lanzar el nodo líder de etcd, mover el liderazgo a otro miembro ya actualizado. El
contenedor de etcd de RKE2 **no tiene `/bin/sh`**: `etcdctl` se ejecuta directamente con
`kubectl exec`, sin `sh -c`.

```sh
POD=$(kubectl -n kube-system get pod -l component=etcd -o name | head -n1)
CERTS="--cacert /var/lib/rancher/rke2/server/tls/etcd/server-ca.crt --cert /var/lib/rancher/rke2/server/tls/etcd/server-client.crt --key /var/lib/rancher/rke2/server/tls/etcd/server-client.key"
kubectl -n kube-system exec $POD -- etcdctl $CERTS endpoint status --cluster -w table   # IS LEADER e ID
kubectl -n kube-system exec $POD -- etcdctl $CERTS --endpoints=https://<IP-del-lider>:2379 move-leader <ID-hex-destino>
kubectl -n kube-system exec $POD -- etcdctl $CERTS endpoint status --cluster -w table   # comprobar el cambio
```

(`$CERTS` va sin comillas a propósito: son varias opciones.) Luego seguir con 5.1.

## 6. Ventana manual: por grupos

Es la alternativa manual al paso 5 cuando hay muchos nodos (con `rollout.sh`, basta con `--group`). Se etiqueta un grupo entero de una vez y el
SUC los procesa **de uno en uno** (`concurrency: 1`), sin esperar confirmación entre nodos.

### Cómo se comporta el SUC con un grupo (v0.16.3)

- **Uno detrás de otro:** cuando un nodo termina, el SUC empieza el siguiente del mismo Plan. No
  verifica nada más entre medias (en el control plane espera `postCompleteDelay: 10m`).
- **Orden no controlable:** dentro de un Plan, el SUC ordena los nodos por un hash de su UID, no
  por nombre. Si el orden importa, separa los nodos en grupos distintos.
- **Un fallo para el grupo:** un nodo cuyo Job falla sigue ocupando el hueco de `concurrency: 1`
  y el SUC no empieza otro. Pero si se le **quita el label** a ese nodo, el SUC pasa al
  siguiente del grupo (ver *Pausar o detener un grupo*).
- **Workers y control plane van en paralelo:** son Plans distintos y `exclusive` no los
  serializa. Un grupo debe ser **solo de workers o solo de control plane**, y no se lanza un grupo
  de un tipo mientras haya otro del otro tipo en curso.

### Reglas para formar los grupos

1. **Grupo 1 = canario:** 1 o 2 workers. Verificarlos a fondo (5.3) antes de seguir.
2. **Workers:** grupos del tamaño que podáis vigilar en la ventana. Se drena de uno en uno, así
   que la capacidad del cluster solo pierde un nodo cada vez.
3. **Control plane no líderes:** pueden ir juntos en un grupo (el SUC los hace de uno en uno con
   10 min entre ellos). Con 3 control plane, son 2 nodos.
4. **Control plane líder:** siempre en un grupo propio, después de `move-leader` (5.5).
5. **Nodos con todos los roles:** cuentan como control plane (Plan `os-upgrade-cp`).

### Lanzar un grupo

El selector excluye los nodos ya terminados (`done`) y los apartados (`hold`), así que relanzar
un grupo nunca repite nodos:

```sh
G=2
SEL="os-upgrade-group=$G,os-upgrade notin (done,hold)"
kubectl get nodes -l "$SEL" -L os-upgrade        # revisar qué nodos entran
kubectl label node -l "$SEL" os-upgrade=upgrade --overwrite
```

### Seguir el grupo

```sh
PLAN=os-upgrade-workers    # u os-upgrade-cp
H=$(kubectl -n $NS get plan $PLAN -o jsonpath='{.status.latestHash}')
kubectl -n $NS get plan $PLAN -o jsonpath='{.status.applying}'; echo   # nodo en curso
kubectl get nodes -l os-upgrade-group=$G -L os-upgrade -L plan.upgrade.cattle.io/$PLAN
kubectl get nodes -l "os-upgrade-group=$G,plan.upgrade.cattle.io/$PLAN=$H"   # terminados
kubectl -n $NS get jobs -l upgrade.cattle.io/plan=$PLAN -w
```

El seguimiento de cada nodo (logs, `journalctl`, `status`) es el mismo que en 5.2.

### Cerrar el grupo

Cuando todos los nodos del grupo estén terminados y verificados (5.3), se marcan como `done`.
El selector solo incluye los nodos cuyo hash coincide con el del Plan, así que nunca marca uno a
medias:

```sh
kubectl label node -l "os-upgrade-group=$G,plan.upgrade.cattle.io/$PLAN=$H" os-upgrade=done --overwrite
kubectl get nodes -l os-upgrade-group=$G -L os-upgrade     # todos deben estar en done
sh scripts/check-cluster.sh
```

Pasar al siguiente grupo solo con el cluster sano.

### Pausar o detener un grupo

Quitar el label a los nodos que **todavía no han empezado**. El que está en curso termina su
proceso (no se puede parar un release upgrade a medias):

```sh
APPLYING=$(kubectl -n $NS get plan $PLAN -o jsonpath='{.status.applying[*]}')
for n in $(kubectl get nodes -l "os-upgrade-group=$G,os-upgrade=upgrade" -o name | cut -d/ -f2); do
  case " $APPLYING " in *" $n "*) echo "en curso, se deja: $n" ;; *) kubectl label node "$n" os-upgrade- ;; esac
done
```

Para reanudar, se lanza el grupo otra vez con el mismo comando de *Lanzar un grupo*: solo
entran los nodos pendientes.

### Si un nodo del grupo falla

El grupo se queda parado en ese nodo (ocupa el hueco). Opciones:

- **Arreglarlo y continuar:** ver *Problemas frecuentes*. Cuando termine, el SUC sigue con el
  resto del grupo.
- **Apartarlo y que el grupo siga:** primero **pausar** el grupo (si no, el SUC empezará otro
  nodo en cuanto se libere el hueco). Después apartar el nodo fallido con
  `kubectl label node N os-upgrade=hold --overwrite` (ningún Plan lo selecciona y el relanzamiento
  del grupo lo excluye), revisarlo aparte y reanudar el grupo. Cuando esté arreglado, se lanza
  solo: `kubectl label node N os-upgrade=upgrade --overwrite`.

## 7. Final de la campaña

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
| `el mirror de Ubuntu del nodo (...) no es un mirror público` | Mirror interno con `ALLOW_THIRD_PARTY=false`: el upgrade lo cambiaría a `archive.ubuntu.com`. Usar `ALLOW_THIRD_PARTY=true` ([configuracion.md](configuracion.md#fuentes-de-apt-mirror-interno-y-repos-de-terceros)) |
| `el hook post-upgrade tiene errores de sintaxis` | Corregir `post-upgrade-hook.sh` del overlay, `make validate` y `kubectl apply` |
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
- **`el hook post-upgrade falló N veces`:** el nodo ya está en 24.04 con el kernel fijado, pero
  la comprobación propia no pasa. Su salida está en `grep 'msg="hook:' /var/log/os-upgrade.log`.
  Arreglar la causa en el nodo, `reset-failed` y borrar el Job: el siguiente intento solo cierra
  (vuelve a ejecutar el hook, sin reboot).
- **Abandonar el nodo por ahora:** `kubectl label node N os-upgrade-`, borrar el Job y
  `kubectl uncordon N` **solo si** `systemctl is-active os-upgrade-release` dice `inactive`.

### Fuentes de apt desactivadas tras el upgrade

Aviso `fuentes desactivadas por el upgrade` (también en el informe del nodo): el upgrader las
comentó (`# ... disabled on upgrade to noble` en `.list`) o les puso `Enabled: no` (en
`.sources`) porque no publican `noble` o porque `ALLOW_THIRD_PARTY=false`. No impide terminar.
Si hacen falta, comprobar que el proveedor tiene paquetes para 24.04 y reactivarlas a mano
cambiando `jammy` por `noble`.

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
