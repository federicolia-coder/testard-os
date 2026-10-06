#!/bin/sh
# Builds the Testard OS ISO with Alpine's mkimage.sh. Run it inside Alpine
# (CI uses the alpine container), as root, from the repository root:
#
#   docker run --rm -v "$PWD":/src -w /src alpine:3.22 sh iso/build.sh
#
# The ISO lands in out/.

set -eu

ALPINE="${ALPINE:-3.22}"
ARCH="${ARCH:-$(apk --print-arch)}"
VERSION="${VERSION:-$(sed -n 's/^VERSION="\(.*\)"$/\1/p' setup.sh)}"
MIRROR="https://dl-cdn.alpinelinux.org/alpine"

apk add --no-cache alpine-sdk alpine-conf syslinux xorriso squashfs-tools \
	grub grub-efi mtools dosfstools git fakeroot

# mkimage signs the image's package index with an abuild key.
# (-i would install it with doas; as root we copy it ourselves.)
if ! ls ~/.abuild/*.rsa >/dev/null 2>&1; then
	abuild-keygen -a -n
	cp ~/.abuild/*.rsa.pub /etc/apk/keys/
fi

# Only the scripts/ folder of aports is needed. GitLab turns away CI
# machines, so the official GitHub mirror comes first.
if [ ! -d /tmp/aports ]; then
	for url in https://github.com/alpinelinux/aports.git https://gitlab.alpinelinux.org/alpine/aports.git; do
		rm -rf /tmp/aports
		git clone --depth 1 --filter=blob:none --sparse --branch "$ALPINE-stable" "$url" /tmp/aports \
			&& git -C /tmp/aports sparse-checkout set scripts && break
	done
	[ -f /tmp/aports/scripts/mkimage.sh ] || { echo "couldn't download aports" >&2; exit 1; }
fi

mkdir -p ~/.mkimage out
cp iso/mkimg.testard.sh iso/genapkovl-testard.sh ~/.mkimage/
chmod +x ~/.mkimage/genapkovl-testard.sh

export TESTARD_OS_DIR="$PWD"
sh /tmp/aports/scripts/mkimage.sh \
	--tag "$VERSION" \
	--outdir "$PWD/out" \
	--arch "$ARCH" \
	--repository "$MIRROR/v$ALPINE/main" \
	--extra-repository "$MIRROR/v$ALPINE/community" \
	--profile testard

iso=$(find out -maxdepth 1 -name "*.iso" | head -n 1)
final="out/testard-os-$VERSION-$ARCH.iso"
mv "$iso" "$final"
sha256sum "$final" | sed 's#out/##' > "$final.sha256"
ls -lh out/
