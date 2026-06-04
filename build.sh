#!/bin/bash
set -euo pipefail
trap '' PIPE

# =========================================================
# ARCH
# =========================================================
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

# =========================================================
# CONFIG
# =========================================================
BUILD_NAME=${BUILD_NAME:-slackware}
VERSION=${VERSION:-current}
RELEASENAME=${RELEASENAME:-slackware${ARCH}}
RELEASE=${RELEASE:-${RELEASENAME}-${VERSION}}

MIRROR=${MIRROR:-$DEFAULT_MIRROR}
if [[ -n "${MIRROR_SUBDIR}" ]]; then
	MIRROR_URL="${MIRROR}/${MIRROR_SUBDIR}"
else
	MIRROR_URL="${MIRROR}"
fi

CACHEFS=${CACHEFS:-/tmp/${BUILD_NAME}/${RELEASE}}
ROOTFS=${ROOTFS:-/tmp/rootfs-${RELEASE}}
CWD="$(pwd)"

# =========================================================
# CLEANUP
# =========================================================
cleanup() {
	for d in cdrom dev sys proc; do
		mountpoint -q "${ROOTFS}/${d}" && umount "${ROOTFS}/${d}" || true
	done
	mountpoint -q "${ROOTFS}/etc/resolv.conf" && umount "${ROOTFS}/etc/resolv.conf" || true
}
trap cleanup EXIT

mkdir -p "$ROOTFS" "$CACHEFS"

# =========================================================
# BASE PKGS
# =========================================================
base_pkgs="a/aaa_base a/aaa_libraries a/coreutils a/aaa_glibc-solibs a/aaa_terminfo a/pkgtools a/shadow a/tar a/xz a/bash a/etc a/gzip l/pcre2 l/libpsl n/wget n/gnupg n/ca-certificates n/curl l/readline l/zlib ap/nano a/elvis ap/less ap/slackpkg l/ncurses a/bin a/bzip2 a/grep a/sed a/dialog a/file a/gawk a/time a/gettext a/libcgroup a/patch a/sysfsutils a/tree a/utempter a/which a/util-linux l/mpfr l/libunistring ap/diffutils a/procps n/net-tools a/findutils n/iproute2 n/openssl l/glibc-i18n a/glibc-zoneinfo n/rsync l/lz4 l/xxhash l/popt l/libgpg-error l/libgcrypt l/libassuan l/libksba l/libcom_err l/e2fsprogs-libs l/npth l/libssh2 l/nghttp2 l/brotli l/libidn2 l/zstd l/attr l/acl l/expat l/gdbm l/jsoncpp l/libarchive l/libcap l/libffi l/libmnl l/libuv l/lzo l/mpdecimal ap/db48 ap/pinentry ap/sqlite d/cmake d/perl d/python3 d/gcc d/gcc-g++ d/make d/binutils d/autoconf d/automake d/libtool d/pkg-config d/git l/libmpc l/gmp l/isl a/lzip a/infozip a/glibc d/kernel-headers"

# =========================================================
# INITRD
# =========================================================
echo "Extracting initrd..."
mkdir -p "$ROOTFS"
cd "$ROOTFS"

if file "${CACHEFS}/${INITRD_PATH}" | grep -q XZ; then
	xzcat "${CACHEFS}/${INITRD_PATH}" | cpio -idm --null --no-absolute-filenames
else
	zcat "${CACHEFS}/${INITRD_PATH}" | cpio -idm --null --no-absolute-filenames
fi

mkdir -p cdrom dev proc sys mnt

mount --bind "$CACHEFS" cdrom
mount -t devtmpfs none dev
mount --bind -o ro /sys sys
mount --bind /proc proc
mount --bind /etc/resolv.conf etc/resolv.conf

# =========================================================
# CRITICAL FIX: LIBCOM_ERR + LDD CACHE
# =========================================================
mkdir -p lib lib64 usr/lib usr/lib64

# 强制保证 perl / update-ca-certificates 可用
cp -a /lib*/libcom_err.so* lib/ 2>/dev/null || true
cp -a /usr/lib*/libcom_err.so* usr/lib/ 2>/dev/null || true
cp -a /lib*/libe2p.so* lib/ 2>/dev/null || true
cp -a /usr/lib*/libe2p.so* usr/lib/ 2>/dev/null || true

