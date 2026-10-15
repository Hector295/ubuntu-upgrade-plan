# Configuración

Cada cluster tiene su overlay en `manifests/overlays/<cluster>/`, con dos archivos:

- `config.env`: parámetros del proceso en los nodos. Se convierte en el ConfigMap
  `os-upgrade-config-<hash>`, que los Jobs reciben como variables de entorno.
- `kustomization.yaml`: imagen, namespace y ajustes de los Plans (ventana, deadlines...).

Para crear un cluster nuevo: `cp -r manifests/overlays/lab manifests/overlays/<cluster>`.

> Cualquier cambio en `config.env` o en `scripts/upgrade.sh` genera un ConfigMap/Secret con
> otro hash y, por tanto, Plans nuevos. **No cambies la configuración con nodos a mitad
> de upgrade**; los nodos ya terminados no se ven afectados si tienen `os-upgrade=done`.

## Parámetros de `config.env`

Solo hace falta escribir los que cambian respecto al valor por defecto
(`manifests/base/config.env`).

| Parámetro | Por defecto | Descripción |
|---|---|---|
| `KERNEL_VERSION` | *(obligatorio)* | Kernel exacto, formato `X.Y.Z-N-generic` (p. ej. `6.8.0-139-generic`). Se instalan `linux-image`, `linux-modules` y `linux-modules-extra` de esa versión. Ver [kernel.md](kernel.md) |
| `SINGLE_REBOOT` | `true` | Si el nodo necesitaría un reboot previo al release upgrade (libc6, linux-base o un kernel de 22.04 pendientes), el preflight falla **antes del drain**. Con `false` solo avisa y el nodo reinicia dos veces |
| `REQUIRE_PREDOWNLOAD` | `true` | El preflight exige que la pre-descarga se haya hecho para este `KERNEL_VERSION`. Con `false` solo avisa y todo se descarga en la ventana |
| `APT_MIRROR` | *(vacío)* | Mirror para la pre-descarga, p. ej. `http://mirror.interno/ubuntu`. Vacío: el que usa el nodo en `sources.list` |
| `HTTP_PROXY` | *(vacío)* | Proxy HTTP para apt y `do-release-upgrade` (`http://host:puerto`) |
| `HTTPS_PROXY` | *(vacío)* | Proxy HTTPS |
| `NO_PROXY` | *(vacío)* | Destinos sin proxy (p. ej. el mirror interno) |
| `MIN_FREE_ROOT_MB` | `5000` | Espacio libre mínimo en `/` |
| `MIN_FREE_BOOT_MB` | `300` | Espacio libre mínimo en `/boot` |
| `MAX_REBOOTS` | `3` | Tope de reboots del proceso en un nodo; al superarlo el nodo queda marcado como fallido. Lo normal es 1 |

El proxy se exporta a apt, a `do-release-upgrade` y a la unidad systemd del host. Si los nodos
ya tienen el proxy configurado en apt (`Acquire::http::Proxy`), no hace falta repetirlo aquí.

## Ajustes de los Plans (`kustomization.yaml`)

Ejemplo completo de un overlay de producción (probado con `make validate`):

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../base

configMapGenerator:
  - name: os-upgrade-config
    behavior: merge
    envs:
      - config.env

# Imagen de los Jobs desde un registry interno (solo necesita sh y chroot).
images:
  - name: docker.io/library/ubuntu
    newName: registry.interno.local/library/ubuntu
    newTag: "24.04"

patches:
  # Ventana horaria: SUC no crea Jobs nuevos fuera de ella (los que están en curso siguen).
  - target: {kind: Plan, name: "os-upgrade-(workers|cp)"}
    patch: |
      - op: add
        path: /spec/window
        value: {days: ["saturday", "sunday"], startTime: "22:00", endTime: "06:00", timeZone: "UTC"}
  # Más margen por nodo (drain + upgrade + reboot de un bare metal lento).
  - target: {kind: Plan, name: "os-upgrade-(workers|cp)"}
    patch: |
      - op: replace
        path: /spec/jobActiveDeadlineSecs
        value: 10800
  # Más nodos pre-descargando a la vez (cuidado con el ancho de banda del proxy).
  - target: {kind: Plan, name: os-upgrade-predownload}
    patch: |
      - op: replace
        path: /spec/concurrency
        value: 4
```

Otros ajustes posibles con el mismo mecanismo: `namespace:` (si el SUC no está en
`cattle-system`), `/spec/serviceAccountName`, `imagePullSecrets` o `/spec/postCompleteDelay`
del Plan de control plane (por defecto `10m`).

### Valores por defecto de los Plans

| Plan | Nodos | concurrency | Deadline | Drain | Otros |
|---|---|---|---|---|---|
| `os-upgrade-predownload` | todos con `os-upgrade=predownload` | 2 | 3600 s | no | — |
| `os-upgrade-workers` | `os-upgrade=upgrade` sin rol control-plane | 1 | 7200 s | sí | prepare antes del drain |
| `os-upgrade-cp` | `os-upgrade=upgrade` con rol control-plane (incluye nodos con todos los roles) | 1 | 7200 s | sí | prepare, `postCompleteDelay: 10m` |

Los tres Plans toleran cualquier taint y son `exclusive` (en SUC v0.16 eso solo impide que
dos de estos Jobs coincidan **en el mismo nodo**; no serializa el cluster).

## Lo que la validación impide

`make validate CLUSTER=<cluster>` falla si:

- Un Plan usa un campo que el CRD del cluster no conoce (p. ej. `postCompleteLabels`) o con un
  tipo incorrecto. Se valida contra `manifests/schemas/<cluster>/crd-plans.json` en modo estricto.
- Aparece `spec.drain.timeout`: en SUC v0.16 son nanosegundos en int32 (máximo ≈ 2 s) y un valor
  grande rompió el listado de todos los Plans del controller.
- Un Plan con drain tiene `concurrency` distinto de 1.
- `jobActiveDeadlineSecs` no está entre 600 y 86400.
- Una imagen no lleva tag explícito.
- `KERNEL_VERSION` falta o tiene formato inválido; booleanos o números incorrectos;
  proxy o mirror sin `http://`/`https://`.
- Los recursos quedan en namespaces distintos.

Si actualizáis Rancher, volved a exportar el CRD:
`kubectl get crd plans.upgrade.cattle.io -o json > manifests/schemas/<cluster>/crd-plans.json`.
