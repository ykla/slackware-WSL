#!/bin/bash
set -euo pipefail
# Generate a very minimal filesystem from slackware

# ---- Architecture detection ----
if [[ -z "${ARCH:-}" ]]; then
	case "$(uname -m)" in
		i?86) ARCH="" ;;
		arm*) ARCH=arm ;;
		   *) ARCH=64 ;;
	esac
fi

# ---- Configuration ----
BUILD_NAME=${BUILD_NAME:-"slackware"}
VERSION=${VERSION:="current"}
RELEASENAME=${RELEASENAME:-"slackware${ARCH}"}
RELEASE=${RELEASE:-"${RELEASENAME}-${VERSION}"}
relbase="${RELEASE%%-*}"
MIRROR=${MIRROR:-"https://mirrors.slackware.com/slackware"}
CACHEFS=${CACHEFS:-"/tmp/${BUILD_NAME}/${RELEASE}"}
ROOTFS=${ROOTFS:-"/tmp/rootfs-${RELEASE}"}
CWD="$(pwd)"

# ---- Cleanup trap ----
cleanup() {
	local dir
	echo "Cleaning up mounts..." >&2
	for dir in cdrom dev sys proc; do
		mountpoint -q "${ROOTFS}/${dir}" 2>/dev/null && umount "${ROOTFS}/${dir}" 2>/dev/null || true
	done
	mountpoint -q "${ROOTFS}/mnt/etc/resolv.conf" 2>/dev/null && umount "${ROOTFS}/mnt/etc/resolv.conf" 2>/dev/null || true
}
trap cleanup EXIT

# ---- Functions ----

# Download a file from the mirror and return its cdrom path
cacheit() {
	local file="$1"
	if [[ ! -f "${CACHEFS}/${file}" ]]; then
		mkdir -p "$(dirname "${CACHEFS}/${file}")"
		echo "Fetching ${MIRROR}/${RELEASE}/${file}" >&2
		curl -fsSL -o "${CACHEFS}/${file}" "${MIRROR}/${RELEASE}/${file}"
	fi
	echo "/cdrom/${file}"
}

# Fetch FILE_LIST from the mirror and extract package paths
fetch_package_paths() {
	local tmp_file
	tmp_file="$(mktemp)"
	local url="${MIRROR}/${RELEASE}/${relbase}/FILE_LIST"
	echo "Fetching package list from ${url}" >&2
	if ! curl -fsSL "${url}" > "${tmp_file}"; then
		echo "ERROR: failed to fetch FILE_LIST" >&2
		rm -f "${tmp_file}"
		return 1
	fi
	grep '\.t\.z$' "${tmp_file}" | awk '{ print $8 }' | sed 's|^\./||'
	rm -f "${tmp_file}"
}

# ---- Base package list ----
base_pkgs="a/aaa_base \
	a/aaa_libraries \
	a/coreutils \
	a/aaa_glibc-solibs \
	a/aaa_terminfo \
	a/pkgtools \
	a/shadow \
	a/tar \
	a/xz \
	a/bash \
	a/etc \
	a/gzip \
	l/pcre2 \
	l/libpsl \
	n/wget \
	n/gnupg \
	a/elvis \
	ap/slackpkg \
	l/ncurses \
	a/bin \
	a/bzip2 \
	a/grep \
	a/sed \
	a/dialog \
	a/file \
	a/gawk \
	a/time \
	a/gettext \
	a/libcgroup \
	a/patch \
	a/sysfsutils \
	a/tree \
	a/utempter \
	a/which \
	a/util-linux \
	l/mpfr \
	l/libunistring \
	ap/diffutils \
	a/procps \
	n/net-tools \
	a/findutils \
	n/iproute2 \
	n/openssl"

# ---- Build ----
mkdir -p "$ROOTFS" "$CACHEFS"

cacheit "isolinux/initrd.img"

cd "$ROOTFS"

# extract the initrd to the current rootfs
if file "${CACHEFS}/isolinux/initrd.img" | grep -wq XZ; then
	xzcat "${CACHEFS}/isolinux/initrd.img" | cpio -idm --null --no-absolute-filenames
