# shellcheck shell=sh disable=SC2034 # mkimage.sh reads these variables
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
	syslinux_serial="0 115200"
	# On the image, so installing works without a network connection.
	apks="$apks nftables sudo curl ca-certificates tzdata openssh chrony
		docker docker-cli-compose
		e2fsprogs dosfstools sfdisk grub grub-efi efibootmgr syslinux"
	apkovl="genapkovl-testard.sh"
	hostname="testard"
}