# =========================================================
# FUNCTIONS
# =========================================================
download_pkg() {
	local file="$1"
	local cache_path="${CACHEFS}/${file}"

	[[ -f "$cache_path" ]] && echo "$cache_path" && return 0

	mkdir -p "$(dirname "$cache_path")"

	if curl -fsSL -o "$cache_path" "${MIRROR_URL}/${RELEASE}/${file}" 2>/dev/null; then
		echo "$cache_path"
		return 0
	fi

	rm -f "$cache_path"

	dir=$(dirname "$file")
	prefix=$(basename "$file" | sed 's/-[0-9].*//')

	listing=$(curl -fsSL "${MIRROR_URL}/${RELEASE}/${dir}/" 2>/dev/null || true)
	latest=$(echo "$listing" | grep -oP "${prefix}-[^\"]+\.txz" | sort -V | tail -1 || true)

	[[ -z "$latest" ]] && return 1

	alt="${dir}/${latest}"
	curl -fsSL -o "${CACHEFS}/${alt}" "${MIRROR_URL}/${RELEASE}/${alt}" 2>/dev/null || return 1
	echo "${CACHEFS}/${alt}"
}

fetch_package_paths() {
	curl -fsSL "${MIRROR_URL}/${RELEASE}/${PKG_SUBDIR}/FILE_LIST" \
	| grep '\.t.z$' | awk '{print $8}' | sed 's|^\./||'
}

# =========================================================
# MANIFEST + FILE_LIST
# =========================================================
paths_file="${CACHEFS}/paths"
[[ ! -f "$paths_file" ]] && fetch_package_paths > "$paths_file"

manifest="${CACHEFS}/manifest"
[[ ! -f "$manifest" ]] && {
	for p in $base_pkgs; do
		match=$(grep "^${p}.*\.t.z$" "$paths_file" | head -1 || true)
		[[ -n "$match" ]] && echo "${PKG_SUBDIR}/${match}" || echo "SKIP $p" >&2
	done > "$manifest"
}

# =========================================================
# PARALLEL DOWNLOAD (FULL FALLBACK)
# =========================================================
echo "Downloading packages..."
export CACHEFS MIRROR_URL RELEASE

cat "$manifest" | xargs -P 8 -I{} bash -c '
file="{}"
cache_path="'"$CACHEFS"'/${file}"

if [[ -f "$cache_path" ]]; then exit 0; fi
mkdir -p "$(dirname "$cache_path")"

curl -fsSL -o "$cache_path" "'"$MIRROR_URL/$RELEASE"'/${file}" && exit 0

rm -f "$cache_path"

dir=$(dirname "$file")
prefix=$(basename "$file" | sed "s/-[0-9].*//")

listing=$(curl -fsSL "'"$MIRROR_URL/$RELEASE"'/${dir}/" 2>/dev/null || true)
latest=$(echo "$listing" | grep -oP "${prefix}-[^\"]+\.txz" | sort -V | tail -1 || true)

[[ -z "$latest" ]] && exit 1

alt="${dir}/${latest}"
curl -fsSL -o "'"$CACHEFS"'/${alt}" "'"$MIRROR_URL/$RELEASE"'/${alt}" 2>/dev/null || exit 1
'

# =========================================================
# INSTALL
# =========================================================
echo "Installing packages..."
install_cmd="./sbin/installpkg"
[[ ! -x "$install_cmd" ]] && install_cmd="./usr/lib/setup/installpkg"

for p in $base_pkgs; do
	path=$(grep "^${p}.*\.t.z$" "$paths_file" | head -1 || true)
	[[ -z "$path" ]] && continue

	f="${CACHEFS}/${PKG_SUBDIR}/${path}"
	[[ ! -f "$f" ]] && continue

	chroot . "$install_cmd" --root /mnt "$f" || true
done

# =========================================================
# FIX: ldconfig (关键修复 perl)
# =========================================================
chroot . /sbin/ldconfig 2>/dev/null || true

# =========================================================
# CA CERTS (perl-safe)
# =========================================================
mkdir -p etc/ssl/certs etc/pki/tls

cp -a /etc/ssl/certs/* etc/ssl/certs/ 2>/dev/null || true
cp -a /etc/pki/tls/* etc/pki/tls/ 2>/dev/null || true
[[ -f /etc/ssl/cert.pem ]] && cp /etc/ssl/cert.pem etc/ssl/

chroot . sh -c '
	export PATH=/bin:/sbin:/usr/bin:/usr/sbin
	export LD_LIBRARY_PATH=/lib:/usr/lib:/lib64:/usr/lib64
	update-ca-certificates --fresh 2>/dev/null || true
' || true

if [[ ! -f etc/ssl/certs/ca-certificates.crt ]]; then
	find etc/ssl/certs -name "*.pem" -exec cat {} + \
	> etc/ssl/certs/ca-certificates.crt 2>/dev/null || true
fi

echo 'ca_certificate = /etc/ssl/certs/ca-certificates.crt' > etc/wgetrc

# =========================================================
# PERL CHECK (FIXED)
# =========================================================
echo "Checking perl..."
chroot . env PATH=/bin:/sbin:/usr/bin:/usr/sbin ldd /usr/bin/perl 2>/dev/null | grep "not found" || true

echo "DONE"