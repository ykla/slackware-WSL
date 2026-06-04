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

# Download a single file, with fallback to directory listing for latest version
# Outputs the resolved cdrom path to stdout on success
download_pkg() {
	local file="$1"
	local cache_path="${CACHEFS}/${file}"

	# Already cached
	if [[ -f "${cache_path}" ]]; then
		echo "/cdrom/${file}"
		return 0
	fi

	mkdir -p "$(dirname "${cache_path}")"

	# Try exact URL first
	if curl -fsSL -o "${cache_path}" "${MIRROR}/${RELEASE}/${file}" 2>/dev/null; then
		echo "/cdrom/${file}"
		return 0
	fi
	rm -f "${cache_path}"

	# Fallback: scan directory listing for latest version
	local dir_path
	dir_path=$(dirname "${file}")
	local pkg_prefix
	pkg_prefix=$(basename "${file}" | sed 's/-[0-9].*//')

	local listing
	listing=$(curl -fsSL "${MIRROR}/${RELEASE}/${dir_path}/" 2>/dev/null) || return 1

	local latest
	latest=$(echo "${listing}" | grep -oP "${pkg_prefix}-[^\"]+\.txz" | sort -V | tail -1) || true
	[[ -z "${latest}" ]] && return 1

	local alt_file="${dir_path}/${latest}"
	if curl -fsSL -o "${CACHEFS}/${alt_file}" "${MIRROR}/${RELEASE}/${alt_file}" 2>/dev/null; then
		echo "/cdrom/${alt_file}"
		return 0
	fi
	rm -f "${CACHEFS}/${alt_file}"
	return 1
}

