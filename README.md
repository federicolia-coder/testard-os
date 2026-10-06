<p>
  <a href="https://platform.testardstudios.it">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="assets/testard-os-logo-on-dark.svg">
      <img src="assets/testard-os-logo.svg" alt="testard. OS" width="300">
    </picture>
  </a>
</p>

# Testard OS

A lean server operating system for your homelab or a VPS, based on [Alpine Linux](https://alpinelinux.org). Put it on a USB stick, install it on any PC, and you get a server that uses about 85 MB of memory with Docker running: keys-only SSH, a firewall, daily security updates and a status screen at login, ready from the first boot.

## Install from a USB stick

1. Download `testard-os-<version>-x86_64.iso` from [Releases](https://github.com/federicolia-coder/testard-os/releases/latest).
2. Write it to a USB stick (all data on the stick is erased) with [balenaEtcher](https://etcher.balena.io), or Rufus in "DD image" mode, or on Linux and macOS: `sudo dd if=testard-os-*.iso of=/dev/sdX bs=4M`.
3. Boot the PC from the stick. The installer opens on the screen by itself.
4. Pick how you'll use it, **Homelab** or **Server**, then answer a few questions: server name, time zone, your user and password, SSH keys (pasted or from your GitHub account), Docker, ports and, if you want, your Testard agent key. Then pick the disk; everything on it is erased.
5. Remove the stick and restart. The first boot finishes the setup in about a minute; log in with your user.

| | Homelab | Server |
| --- | --- | --- |
| Who can connect | Only devices on your network (and Tailscale) | Anyone, on the ports you open |
| Name | Answers as `name.local` | Just its IP or your DNS |
| Docker | On by default | Off by default |

Needs a 64-bit PC (x86_64) with BIOS or UEFI, 2 GB of memory for the installer and a wired network. If the screen can't show the graphical installer, a text one takes over: log in as `root` (no password) and type `testard-install`. Every build is installed twice in a virtual machine by [CI](.github/workflows/iso.yml), once with each installer, before it's published.

## Or set up an existing server

Already have Alpine, Debian or Ubuntu running, for example on a VPS? The same setup runs as a script:

```sh
curl -fsSL https://raw.githubusercontent.com/federicolia-coder/testard-os/main/setup.sh -o setup.sh
less setup.sh      # read it first: it's plain shell, top to bottom
sudo sh setup.sh
```

It asks a few questions, shows what it's about to change, and waits for a yes.

## What it sets up

| | |
| --- | --- |
| **Admin user** | A user with sudo, with SSH keys pasted in or taken from `github.com/<you>.keys`. |
| **SSH** | Keys only, no passwords, no root login. Applied only if a key is in place, so you can't lock yourself out, and only after `sshd -t` accepts it. |
| **Firewall** | nftables: incoming connections are dropped except SSH and the ports you list. It lives in its own table, so it doesn't touch rules from Docker or anything else. If `ufw` or `firewalld` is already on, it's left to them. |
| **Security updates** | Installed automatically every day: `unattended-upgrades` on Debian and Ubuntu, a daily `apk upgrade` on Alpine. It never reboots on its own; the login screen tells you when a reboot is needed. |
| **Containers** | Docker with compose, or Podman, from your distribution's own packages. Optional. |
| **Lighter defaults** | System logs capped at 100 MB; on Debian and Ubuntu, apt stops installing "recommended" extras. |
| **Login screen** | IP, uptime, memory, disk, running containers and whether a reboot is needed. |
| **Testard** | Optional: installs the open-source [Testard agent](https://github.com/federicolia-coder/testard-agent), so the server shows up in [Testard](https://platform.testardstudios.it) next to your other servers and cloud accounts. |

## Which base to pick (for the script)

- **Alpine**: the lightest. About 50 MB of memory in use at idle and under 200 MB on disk. Best for small VPSs, old PCs and Raspberry Pis. Software built for Debian or Ubuntu may not run directly; inside Docker it does.
- **Debian**: a little heavier (about 100 to 150 MB at idle), with the widest software support. The safe choice if you're unsure.
- **Ubuntu Server**: like Debian, and what many VPS providers install by default.

The script supports Alpine 3.20 and later, Debian 12 and 13, Ubuntu 22.04 and 24.04.

## Without questions

Pass the options to skip the questions, and `--yes` to skip the final confirmation as well, e.g. from cloud-init or a provisioning script:

```sh
sudo sh setup.sh --yes \
  --hostname homelab-1 \
  --user mario --github mario-rossi \
  --containers docker \
  --open 80,443,51820/udp \
  --agent-key tsk_...
```

`sudo sh setup.sh --help` lists every option. You can also leave out a step with `--no-firewall`, `--no-ssh-hardening` or `--no-auto-updates`.

## Running it again

The script installs itself as `testard-setup` and remembers your choices in `/etc/testard/setup.conf`, so running it again only changes what you ask for:

```sh
sudo testard-setup --open 80,443,8123     # change the open ports
sudo testard-setup --agent-key tsk_...    # connect the server to Testard
```

`--open` replaces the list from the last run (`--open none` closes them all except SSH). Everything it does is logged to `/var/log/testard-setup.log`.

## Good to know

- **Ports published by Docker** (`-p 8080:80`) are reachable even if they aren't in `--open`, because Docker adds its own forwarding rules. To keep a container private, publish it on localhost only: `-p 127.0.0.1:8080:80`.
- **Sudo password**: if the admin user has no password, you're asked to set one. When run with `--yes` instead, that user can use sudo without a password, and the summary tells you how to change that.
- **Before closing your session**, check that you can log in from another terminal with the command shown at the end.

## Undoing it

Every file it writes starts with `Written by testard-setup`:

| To undo | Remove |
| --- | --- |
| SSH settings | `/etc/ssh/sshd_config.d/01-testard.conf`, then restart SSH |
| Firewall | `systemctl disable --now testard-firewall` (or `rc-update del testard-firewall boot` on Alpine), then `/etc/testard/firewall.nft` |
| Automatic updates | `/etc/apt/apt.conf.d/20auto-upgrades` or `/etc/periodic/daily/testard-updates` |
| Lighter defaults | `/etc/apt/apt.conf.d/90testard-lean`, `/etc/systemd/journald.conf.d/10-testard.conf` |
| Login screen | `/etc/profile.d/testard-motd.sh` |
| Testard agent | `sudo testard-agent uninstall` |

## Building the ISO

`iso/build.sh` builds it with Alpine's `mkimage` inside an Alpine container: `docker run --rm -v "$PWD":/src -w /src alpine:3.22 sh iso/build.sh`. `iso/test/install-test.py` installs the result in QEMU and checks it.

## Coming next

Raspberry Pi images, and Wi-Fi during installation.

## License

Apache 2.0. Made by [Testard Studios](https://platform.testardstudios.it).
