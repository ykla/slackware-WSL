#!/bin/bash
set -euo pipefail
# Ignore SIGPIPE to avoid "Broken pipe" errors when grep pipes to head/tail
trap '' PIPE
# Generate a very minimal filesystem from slackware

# ---- Architecture detection ----
if [[ -z "${ARCH:-}" ]]; then
	case "$(uname -m)" in
		i?86) ARCH="" ;;
		aarch64) ARCH=aarch64 ;;
		arm*) ARCH=arm ;;
		   *) ARCH=64 ;;
	esac
fi

# ---- Architecture-specific configuration ----
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

# ---- Configuration ----
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
	if curl -fsSL -o "${cache_path}" "${MIRROR_URL}/${RELEASE}/${file}" 2>/dev/null; then
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
	listing=$(curl -fsSL "${MIRROR_URL}/${RELEASE}/${dir_path}/" 2>/dev/null) || return 1

	local latest
	latest=$(echo "${listing}" | grep -oP "${pkg_prefix}-[^\"]+\.txz" | sort -V | tail -1) || true
	[[ -z "${latest}" ]] && return 1

	local alt_file="${dir_path}/${latest}"
	if curl -fsSL -o "${CACHEFS}/${alt_file}" "${MIRROR_URL}/${RELEASE}/${alt_file}" 2>/dev/null; then
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
	local url="${MIRROR_URL}/${RELEASE}/${PKG_SUBDIR}/FILE_LIST"
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
	n/ca-certificates \
	n/curl \
	l/readline \
	l/zlib \
	ap/nano \
	a/elvis \
	ap/less \
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
	n/openssl \
	l/glibc-i18n \
	a/glibc-zoneinfo \
	n/rsync \
	l/lz4 \
	l/xxhash \
	l/popt \
	l/libgpg-error \
	l/libgcrypt \
	l/libassuan \
	l/libksba \
	l/npth \
	l/libssh2 \
	l/nghttp2 \
	l/brotli \
	l/libidn2 \
	l/zstd \
	l/attr \
	l/acl \
	l/expat \
	l/gdbm \
	l/jsoncpp \
	l/libarchive \
	l/libcap \
	l/libffi \
	l/libmnl \
	l/libuv \
	l/lzo \
	l/mpdecimal \
	l/rhash \
	ap/db48 \
	ap/pinentry \
	ap/sqlite \
	d/cmake \
	d/perl \
	d/python3 \
	d/gcc \
	d/gcc-g++ \
	d/make \
	d/binutils \
	d/autoconf \
	d/automake \
	d/libtool \
	d/pkg-config \
	d/git \
	l/libmpc \
	l/gmp \
	l/isl \
	a/lzip \
	a/infozip \
	a/glibc \
	d/kernel-headers"

# ---- Logging helpers ----
LOG_SEPARATOR() {
	echo "========================================================================" >&2
}
LOG_STEP() {
	echo "" >&2
	LOG_SEPARATOR
	echo "  STEP: $1" >&2
	LOG_SEPARATOR
	echo "" >&2
}

# ---- Build ----
mkdir -p "$ROOTFS" "$CACHEFS"

LOG_STEP "Downloading initrd for ${ARCH} ${VERSION}"
download_pkg "${INITRD_PATH}"

cd "$ROOTFS"

LOG_STEP "Extracting initrd"
# extract the initrd to the current rootfs
if file "${CACHEFS}/${INITRD_PATH}" | grep -wq XZ; then
	xzcat "${CACHEFS}/${INITRD_PATH}" | cpio -idm --null --no-absolute-filenames
else
	zcat "${CACHEFS}/${INITRD_PATH}" | cpio -idm --null --no-absolute-filenames
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

LOG_STEP "Detecting install command"
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
LOG_STEP "Fetching package list from mirror"
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
LOG_STEP "Resolving package paths and downloading"
# Step 1: resolve all paths from FILE_LIST into a download manifest
manifest_file="${CACHEFS}/manifest"
if [[ ! -f "${manifest_file}" ]]; then
	for pkg in ${base_pkgs}; do
		path=$(grep "^${pkg}.*\.t.z$" "${paths_file}" | head -1) || true
		if [[ -n "${path}" ]]; then
			echo "${PKG_SUBDIR}/${path}"
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
	if curl -fsSL -o "${cache_path}" "'"${MIRROR_URL}/${RELEASE}"'/${file}" 2>/dev/null; then
		echo "  OK: ${file}" >&2
		exit 0
	fi
	rm -f "${cache_path}"
	# Fallback: scan directory for latest version
	dir_path=$(dirname "${file}")
	pkg_prefix=$(basename "${file}" | sed "s/-[0-9].*//")
	listing=$(curl -fsSL "'"${MIRROR_URL}/${RELEASE}"'/${dir_path}/" 2>/dev/null) || exit 1
	latest=$(echo "${listing}" | grep -oP "${pkg_prefix}-[^\"]+\.txz" | sort -V | tail -1) || true
	if [[ -z "${latest}" ]]; then
		echo "  FAIL: ${file} not found" >&2
		exit 1
	fi
	alt_file="${dir_path}/${latest}"
	if curl -fsSL -o "'"${CACHEFS}"'/${alt_file}" "'"${MIRROR_URL}/${RELEASE}"'/${alt_file}" 2>/dev/null; then
		echo "  OK (fallback): ${alt_file}" >&2
		exit 0
	fi
	echo "  FAIL: ${alt_file}" >&2
	rm -f "'"${CACHEFS}"'/${alt_file}"
	exit 1
