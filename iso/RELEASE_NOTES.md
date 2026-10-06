Write the ISO to a USB stick (balenaEtcher, Rufus in "DD image" mode, or `dd`) and boot from it: the installer opens on the screen. Pick Homelab or Server, answer a few questions and choose the disk.

If the screen can't show the graphical installer, log in as `root` (no password on the live system) and type `testard-install`.

Needs a 64-bit PC with 2 GB of memory. Check the download first: `sha256sum -c testard-os-*.iso.sha256`.
