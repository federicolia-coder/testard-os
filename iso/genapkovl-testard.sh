#!/bin/sh -e
# Builds the overlay of the Testard OS live system: what /etc looks like when
# the USB stick boots. mkimage.sh runs it as: genapkovl-testard.sh <hostname>
# TESTARD_OS_DIR points at this repository (set by iso/build.sh).

HOSTNAME="$1"
[ -n "$HOSTNAME" ] || { echo "usage: $0 hostname" >&2; exit 1; }
SRC="${TESTARD_OS_DIR:?set TESTARD_OS_DIR to the testard-os repository}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

makefile() { # makefile OWNER PERMS FILE < content
	cat > "$3"
	chown "$1" "$3"
	chmod "$2" "$3"
}

rc_add() { # rc_add SERVICE RUNLEVEL
	mkdir -p "$tmp/etc/runlevels/$2"
	ln -sf "/etc/init.d/$1" "$tmp/etc/runlevels/$2/$1"
}

mkdir -p "$tmp/etc/network" "$tmp/etc/apk" "$tmp/etc/profile.d" "$tmp/etc/testard"

makefile root:root 0644 "$tmp/etc/hostname" <<EOF
$HOSTNAME
EOF

# Wired network by DHCP, so the installer can fetch SSH keys from GitHub.
makefile root:root 0644 "$tmp/etc/network/interfaces" <<EOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

# Installed when the live system boots, from the packages on the USB stick.
makefile root:root 0644 "$tmp/etc/apk/world" <<EOF
alpine-base
curl
ca-certificates
tzdata
EOF

makefile root:root 0644 "$tmp/etc/issue" <<'EOF'

Testard OS (Alpine Linux) \r on \m (\l)
Log in as root (no password), then type: testard-install

EOF

# On the screen (tty1) the live system logs in by itself, so the first thing
# you see is how to start the installer. testard-install puts the normal
# login back before copying /etc to the disk.
makefile root:root 0755 "$tmp/etc/testard/live-login" <<'EOF'
#!/bin/sh
exec /bin/login -f root
EOF
makefile root:root 0644 "$tmp/etc/inittab" <<'EOF'
# /etc/inittab (Testard OS live system)

::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default

tty1::respawn:/sbin/getty -n -l /etc/testard/live-login 38400 tty1
tty2::respawn:/sbin/getty 38400 tty2
tty3::respawn:/sbin/getty 38400 tty3

# Put a getty on the serial port
#ttyS0::respawn:/sbin/getty -L 115200 ttyS0 vt100

::ctrlaltdel:/sbin/reboot
::shutdown:/sbin/openrc shutdown
EOF

esc=$(printf '\033')
makefile root:root 0644 "$tmp/etc/motd" <<EOF

  ${esc}[1mtestard${esc}[1;34m.${esc}[0m ${esc}[1;32mOS${esc}[0m

  Welcome to Testard OS, a lean server OS based on Alpine Linux.

  To install it on this machine's disk, type:  ${esc}[1mtestard-install${esc}[0m and press Enter.

EOF

# The installer and the setup script live in /etc/testard, so the installer
# can copy them to the new system along with the rest of /etc.
makefile root:root 0755 "$tmp/etc/testard/testard-install" < "$SRC/iso/testard-install"
makefile root:root 0755 "$tmp/etc/testard/testard-setup" < "$SRC/setup.sh"
makefile root:root 0644 "$tmp/etc/profile.d/testard-live.sh" <<'EOF'
# Testard OS live system: make the installer a plain command.
case ":$PATH:" in *:/etc/testard:*) ;; *) PATH="$PATH:/etc/testard" ;; esac
alias testard-install='/etc/testard/testard-install'
EOF

rc_add devfs sysinit
rc_add dmesg sysinit
rc_add mdev sysinit
rc_add hwdrivers sysinit
rc_add modloop sysinit

rc_add hwclock boot
rc_add modules boot
rc_add sysctl boot
rc_add hostname boot
rc_add bootmisc boot
rc_add syslog boot
rc_add networking boot

rc_add mount-ro shutdown
rc_add killprocs shutdown
rc_add savecache shutdown

tar -c -C "$tmp" etc | gzip -9n > "$HOSTNAME.apkovl.tar.gz"
