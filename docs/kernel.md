# Kernel fijado (`KERNEL_VERSION`)

La única opción de kernel es una versión exacta, p. ej. `KERNEL_VERSION=6.8.0-139-generic`.
Se instalan siempre tres paquetes de esa versión:

- `linux-image-6.8.0-139-generic`
- `linux-modules-6.8.0-139-generic`
- `linux-modules-extra-6.8.0-139-generic`

## Elegir y verificar la versión

La versión tiene que estar publicada en el archivo de Ubuntu 24.04 (o en vuestro mirror).
Ubuntu va retirando del índice ABIs antiguas, así que conviene comprobarlo antes de cada campaña:

```sh
# Desde un equipo con acceso (añadir -x http://proxy:puerto si hace falta):
for pocket in noble-updates noble-security; do
  curl -fsSL "http://archive.ubuntu.com/ubuntu/dists/$pocket/main/binary-amd64/Packages.gz" \
    | zcat | grep -E '^Package: linux-(image|modules|modules-extra)-6\.8\.0-139-generic$'
done
```

Deben salir las tres líneas. En un nodo 24.04 también vale
`apt-cache policy linux-image-6.8.0-139-generic`.

Además, la **pre-descarga** lo comprueba en cada nodo: si el kernel no está disponible, el Job de
pre-descarga falla con `no se pudo descargar el kernel ...`, días antes de la ventana.

## Cómo se garantiza que el kernel se queda

| Riesgo | Medida |
|---|---|
| El upgrade o un `apt upgrade` futuro instalan el kernel más nuevo a través del metapaquete (`linux-generic`, `linux-generic-hwe-*`...) | Los metapaquetes se quitan **antes** del full-upgrade de 22.04, y un pin de apt con prioridad `-1` impide reinstalarlos (`/etc/apt/preferences.d/99-os-upgrade-kernel`) |
| El upgrader de Ubuntu reinstala `linux-generic` por su cuenta (quirk `_install_linux_metapackage`) | El pin lo impide; en `/var/log/dist-upgrade/main.log` aparecerá `Installing/upgrading 'linux-generic' failed`, y es lo **esperado**. Si aun así se instalara, el proceso purga después cualquier kernel distinto del fijado |
| `autoremove` o una limpieza quitan el kernel fijado | `apt-mark hold` de sus tres paquetes |
| GRUB arranca otro kernel con versión mayor (p. ej. el HWE de 22.04 que estaba arrancado) | `GRUB_DEFAULT` apunta a la entrada exacta del kernel fijado (`/etc/default/grub.d/99-os-upgrade-kernel.cfg`). Se comprueba en `grub.cfg` **antes** de reiniciar; si no está, no se reinicia y el nodo queda marcado |
| Al quitar el metapaquete, `linux-firmware` y el microcode quedan huérfanos y `autoremove` los borra (NICs y RAID sin firmware) | Se marcan como instalados manualmente (`apt-mark manual`) |

Tras el reboot, el proceso comprueba que `uname -r` es el kernel fijado y purga los demás
kernels (incluido el de 22.04).

## Comprobar un nodo

```sh
uname -r                                          # 6.8.0-139-generic
apt-mark showhold | grep 6.8.0-139                # los tres paquetes
cat /etc/apt/preferences.d/99-os-upgrade-kernel   # Pin-Priority: -1
grep GRUB_DEFAULT /etc/default/grub.d/99-os-upgrade-kernel.cfg
dpkg -l 'linux-image-*' | grep ^ii                # solo el kernel fijado
sh /usr/local/sbin/os-upgrade.sh status
```

## Cambiar de kernel más adelante

El mismo proceso sirve para nodos que ya están en 24.04: no hace release upgrade, solo cambia
el kernel con un reboot.

1. Cambiar `KERNEL_VERSION` en `config.env` del overlay y `make validate CLUSTER=<cluster>`.
2. `kubectl apply -f out/<cluster>.yaml`.
3. Seguir el [runbook](runbook.md) desde la pre-descarga, poniendo de nuevo los labels
   `os-upgrade=predownload` y luego `os-upgrade=upgrade`.

El nuevo kernel queda retenido y el anterior se purga.

## Deshacer el pin (volver a kernels gestionados por Ubuntu)

Solo si se decide abandonar el kernel fijado. En el nodo:

```sh
V=6.8.0-139-generic
sudo apt-mark unhold linux-image-$V linux-modules-$V linux-modules-extra-$V
sudo rm /etc/apt/preferences.d/99-os-upgrade-kernel /etc/default/grub.d/99-os-upgrade-kernel.cfg
sudo apt-get install linux-generic          # o linux-generic-hwe-24.04
sudo update-grub
# reboot cuando corresponda (con drain)
```