# Fetch FILE_LIST from the mirror and extract package paths
fetch_package_paths() {
	local tmp_file
	tmp_file="$(mktemp)"
	local url="${MIRROR}/${RELEASE}/${relbase}/FILE_LIST"
	echo "Fetching package list from ${url}" >&2
	if ! curl -fsSL "${url}" > "${tmp_file}"; then
		echo "ERROR: failed to fetch FILE_LIST from ${url}" >&2
		rm -f "${tmp_file}"
		return 1
	fi
	local file_size
	file_size=$(wc -c < "${tmp_file}")
	echo "Downloaded FILE_LIST (${file_size} bytes)" >&2
	if [[ "${file_size}" -eq 0 ]]; then
		echo "ERROR: FILE_LIST is empty" >&2
		rm -f "${tmp_file}"
		return 1
	fi
	local count
	count=$(grep -c '\.t.z$' "${tmp_file}") || count=0
	echo "Found ${count} packages in FILE_LIST" >&2
	if [[ "${count}" -eq 0 ]]; then
		echo "ERROR: no packages found in FILE_LIST" >&2
		head -20 "${tmp_file}" >&2
		rm -f "${tmp_file}"
		return 1
	fi
	grep '\.t.z$' "${tmp_file}" | awk '{ print $8 }' | sed 's|^\./||' || true
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

download_pkg "isolinux/initrd.img"

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

# determine install command and flags
# We are doing fresh installs into /mnt, so installpkg is preferred.
# upgradepkg does not support --root and is for upgrading existing packages.
install_cmd=""
install_args=""
if [[ -f ./sbin/installpkg ]]; then
	install_cmd="./sbin/installpkg"
	grep -qw terse ./sbin/installpkg && install_args="--terse"
elif [[ -f ./usr/lib/setup/installpkg ]]; then
	install_cmd="./usr/lib/setup/installpkg"
	grep -qw terse ./usr/lib/setup/installpkg && install_args="--terse"
elif [[ -f ./sbin/upgradepkg ]]; then
	install_cmd="./sbin/upgradepkg"
	grep -qw terse ./sbin/upgradepkg && install_args="--terse"
fi
echo "Using install command: ${install_cmd} ${install_args}" >&2

# Fetch package paths from mirror
paths_file="${CACHEFS}/paths"
if [[ ! -f "${paths_file}" ]]; then
	fetch_package_paths > "${paths_file}"
fi
paths_count=$(wc -l < "${paths_file}")
echo "Package paths cached: ${paths_count} entries" >&2
if [[ "${paths_count}" -eq 0 ]]; then
	echo "ERROR: no package paths available, aborting" >&2
	exit 1
fi

# Resolve package paths and download in parallel
# Step 1: resolve all paths from FILE_LIST into a download manifest
manifest_file="${CACHEFS}/manifest"
if [[ ! -f "${manifest_file}" ]]; then
	for pkg in ${base_pkgs}; do
		path=$(grep "^${pkg}.*\.t.z$" "${paths_file}" | head -1) || true
		if [[ -n "${path}" ]]; then
			echo "${relbase}/${path}"
		else
			echo "SKIP: ${pkg} not found in package list" >&2
		fi
	done > "${manifest_file}"
fi
manifest_count=$(wc -l < "${manifest_file}")
echo "Manifest: ${manifest_count} packages to download" >&2

# Step 2: parallel download using xargs
echo "Downloading ${manifest_count} packages in parallel..." >&2
cat "${manifest_file}" | xargs -P 8 -I{} bash -c '
	file="{}"
	cache_path="'"${CACHEFS}"'/${file}"
	if [[ -f "${cache_path}" ]]; then exit 0; fi
	mkdir -p "$(dirname "${cache_path}")"
	if curl -fsSL -o "${cache_path}" "'"${MIRROR}/${RELEASE}"'/${file}" 2>/dev/null; then
		echo "  OK: ${file}" >&2
		exit 0
	fi
	rm -f "${cache_path}"
	# Fallback: scan directory for latest version
	dir_path=$(dirname "${file}")
	pkg_prefix=$(basename "${file}" | sed "s/-[0-9].*//")
	listing=$(curl -fsSL "'"${MIRROR}/${RELEASE}"'/${dir_path}/" 2>/dev/null) || exit 1
	latest=$(echo "${listing}" | grep -oP "${pkg_prefix}-[^\"]+\.txz" | sort -V | tail -1) || true
	if [[ -z "${latest}" ]]; then
		echo "  FAIL: ${file} not found" >&2
		exit 1
	fi
	alt_file="${dir_path}/${latest}"
	if curl -fsSL -o "'"${CACHEFS}"'/${alt_file}" "'"${MIRROR}/${RELEASE}"'/${alt_file}" 2>/dev/null; then
		echo "  OK (fallback): ${alt_file}" >&2
		exit 0
	fi
	echo "  FAIL: ${alt_file}" >&2
	rm -f "'"${CACHEFS}"'/${alt_file}"
	exit 1
' || true

# Step 3: install packages sequentially
for pkg in ${base_pkgs}; do
	path=$(grep "^${pkg}.*\.t.z$" "${paths_file}" | head -1) || true
	if [[ -z "${path}" ]]; then
		echo "SKIP: ${pkg} not found in package list" >&2
		continue
	fi

	# Check if file was downloaded (exact or fallback)
	cached_path="${CACHEFS}/${relbase}/${path}"
	if [[ ! -f "${cached_path}" ]]; then
		# Check for fallback version
		dir_path=$(dirname "${relbase}/${path}")
		pkg_prefix=$(basename "${path}" | sed 's/-[0-9].*//')
		latest=$(ls "${CACHEFS}/${dir_path}/${pkg_prefix}"-*.txz 2>/dev/null | sort -V | tail -1) || true
		if [[ -n "${latest}" ]]; then
			l_pkg="/cdrom/${latest#${CACHEFS}/}"
		else
			echo "SKIP: ${pkg} not downloaded, will be installed by slackpkg later" >&2
			continue
		fi
	else
		l_pkg="/cdrom/${relbase}/${path}"
	fi

	echo "Installing ${pkg}..." >&2
	if ! PATH=/bin:/sbin:/usr/bin:/usr/sbin chroot . ${install_cmd} --root /mnt ${install_args} "${l_pkg}"; then
		echo "WARN: ${pkg} install failed, will be retried by slackpkg" >&2
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

# Copy host CA certificates so wget can verify HTTPS in chroot
if [[ -d /etc/ssl/certs ]]; then
	mkdir -p etc/ssl/certs
	cp -a /etc/ssl/certs/* etc/ssl/certs/ 2>/dev/null || true
	if [[ -f /etc/ssl/cert.pem ]]; then
		cp -a /etc/ssl/cert.pem etc/ssl/cert.pem
	fi
fi
if [[ -d /etc/pki/tls ]]; then
	mkdir -p etc/pki/tls
	cp -a /etc/pki/tls/* etc/pki/tls/ 2>/dev/null || true
fi

mount --bind /etc/resolv.conf etc/resolv.conf

# Import GPG key before update
echo 'Importing GPG key ...'
chroot . sh -c 'echo Y | /usr/sbin/slackpkg update gpg' || true

echo 'slackpkg update ...'
chroot . sh -c '/usr/sbin/slackpkg -batch=on -default_answer=y update'

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