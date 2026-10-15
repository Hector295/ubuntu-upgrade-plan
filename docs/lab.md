# Lab de VMs (pruebas de extremo a extremo)

`lab/lab.sh` crea en tu equipo un cluster RKE2 con VMs Ubuntu 22.04 sobre libvirt e instala el
**system-upgrade-controller oficial v0.16.3** (la misma versión que usa Rancher). Sirve para
probar todo el flujo (`preflight.sh`, `rollout.sh`, los Plans y `upgrade.sh`) sin tocar ningún
cluster real.

## Requisitos

- libvirt con KVM: `virsh`, `virt-install`, `genisoimage`. Tu usuario en el grupo `libvirt`.
  Se usa `qemu:///system`, el pool `default` y la red `default` (NAT con DHCP).
- `ssh`, `curl` y `make tools` (el lab usa el `kubectl` fijado en `tools/bin`, v1.33).
- Recursos con la topología por defecto (3 control plane + 1 worker): **16 GB de RAM, 8 vCPU** y
  unos 10 GB de disco en el pool (discos en copia sobre una imagen base común).
- Salida a internet desde las VMs: imagen de Ubuntu, RKE2, imagen `ubuntu:24.04` de los Jobs y
  paquetes de 24.04.

## Uso

```sh
lab/lab.sh plan        # qué se va a crear (no cambia nada)
lab/lab.sh up          # VMs + RKE2 + SUC; deja el kubeconfig en .lab/kubeconfig (~15-20 min)
eval "$(lab/lab.sh env)"   # KUBECONFIG y NS=system-upgrade para kubectl y los scripts
lab/lab.sh e2e         # prueba completa (ver abajo)
lab/lab.sh reports     # informe de os-upgrade de cada nodo
lab/lab.sh ssh osu-lab-cp1
lab/lab.sh down        # borra las VMs y sus discos (conserva la imagen base para la próxima vez)
lab/lab.sh destroy     # además borra la imagen base y .lab/
```

Topología y versión, por variables de entorno:

```sh
LAB_CP=1 LAB_WORKERS=1 lab/lab.sh up          # versión mínima (8 GB): sin move-leader
LAB_RKE2_VERSION=v1.33.13+rke2r1 lab/lab.sh up  # otra versión (por defecto v1.33.13+rke2r2)
LAB_RKE2_VERSION= LAB_RKE2_CHANNEL=v1.34 lab/lab.sh up   # última de un canal
LAB_UEFI=true lab/lab.sh up                     # arranque UEFI, como bare metal UEFI
```

Con `LAB_CP` inferior a 3, `preflight.sh` y `rollout.sh` fallarán en la comprobación de etcd
(mínimo 3 miembros); para esa topología: `export ETCD_MIN_MEMBERS=1`.

**Seguridad:** el lab solo crea y borra VMs y volúmenes con su prefijo (`osu-lab-cp1`,
`osu-lab-w1`, `osu-lab-base-jammy.qcow2`...), por nombre exacto. Las demás VMs de libvirt no
se tocan; hay tests que lo comprueban.

## Qué hace `e2e`

1. Genera los manifiestos del overlay `manifests/overlays/lab-vm` y los valida contra el CRD
   **exportado del lab** (`.lab/schema/crd-plans.json`).
2. Aplica los Plans y ejecuta `preflight.sh`.
3. `rollout.sh predownload --wait` del grupo 1 (worker) y del grupo 2 (control plane).
4. `rollout.sh upgrade --yes` del grupo 1 y luego del grupo 2: incluye `move-leader` del líder de
   etcd, la supervisión de fases y la verificación tras cada nodo.
5. Comprueba que **todos** los nodos quedan en Ubuntu 24.04 con el `KERNEL_VERSION` del overlay y
   que `check-cluster.sh` está sano.

Con 4 nodos tarda del orden de 1,5-2 h (cada nodo: drain, release upgrade y un reboot).
`lab/lab.sh reports` muestra después el informe de cada nodo.

El overlay `lab-vm` difiere del de un cluster de Rancher en el namespace y la ServiceAccount del
SUC oficial (`system-upgrade`) y en un `postCompleteDelay` de 2 min.

## Qué no cubre el lab

- **Bare metal:** firmware, controladoras RAID, NICs y tiempos de arranque reales. GRUB se prueba
  en BIOS o UEFI (`LAB_UEFI=true`), sin Secure Boot.
- **Rancher:** se usa el SUC oficial, no el de Rancher; no hay agente de Rancher en los nodos.
- **Proxy y mirror interno:** las VMs salen directamente a internet.
- **Cargas de trabajo y PDBs:** el cluster está vacío. Para probar el drain se pueden desplegar
  aplicaciones de prueba con PDBs antes del `e2e`.