else
	zcat "${CACHEFS}/isolinux/initrd.img" | cpio -idm --null --no-absolute-filenames
fi

if stat -c %F "$ROOTFS/cdrom" | grep -q "symbolic link"; then
	rm -f "$ROOTFS/cdrom"
fi
mkdir -p mnt cdrom dev proc sys

for dir in cdrom dev sys proc; do
	if mountpoint -q "$ROOTFS/$dir" 2>/dev/null; then
		umount "$ROOTFS/$dir"
	fi
done

mount --bind "$CACHEFS" "${ROOTFS}/cdrom"
mount -t devtmpfs none "${ROOTFS}/dev"
mount --bind -o ro /sys "${ROOTFS}/sys"
mount --bind /proc "${ROOTFS}/proc"

mkdir -p mnt/etc
cp etc/ld.so.conf mnt/etc

# determine install flags based on available pkgtools version
install_args=""
if [[ -f ./sbin/upgradepkg ]] && grep -qw terse ./sbin/upgradepkg; then
	install_args="--install-new --reinstall --terse"
elif [[ -f ./sbin/installpkg ]] && grep -qw terse ./sbin/installpkg; then
	install_args="--terse"
elif [[ -f ./usr/lib/setup/installpkg ]] && grep -qw terse ./usr/lib/setup/installpkg; then
	install_args="--terse"
fi

# Fetch package paths from mirror
paths_file="${CACHEFS}/paths"
if [[ ! -f "${paths_file}" ]]; then
	fetch_package_paths > "${paths_file}"
fi

# Install base packages
for pkg in ${base_pkgs}; do
	path=$(grep "^${pkg}.*\.t.z$" "${paths_file}" | head -1) || true
	if [[ -z "${path}" ]]; then
		echo "SKIP: ${pkg} not found in package list" >&2
		continue
	fi

	l_pkg=$(cacheit "${relbase}/${path}")
	echo "Installing ${pkg}..." >&2
	if [[ -e ./sbin/upgradepkg ]]; then
		PATH=/bin:/sbin:/usr/bin:/usr/sbin chroot . /sbin/upgradepkg --root /mnt ${install_args} "${l_pkg}"
	elif [[ -e ./sbin/installpkg ]]; then
		PATH=/bin:/sbin:/usr/bin:/usr/sbin chroot . /sbin/installpkg --root /mnt ${install_args} "${l_pkg}"
	else
		PATH=/bin:/sbin:/usr/bin:/usr/sbin chroot . /usr/lib/setup/installpkg --root /mnt ${install_args} "${l_pkg}"
	fi
done

# ---- System Configuration ----
cd mnt

touch etc/resolv.conf
echo 'export TERM=linux' >> etc/profile.d/term.sh
chmod +x etc/profile.d/term.sh
echo '. /etc/profile' > .bashrc
echo "${MIRROR}/${RELEASE}/" >> etc/slackpkg/mirrors
sed -i \
	-e 's/DIALOG=on/DIALOG=off/' \
	-e 's/POSTINST=on/POSTINST=off/' \
	-e 's/SPINNING=on/SPINNING=off/' \
	etc/slackpkg/slackpkg.conf

mount --bind /etc/resolv.conf etc/resolv.conf

echo 'slackpkg update ...'
chroot . sh -c 'yes y | /usr/sbin/slackpkg -batch=on -default_answer=y update'

echo 'slackpkg upgrade-all ...'
chroot . sh -c '/usr/sbin/slackpkg -batch=on -default_answer=y upgrade-all'

# ---- Cleanup ----
rm -rf var/lib/slackpkg/*
rm -rf usr/share/locale/*
rm -rf usr/man/*
find usr/share/terminfo/ -type f \
	! -name 'linux' \
	! -name 'xterm' \
	! -name 'screen.linux' \
	-delete

umount "$ROOTFS/dev"
rm -f dev/* # containers should expect the kernel API (`mount -t devtmpfs none /dev`)
umount etc/resolv.conf

echo "Packaging ${CWD}/${RELEASE}.tar.gz ..."
tar --numeric-owner -czf "${CWD}/${RELEASE}.tar.gz" .
ls -sh "${CWD}/${RELEASE}.tar.gz"

echo "Done."