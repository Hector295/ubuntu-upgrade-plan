# os-upgrade: Ubuntu 22.04 → 24.04 con kernel fijado en nodos RKE2

Herramienta para actualizar in place el sistema operativo de los nodos de clusters RKE2
gestionados por Rancher, usando el **system-upgrade-controller (SUC)** que Rancher ya despliega
en `cattle-system`. No modifica el SUC ni los Plans de Rancher.

Qué hace en cada nodo:

- Actualiza Ubuntu 22.04 → 24.04 con `do-release-upgrade`.
- Instala **exactamente** el kernel indicado en `KERNEL_VERSION` (p. ej. `6.8.0-139-generic`:
  `linux-image`, `linux-modules` y `linux-modules-extra`) y garantiza que se quede: sin
  metapaquetes, `apt-mark hold`, pin de apt y `GRUB_DEFAULT` fijo. Ver [docs/kernel.md](docs/kernel.md).
- **Un solo reboot** por nodo en la ventana (pensado para bare metal).
- Descarga previa de paquetes, sin drain, días antes de la ventana: la ventana no depende de la red.
- Preflight antes del drain: si el nodo no puede actualizarse, falla sin cordonearlo.
- Idempotente: cada reboot mata el pod, el Job crea otro y el proceso continúa donde quedó.
- Mantiene el mirror interno y los repos de terceros que publican 24.04
  (`--allow-third-party`) y avisa de los que se desactivan.
- Hook post-upgrade opcional por cluster para comprobaciones propias, e informe final en cada
  nodo (`/var/log/os-upgrade-report.txt`).

## Requisitos

- Clusters RKE2 con Rancher y su SUC en `cattle-system` (probado con `rancher/system-upgrade-controller:v0.16.3`).
- Nodos Ubuntu 22.04 (o 24.04, para solo cambiar de kernel), con GRUB.
- Acceso de los nodos a un mirror de Ubuntu (directo, por proxy o mirror interno).
- En tu equipo: `make`, `curl` y `kubectl`. El resto de herramientas se descarga en versiones
  fijas con `make tools`.
- **Un kubeconfig del cluster downstream con permisos de cluster-admin** para exportar el CRD,
  aplicar los Plans, etiquetar nodos y consultar etcd. `make render`/`make validate` no lo
  necesitan. Cómo obtenerlo y precauciones con varios clusters:
  [runbook → Acceso al cluster](docs/runbook.md#acceso-al-cluster-kubeconfig).

## Inicio rápido

```sh
export KUBECONFIG=~/.kube/mi-cluster.yaml   # kubeconfig del cluster (cluster-admin)
kubectl config current-context              # comprobar SIEMPRE a qué cluster apuntas
make tools                                  # shellcheck, bats, kubeconform, kustomize, yq en tools/bin
cp -r manifests/overlays/lab manifests/overlays/mi-cluster
$EDITOR manifests/overlays/mi-cluster/config.env      # como mínimo KERNEL_VERSION
mkdir -p manifests/schemas/mi-cluster
kubectl get crd plans.upgrade.cattle.io -o json > manifests/schemas/mi-cluster/crd-plans.json
make validate CLUSTER=mi-cluster            # genera out/mi-cluster.yaml y lo valida
kubectl apply -f out/mi-cluster.yaml        # crea los Plans; no afecta a ningún nodo todavía
```

Los Plans solo actúan sobre nodos con el label `os-upgrade`:

| Label | Plan | Qué hace |
|---|---|---|
| `os-upgrade=predownload` | `os-upgrade-predownload` | Descarga paquetes. Sin drain ni reboot |
| `os-upgrade=upgrade` | `os-upgrade-workers` / `os-upgrade-cp` | Preflight → drain → upgrade → 1 reboot |
| `os-upgrade=done` | ninguno | Nodo terminado (lo pones tú al acabar) |
| `os-upgrade=hold` | ninguno | Nodo apartado: se excluye al lanzar o reanudar un grupo |

Los labels los pone el orquestador:

```sh
sh scripts/preflight.sh --group 1                      # comprobaciones, solo lectura
sh scripts/rollout.sh predownload --group 1 --wait     # pre-descarga (sin impacto)
sh scripts/rollout.sh upgrade --group 1 --dry-run      # plan y comprobaciones, sin cambiar nada
sh scripts/rollout.sh upgrade --group 1                # nodo a nodo, verificando y confirmando
sh scripts/rollout.sh status --group 1
```

`rollout.sh` ordena workers → control plane no líderes → líder de etcd (con `move-leader`
antes). Supervisa prepare y drain con timeout, y aparta el nodo sin tocarlo si fallan. Después
de cada nodo verifica 24.04, kernel, DaemonSets, pods, DNS y etcd, y pide confirmación antes
del siguiente. Los grupos son un label `os-upgrade-group=<n>`.

El procedimiento completo, incluida la alternativa manual, está en el
**[runbook](docs/runbook.md)**.

## Documentación

- [docs/runbook.md](docs/runbook.md): procedimiento paso a paso, seguimiento y problemas frecuentes.
- [docs/configuracion.md](docs/configuracion.md): todos los parámetros y cómo personalizar un cluster.
- [docs/kernel.md](docs/kernel.md): elegir, verificar, cambiar y deshacer el kernel fijado.
- [docs/rollback.md](docs/rollback.md): qué hacer si un nodo sale mal: arreglarlo, otro kernel,
  reconstruir worker o control plane, restaurar etcd.
- [docs/lab.md](docs/lab.md): lab de VMs con libvirt para probar todo el flujo de principio a fin.

## Estructura

```
scripts/upgrade.sh            se ejecuta en los nodos (subcomandos prepare, predownload, upgrade...)
scripts/rollout.sh            orquestador: predownload, upgrade nodo a nodo, status
scripts/preflight.sh          comprobaciones previas del cluster (solo lectura)
scripts/check-cluster.sh      estado detallado de nodos, etcd, Jobs y pods, con veredicto
scripts/lib/                  librerías del operador: kubectl, etcd y comprobaciones
scripts/validate-manifests.sh valida los Plans contra el CRD real del cluster y reglas propias
lab/lab.sh                    lab de VMs (libvirt) con RKE2 y el SUC oficial para pruebas e2e
manifests/base/               Plans, configuración por defecto y config de kustomize
manifests/overlays/<cluster>/ lo único que se edita por cluster
manifests/schemas/<cluster>/  CRD de Plans exportado de cada cluster
tests/                        tests bats: stubs del nodo (apt, dpkg, systemctl, grub...) y de kubectl
tools/                        install.sh descarga las herramientas fijadas (tools/bin no se versiona)
```

## Desarrollo

```sh
make lint       # shellcheck sin warnings (shell POSIX)
make test       # bats: upgrade.sh sobre una raíz falsa, rollout/preflight sobre un cluster falso y manifiestos
make check      # lint + test + validate
lab/lab.sh up && lab/lab.sh e2e   # prueba completa en VMs locales (ver docs/lab.md)
```

Nada de esto contacta con un cluster: `make` solo genera y valida archivos en local.

Convenciones: shell POSIX (`/bin/sh`, `set -eu`), mensajes y documentación en español,
identificadores en inglés.
