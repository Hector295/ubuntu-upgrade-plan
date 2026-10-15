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

## Requisitos

- Clusters RKE2 con Rancher y su SUC en `cattle-system` (probado con `rancher/system-upgrade-controller:v0.16.3`).
- Nodos Ubuntu 22.04 (o 24.04, para solo cambiar de kernel), con GRUB.
- Acceso de los nodos a un mirror de Ubuntu (directo, por proxy o mirror interno).
- En tu equipo: `make`, `curl`, `kubectl` con acceso al cluster. El resto de herramientas
  se descarga en versiones fijas con `make tools`.

## Inicio rápido

```sh
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

El procedimiento completo, nodo a nodo, está en el **[runbook](docs/runbook.md)**.

## Documentación

- [docs/runbook.md](docs/runbook.md): procedimiento paso a paso, seguimiento y problemas frecuentes.
- [docs/configuracion.md](docs/configuracion.md): todos los parámetros y cómo personalizar un cluster.
- [docs/kernel.md](docs/kernel.md): elegir, verificar, cambiar y deshacer el kernel fijado.

## Estructura

```
scripts/upgrade.sh            se ejecuta en los nodos (subcomandos prepare, predownload, upgrade...)
scripts/validate-manifests.sh valida los Plans contra el CRD real del cluster y reglas propias
scripts/check-cluster.sh      estado de nodos, etcd y Jobs de SUC (se rehace en la iteración 2)
manifests/base/               Plans, configuración por defecto y config de kustomize
manifests/overlays/<cluster>/ lo único que se edita por cluster
manifests/schemas/<cluster>/  CRD de Plans exportado de cada cluster
tests/                        tests bats con stubs de apt, dpkg, systemctl, grub...
tools/                        install.sh descarga las herramientas fijadas (tools/bin no se versiona)
```

## Desarrollo

```sh
make lint       # shellcheck sin warnings (shell POSIX)
make test       # bats: lógica de upgrade.sh sobre una raíz falsa + validación de manifiestos
make check      # lint + test + validate
```

Nada de esto contacta con un cluster: `make` solo genera y valida archivos en local.

Convenciones: shell POSIX (`/bin/sh`, `set -eu`), mensajes y documentación en español,
identificadores en inglés.
