#!/bin/bash
set -euo pipefail
trap '' PIPE

# ---- Architecture detection ----
if [[ -z "${ARCH:-}" ]]; then
	case "$(uname -m)" in
		i?86) ARCH="" ;;
		aarch64) ARCH=aarch64 ;;
		arm*) ARCH=arm ;;
		*) ARCH=64 ;;
	esac
fi

case "${ARCH}" in
	aarch64)
		INITRD_PATH="installer/initrd-armv8.img"
		PKG_SUBDIR="slackware"
		MIRROR_SUBDIR="slackwarearm"
		DEFAULT_MIRROR="https://mirrors.aptalaska.net/slackware"
		;;
	*)
		INITRD_PATH="isolinux/initrd.img"
		PKG_SUBDIR="slackware${ARCH}"
		MIRROR_SUBDIR=""
		DEFAULT_MIRROR="https://mirrors.slackware.com/slackware"
		;;
esac

BUILD_NAME=${BUILD_NAME:-"slackware"}
VERSION=${VERSION:="current"}
RELEASENAME=${RELEASENAME:-"slackware${ARCH}"}
RELEASE=${RELEASE:-"${RELEASENAME}-${VERSION}"}
MIRROR=${MIRROR:-"${DEFAULT_MIRROR}"}
if [[ -n "${MIRROR_SUBDIR}" ]]; then
	MIRROR_URL="${MIRROR}/${MIRROR_SUBDIR}"
else
	MIRROR_URL="${MIRROR}"
fi
CACHEFS=${CACHEFS:-"/tmp/${BUILD_NAME}/${RELEASE}"}
ROOTFS=${ROOTFS:-"/tmp/rootfs-${RELEASE}"}
CWD="$(pwd)"

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
LOG_SEPARATOR() { echo "========================================================================" >&2; }
LOG_STEP() { echo ""; LOG_SEPARATOR; echo "  STEP: $1" >&2; LOG_SEPARATOR; echo ""; }

download_pkg() {
	local file="$1"
	local cache_path="${CACHEFS}/${file}"
	if [[ -f "${cache_path}" ]]; then
		echo "/cdrom/${file}"
		return 0
	fi
	mkdir -p "$(dirname "${cache_path}")"
	if curl -fsSL -o "${cache_path}" "${MIRROR_URL}/${RELEASE}/${file}" 2>/dev/null; then
		echo "/cdrom/${file}"
		return 0
	fi
	rm -f "${cache_path}"
	local dir_path pkg_prefix listing latest alt_file
	dir_path=$(dirname "${file}")
	pkg_prefix=$(basename "${file}" | sed 's/-[0-9].*//')
	listing=$(curl -fsSL "${MIRROR_URL}/${RELEASE}/${dir_path}/" 2>/dev/null) || return 1
	latest=$(echo "${listing}" | grep -oP "${pkg_prefix}-[^\"]+\.txz" | sort -V | tail -1) || true
	[[ -z "${latest}" ]] && return 1
	alt_file="${dir_path}/${latest}"
	if curl -fsSL -o "${CACHEFS}/${alt_file}" "${MIRROR_URL}/${RELEASE}/${alt_file}" 2>/dev/null; then
		echo "/cdrom/${alt_file}"
		return 0
	fi
	rm -f "${CACHEFS}/${alt_file}"
	return 1
}

