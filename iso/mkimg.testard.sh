# shellcheck shell=sh disable=SC2034,SC2154,SC3043 # mkimage.sh reads and sets these variables
# Testard OS image profile for Alpine's mkimage.sh (aports/scripts).
# Built by iso/build.sh; see the README for how.

profile_testard() {
	profile_standard
	title="Testard OS"
	desc="A lean server OS for homelabs and VPSs, based on Alpine Linux."
	profile_abbrev="testard"
	image_ext="iso"
	arch="x86_64"
	output_format="iso"
	# Show the boot menu and a login prompt on the serial port too, for
	# headless machines and for testing in a virtual machine.
	kernel_cmdline="$kernel_cmdline console=tty0 console=ttyS0,115200"
	# The live system runs from RAM; let it use most of it (the graphical
	# installer needs room). tmpfs only takes what's actually written.
	kernel_cmdline="$kernel_cmdline rootflags=size=85%"
	syslinux_serial="0 115200"
	# On the image, so installing works without a network connection.
	apks="$apks nftables sudo curl ca-certificates tzdata openssh chrony
		docker docker-cli-compose avahi dbus
		e2fsprogs dosfstools sfdisk grub grub-efi efibootmgr syslinux
		eudev udev-init-scripts udev-init-scripts-openrc
		busybox-extras cage firefox-esr seatd seatd-launch mesa-dri-gallium
		xkeyboard-config font-dejavu"
	# Relative to the repository root, where iso/build.sh runs mkimage.
	apkovl="iso/genapkovl-testard.sh"
	hostname="testard"
}

# Boot straight into Testard OS: no boot prompt, no menu to wait for.
syslinux_gen_config() {
	[ -z "$syslinux_serial" ] || echo "SERIAL $syslinux_serial"
	echo "TIMEOUT 0"
	echo "PROMPT 0"
	echo "DEFAULT testard"
	local _f="${kernel_flavors%% *}"
	cat <<- EOF

	LABEL testard
		MENU LABEL Testard OS
		KERNEL /boot/vmlinuz-$_f
		INITRD /boot/initramfs-$_f
		APPEND $initfs_cmdline $kernel_cmdline
	EOF
}

grub_gen_config() {
	local _f="${kernel_flavors%% *}"
	echo "set timeout=0"
	cat <<- EOF

	menuentry "Testard OS" {
		linux	/boot/vmlinuz-$_f $initfs_cmdline $kernel_cmdline
		initrd	/boot/initramfs-$_f
	}
	EOF
}