' || true

# Log download summary
download_ok=$(find "${CACHEFS}/${PKG_SUBDIR}" -name '*.txz' 2>/dev/null | wc -l)
echo "Download summary: ${download_ok} packages cached in ${CACHEFS}/${PKG_SUBDIR}" >&2

# Step 3: install packages sequentially
base_pkgs_count=$(echo "${base_pkgs}" | wc -w)
LOG_STEP "Installing ${base_pkgs_count} base packages"

install_ok=0
install_fail=0
install_skip=0
for pkg in ${base_pkgs}; do
	path=$(grep "^${pkg}.*\.t.z$" "${paths_file}" | head -1) || true
	if [[ -z "${path}" ]]; then
		echo "SKIP: ${pkg} not found in package list" >&2
		install_skip=$((install_skip + 1))
		continue
	fi

	# Check if file was downloaded (exact or fallback)
	cached_path="${CACHEFS}/${PKG_SUBDIR}/${path}"
	if [[ ! -f "${cached_path}" ]]; then
		# Check for fallback version
		dir_path=$(dirname "${PKG_SUBDIR}/${path}")
		pkg_prefix=$(basename "${path}" | sed 's/-[0-9].*//')
		latest=$(ls "${CACHEFS}/${dir_path}/${pkg_prefix}"-*.txz 2>/dev/null | sort -V | tail -1) || true
		if [[ -n "${latest}" ]]; then
			l_pkg="/cdrom/${latest#${CACHEFS}/}"
		else
			echo "SKIP: ${pkg} not downloaded, will be installed by slackpkg later" >&2
			install_skip=$((install_skip + 1))
			continue
		fi
	else
		l_pkg="/cdrom/${PKG_SUBDIR}/${path}"
	fi

	echo "Installing ${pkg}..." >&2
	if ! PATH=/bin:/sbin:/usr/bin:/usr/sbin chroot . ${install_cmd} --root /mnt ${install_args} "${l_pkg}"; then
		echo "WARN: ${pkg} install failed, will be retried by slackpkg" >&2
		install_fail=$((install_fail + 1))
	else
		install_ok=$((install_ok + 1))
	fi
done

echo "" >&2
echo "Base package install summary:" >&2
echo "  OK:   ${install_ok}" >&2
echo "  FAIL: ${install_fail}" >&2
echo "  SKIP: ${install_skip}" >&2
echo "  Total: $((install_ok + install_fail + install_skip)) / ${base_pkgs_count}" >&2