fetch_package_paths() {
	local tmp_file tmp url file_size count
	tmp_file="$(mktemp)"
	url="${MIRROR_URL}/${RELEASE}/${PKG_SUBDIR}/FILE_LIST"
	echo "Fetching package list from ${url}" >&2
	if ! curl -fsSL "${url}" > "${tmp_file}"; then
		echo "ERROR: failed to fetch FILE_LIST from ${url}" >&2
		rm -f "${tmp_file}"
		return 1
	fi
	file_size=$(wc -c < "${tmp_file}")
	echo "Downloaded FILE_LIST (${file_size} bytes)" >&2
	if [[ "${file_size}" -eq 0 ]]; then
		echo "ERROR: FILE_LIST is empty" >&2
		rm -f "${tmp_file}"
		return 1
	fi
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

# ---- Chroot environment fix (解决 perl 库报错) ----
fix_chroot_env() {
	chroot . sh -c '
		set -e
		if [ -x /sbin/ldconfig ]; then /sbin/ldconfig || true; fi
		if [ -x /usr/sbin/ldconfig ]; then /usr/sbin/ldconfig || true; fi
		mkdir -p /lib /usr/lib /lib64 /usr/lib64
	' || true
}

# ---- Base package list ----
base_pkgs="a/aaa_base a/aaa_libraries a/coreutils a/aaa_glibc-solibs a/aaa_terminfo a/pkgtools a/shadow a/tar a/xz a/bash a/etc a/gzip l/pcre2 l/libpsl n/wget n/gnupg n/ca-certificates n/curl l/readline l/zlib ap/nano a/elvis ap/less ap/slackpkg l/ncurses a/bin a/bzip2 a/grep a/sed a/dialog a/file a/gawk a/time a/gettext a/libcgroup a/patch a/sysfsutils a/tree a/utempter a/which a/util-linux l/mpfr l/libunistring ap/diffutils a/procps n/net-tools a/findutils n/iproute2 n/openssl l/glibc-i18n a/glibc-zoneinfo n/rsync l/lz4 l/xxhash l/popt l/libgpg-error l/libgcrypt l/libassuan l/libksba l/libcom_err l/e2fsprogs-libs l/npth l/libssh2 l/nghttp2 l/brotli l/libidn2 l/zstd l/attr l/acl l/expat l/gdbm l/jsoncpp l/libarchive l/libcap l/libffi l/libmnl l/libuv l/lzo l/mpdecimal ap/db48 ap/pinentry ap/sqlite d/cmake d/perl d/python3 d/gcc d/gcc-g++ d/make d/binutils d/autoconf d/automake d/libtool d/pkg-config d/git l/libmpc l/gmp l/isl a/lzip a/infozip a/glibc d/kernel-headers"

# ---- Build ----
mkdir -p "$ROOTFS" "$CACHEFS"
LOG_STEP "Downloading initrd for ${ARCH} ${VERSION}"
download_pkg "${INITRD_PATH}"

cd "$ROOTFS"
LOG_STEP "Extracting initrd"
if file "${CACHEFS}/${INITRD_PATH}" | grep -wq XZ; then
	xzcat "${CACHEFS}/${INITRD_PATH}" | cpio -idm --null --no-absolute-filenames
else
	zcat "${CACHEFS}/${INITRD_PATH}" | cpio -idm --null --no-absolute-filenames
fi

# mount points
for dir in cdrom dev sys proc; do
	mkdir -p "$dir"
	mountpoint -q "$dir" || mount --bind "$CACHEFS" "$dir" 2>/dev/null || true
done
mount -t devtmpfs none dev
mount --bind -o ro /sys sys
mount --bind /proc proc
mkdir -p mnt/etc

# ---- Install packages sequentially ----
LOG_STEP "Installing base packages"
install_ok=0; install_fail=0; install_skip=0
for pkg in ${base_pkgs}; do
	cached_path="${CACHEFS}/${PKG_SUBDIR}/${pkg}.txz"
	if [[ -f "$cached_path" ]]; then
		echo "Installing $pkg..."
		chroot . /sbin/installpkg --root /mnt "$cached_path" || install_fail=$((install_fail+1))
		install_ok=$((install_ok+1))
	else
		echo "SKIP: $pkg not downloaded"
		install_skip=$((install_skip+1))
	fi
done

# Fix chroot environment before perl
LOG_STEP "Fixing chroot runtime environment"
fix_chroot_env

# Force ldconfig to refresh linker cache
chroot . /sbin/ldconfig || true

echo "Base package install summary:"
echo "  OK: $install_ok"
echo "  FAIL: $install_fail"
echo "  SKIP: $install_skip"
echo "  Total: $((install_ok + install_fail + install_skip)) / $(echo $base_pkgs | wc -w)"

# ---- CA certificates ----
LOG_STEP "Setting up CA certificates"
mkdir -p etc/ssl/certs
chroot . sh -c '
	set -e
	if command -v update-ca-certificates >/dev/null 2>&1; then
		update-ca-certificates --fresh || true
	fi
'

# Fallback: concat all .pem
if [[ ! -f etc/ssl/certs/ca-certificates.crt ]]; then
	find etc/ssl/certs -name "*.pem" -exec cat {} + > etc/ssl/certs/ca-certificates.crt 2>/dev/null || true
fi
cert_count=$(grep -c 'BEGIN CERTIFICATE' etc/ssl/certs/ca-certificates.crt 2>/dev/null || echo 0)
echo "CA bundle OK: $cert_count certificates in /etc/ssl/certs/ca-certificates.crt"

# Ensure wget uses CA bundle
mkdir -p etc
echo 'ca_certificate = /etc/ssl/certs/ca-certificates.crt' > etc/wgetrc

# ---- Clean up and package ----
rm -rf var/lib/slackpkg/* usr/share/locale/* usr/man/*
find usr/share/terminfo/ -type f ! -name 'linux' ! -name 'xterm' ! -name 'screen.linux' -delete

umount dev etc/resolv.conf || true

echo "Packaging ${CWD}/${RELEASE}.tar.gz ..."
tar --numeric-owner -czf "${CWD}/${RELEASE}.tar.gz" .
ls -sh "${CWD}/${RELEASE}.tar.gz"

LOG_STEP "Build complete"
echo "Architecture: ${ARCH}"
echo "Version: ${VERSION}"
echo "Release: ${RELEASE}"
echo "Mirror: ${MIRROR_URL}"
echo "Output: ${CWD}/${RELEASE}.tar.gz"
echo "Done."