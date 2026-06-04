LATEST		:= 14.2
VERSION		:= $(LATEST)
VERSIONS	:= 14.2 current
NAME		:= slackware
MIRROR		:= http://mirrors.ustc.edu.cn/slackware
ifeq ($(shell uname -m),x86_64)
ARCH := 64
else ifeq ($(patsubst i%86,x86,$(shell uname -m)),x86)
ARCH :=
else ifeq ($(shell uname -m),armv6l)
ARCH := arm
else ifeq ($(shell uname -m),aarch64)
ARCH := arm64
else
ARCH := 64
endif
RELEASENAME	?= slackware$(ARCH)
RELEASE		:= $(RELEASENAME)-$(VERSION)
CACHEFS		:= /tmp/$(NAME)/$(RELEASE)
ROOTFS		:= /tmp/rootfs-$(RELEASE)

all: mkimage-slackware.sh
	for version in $(VERSIONS) ; do \
		$(MAKE) $(RELEASENAME)-$${version}.tar.gz && \
		$(MAKE) VERSION=$${version} clean; \
	done

$(RELEASENAME)-%.tar.gz: mkimage-slackware.sh
	sudo \
		VERSION="$*" \
		USER="$(USER)" \
		BUILD_NAME="$(NAME)" \
		MIRROR="$(MIRROR)" \
		bash $<
	$(MAKE) VERSION=$(VERSION) clean

arch:
	@echo $(ARCH)
	@echo $(RELEASE)

.PHONY: umount
umount:
	@sudo umount $(ROOTFS)/cdrom || :
	@sudo umount $(ROOTFS)/dev || :
	@sudo umount $(ROOTFS)/sys || :
	@sudo umount $(ROOTFS)/proc || :
	@sudo umount $(ROOTFS)/etc/resolv.conf || :

.PHONY: clean
clean: umount
	sudo rm -rf $(ROOTFS) $(CACHEFS)/paths

.PHONY: clean-all
clean-all:
	for version in $(VERSIONS) ; do \
		$(MAKE) VERSION=$${version} clean ; \
	done

.PHONY: dist-clean
dist-clean: clean-all
	sudo rm -rf $(CACHEFS)