# Check for missing shared libraries in the installed rootfs
LOG_STEP "Checking for missing shared libraries"
missing_libs=$(PATH=/bin:/sbin:/usr/bin:/usr/sbin chroot . ldd /mnt/usr/bin/* /mnt/usr/sbin/* /mnt/bin/* /mnt/sbin/* 2>/dev/null | grep 'not found' | sort -u || true)
if [[ -n "${missing_libs}" ]]; then
	echo "WARNING: The following shared libraries are missing:" >&2
	echo "${missing_libs}" >&2
else
	echo "All shared libraries resolved OK" >&2
fi

# ---- System Configuration ----
LOG_STEP "System configuration"
cd mnt

touch etc/resolv.conf
echo 'export TERM=linux' >> etc/profile.d/term.sh
chmod +x etc/profile.d/term.sh
echo '. /etc/profile' > .bashrc

# Configure Simplified Chinese locale
if localedef --list-archive 2>/dev/null | grep -q 'zh_CN'; then
	echo 'zh_CN.UTF-8 UTF-8' > etc/locale.nopurge
else
	# Generate zh_CN.UTF-8 locale from glibc-i18n
	if [[ -d usr/lib/locale ]]; then
		localedef -i zh_CN -f UTF-8 zh_CN.UTF-8 2>/dev/null || true
	fi
	echo 'zh_CN.UTF-8 UTF-8' > etc/locale.nopurge
fi
cat > etc/profile.d/lang.sh << 'LOCALE'
export LANG=zh_CN.UTF-8
export LC_ALL=zh_CN.UTF-8
LOCALE
chmod +x etc/profile.d/lang.sh

# Set timezone to Asia/Shanghai
if [[ -f usr/share/zoneinfo/Asia/Shanghai ]]; then
	ln -sf /usr/share/zoneinfo/Asia/Shanghai etc/localtime
	echo 'Asia/Shanghai' > etc/timezone
fi

echo "${MIRROR_URL}/${RELEASE}/" >> etc/slackpkg/mirrors
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

# Regenerate CA certificate bundle inside chroot
# This creates /etc/ssl/certs/ca-certificates.crt which wget uses for verification
LOG_STEP "Setting up CA certificates"
mkdir -p etc/ssl/certs

chroot . sh -c '
	if command -v update-ca-certificates >/dev/null 2>&1; then
		update-ca-certificates --fresh
	fi
' || true

if [[ ! -f etc/ssl/certs/ca-certificates.crt ]]; then
	if [[ -f etc/ssl/cert.pem ]]; then
		cp etc/ssl/cert.pem etc/ssl/certs/ca-certificates.crt
	else
		find etc/ssl/certs -name "*.pem" -exec cat {} + \
			> etc/ssl/certs/ca-certificates.crt 2>/dev/null || true
	fi
fi

# Verify CA bundle exists
if [[ -f etc/ssl/certs/ca-certificates.crt ]]; then
	cert_count=$(grep -c 'BEGIN CERTIFICATE' etc/ssl/certs/ca-certificates.crt 2>/dev/null || echo 0)
	echo "CA bundle OK: ${cert_count} certificates in /etc/ssl/certs/ca-certificates.crt" >&2
else
	echo "WARNING: /etc/ssl/certs/ca-certificates.crt not found!" >&2
fi

# Ensure wget uses the system CA bundle
if [[ -f etc/wgetrc ]]; then
	if ! grep -q 'ca_certificate' etc/wgetrc 2>/dev/null; then
		echo 'ca_certificate = /etc/ssl/certs/ca-certificates.crt' >> etc/wgetrc
	fi
else
	echo 'ca_certificate = /etc/ssl/certs/ca-certificates.crt' > etc/wgetrc
fi

mount --bind /etc/resolv.conf etc/resolv.conf

# ---- Install sbopkg ----
LOG_STEP "Installing sbopkg"

SBOPKG_VERSION="0.38.3"
SBOPKG_URL="https://github.com/sbopkg/sbopkg/releases/download/${SBOPKG_VERSION}/sbopkg-${SBOPKG_VERSION}-noarch-1_wsr.tgz"
SBOPKG_PKG="/tmp/sbopkg-${SBOPKG_VERSION}-noarch-1_wsr.tgz"

if ! curl -fsSL -o "${SBOPKG_PKG}" "${SBOPKG_URL}"; then
	echo "WARNING: Failed to download sbopkg from ${SBOPKG_URL}" >&2
else
	cp "${SBOPKG_PKG}" tmp/

	echo "Checking package location..." >&2
	ls -l tmp/sbopkg-${SBOPKG_VERSION}-noarch-1_wsr.tgz >&2

	if chroot . test -f \
		"/tmp/sbopkg-${SBOPKG_VERSION}-noarch-1_wsr.tgz"
	then
		echo "Package visible inside chroot" >&2
	else
		echo "WARNING: Package not visible inside chroot" >&2
	fi

	if chroot . /sbin/installpkg \
		"/tmp/sbopkg-${SBOPKG_VERSION}-noarch-1_wsr.tgz"
	then
		echo "sbopkg ${SBOPKG_VERSION} installed OK" >&2
	else
		echo "WARNING: sbopkg install failed" >&2
	fi

	rm -f "${SBOPKG_PKG}"
	rm -f tmp/sbopkg-*.tgz
fi

# Post-slackpkg dependency check
LOG_STEP "Post-slackpkg dependency check"

missing_libs2=$(find /mnt/usr/bin /mnt/usr/sbin /mnt/bin /mnt/sbin -maxdepth 1 -type f -executable 2>/dev/null | \
	xargs -r -I {} chroot . env PATH=/bin:/sbin:/usr/bin:/usr/sbin ldd {} 2>/dev/null | \
	grep 'not found' | sort -u || true)

if [[ -n "${missing_libs2}" ]]; then
	echo "WARNING: The following shared libraries are still missing after slackpkg:" >&2
	echo "${missing_libs2}" >&2
else
	echo "All shared libraries resolved OK after slackpkg" >&2
fi

# List all installed packages
if [[ -d "/mnt/var/log/packages/" ]]; then
	installed_count=$(find /mnt/var/log/packages/ -maxdepth 1 -type f 2>/dev/null | wc -l || echo 0)
else
	installed_count=0
fi

echo "Total installed packages: ${installed_count}" >&2
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

LOG_STEP "Build complete"
echo "Architecture: ${ARCH}" >&2
echo "Version: ${VERSION}" >&2
echo "Release: ${RELEASE}" >&2
echo "Mirror: ${MIRROR_URL}" >&2
echo "Installed packages: ${installed_count}" >&2
echo "Output: ${CWD}/${RELEASE}.tar.gz" >&2

echo "Done."