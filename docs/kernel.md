# Pinned kernel (`KERNEL_VERSION`)

The only kernel option is an exact version, e.g. `KERNEL_VERSION=6.8.0-139-generic`. Three
packages of that version are always installed, and which ones depends on the target release:

| Target | Packages |
|---|---|
| 24.04 | `linux-image-<v>`, `linux-modules-<v>`, `linux-modules-extra-<v>` |
| 26.04 | `linux-image-<v>`, `linux-modules-<v>` (includes what used to be in `-extra`), `linux-main-modules-zfs-<v>` |

## Choosing and checking the version

The version must be published in the archive of the target release (or in your mirror). Ubuntu
drops old ABIs from the index over time, so check it before each campaign:

```sh
# From a machine with access (add -x http://proxy:port if needed):
for pocket in noble-updates noble-security; do
  curl -fsSL "http://archive.ubuntu.com/ubuntu/dists/$pocket/main/binary-amd64/Packages.gz" \
    | zcat | grep -E '^Package: linux-(image|modules|modules-extra)-6\.8\.0-139-generic$'
done
```

All three lines must show up. For 26.04, replace `noble` with `resolute` and
`linux-(image|modules|modules-extra)` with `linux-(image|modules|main-modules-zfs)` (26.04 kernels
are the 7.0 series, e.g. `7\.0\.0-38-generic`). On a node already on the target release,
`apt-cache policy linux-image-6.8.0-139-generic` also works.

The **predownload** also checks it on every node: if the kernel is not available, the
predownload Job fails with `could not download kernel ...`, days before the window.

## How the kernel is kept in place

| Risk | Measure |
|---|---|
| The upgrade, or a future `apt upgrade`, installs the newest kernel through the metapackage (`linux-generic`, `linux-generic-hwe-*`...) | The metapackages are removed **before** the source release full-upgrade, and an apt pin with priority `-1` prevents reinstalling them (`/etc/apt/preferences.d/99-os-upgrade-kernel`) |
| The Ubuntu upgrader reinstalls `linux-generic` on its own (quirk `_install_linux_metapackage`) | The pin prevents it; `/var/log/dist-upgrade/main.log` will show `Installing/upgrading 'linux-generic' failed`, which is **expected**. If it got installed anyway, the process later purges any kernel other than the pinned one |
| `autoremove` or a cleanup removes the pinned kernel | `apt-mark hold` on its three packages |
| GRUB boots another kernel with a higher version (e.g. the source release HWE kernel that was running) | `GRUB_DEFAULT` points to the exact entry of the pinned kernel (`/etc/default/grub.d/99-os-upgrade-kernel.cfg`). It is checked in `grub.cfg` **before** rebooting; if it is not there, the node does not reboot and is marked as failed |
| Removing the metapackage orphans `linux-firmware` and the microcode, and `autoremove` deletes them (NICs and RAID without firmware) | They are marked as manually installed (`apt-mark manual`) |

After the reboot, the process checks that `uname -r` is the pinned kernel and purges the other
kernels (including the source release one).

## Checking a node

```sh
uname -r                                          # 6.8.0-139-generic
apt-mark showhold | grep 6.8.0-139                # the three packages
cat /etc/apt/preferences.d/99-os-upgrade-kernel   # Pin-Priority: -1
grep GRUB_DEFAULT /etc/default/grub.d/99-os-upgrade-kernel.cfg
dpkg -l 'linux-image-*' | grep ^ii                # only the pinned kernel
sh /usr/local/sbin/os-upgrade.sh status
```

## Changing the kernel later

The same process works for nodes already on the target release: it skips the release upgrade
and only changes the kernel, with one reboot.

1. Change `KERNEL_VERSION` in the overlay `config.env` and run `make validate CLUSTER=<cluster>`.
2. `kubectl apply -f out/<cluster>.yaml`.
3. Remove the `done` label from the nodes (`kubectl label node N os-upgrade-`) and follow the
   [runbook](runbook.md) from the predownload (`rollout.sh predownload`, then
   `rollout.sh upgrade`).

The new kernel is held and the previous one is purged.

## Undoing the pin (back to Ubuntu-managed kernels)

Only if you decide to stop pinning the kernel. On the node:

```sh
V=6.8.0-139-generic
sudo apt-mark unhold $(apt-mark showhold | grep -- "-$V\$")
sudo rm /etc/apt/preferences.d/99-os-upgrade-kernel /etc/default/grub.d/99-os-upgrade-kernel.cfg
sudo apt-get install linux-generic          # or the HWE one: linux-generic-hwe-<version>
sudo update-grub
# reboot when appropriate (with a drain)
```
