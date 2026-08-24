# Driver installation source: prebuilt (kmod packages from repos) or source
# (kernel modules compiled from source in a driver-toolkit builder stage).
DRIVER_SOURCE ?= prebuilt
# RHEL package source: rhsm (host RHSM entitlements, untouched) or repo-file
# (REDHAT_REPO overrides /etc/yum.repos.d/redhat.repo in the image; the file
# is COPYed from the build context at build time).
RHEL_SOURCE   ?= rhsm
REDHAT_REPO   ?=
# Space-separated optional features, see `make list`.
OPTIONALS     ?=
KERNEL_TYPE   ?= default

OCP_VERSION ?= 4.22.0
DOCA_VERSION      ?= 3.4.0
DOCA_URL_VERSION  ?=
OFED_VERSION  ?= 26.04-0.8.5.0

# OCP 4.22+ ships RHEL 10; earlier releases ship RHEL 9.
RHEL_MAJOR    := $(shell [ $$(echo '$(OCP_VERSION)' | cut -d. -f2) -ge 22 ] && echo 10 || echo 9)
DOCA_DISTRO   ?= rhel10.2

# The generated Containerfile lands in the directory make is invoked from.
CONTAINERFILE ?= bluefield-ocp.generated.Containerfile

# Space-separated extra fragment roots (same layout as containerfile/),
# overlaid on top of the public fragments — e.g. a private directory in a
# parent project that embeds this repo as a submodule. Same-named files
# override the public ones; an override with an empty body removes the step.
EXTRA_DIRS ?=
EXTRA_DIR_FLAGS = $(foreach dir,$(EXTRA_DIRS),--extra-dir $(dir))
IMAGE_TAG     ?= bluefield-ocp:$(OCP_VERSION)-latest
DTK_IMAGE     ?= localhost/driver-toolkit:$(OCP_VERSION)
BUILDER_IMAGE ?= $(DTK_IMAGE)

# Template variables forwarded to generate.py via --set when set.
# These are baked into the generated Containerfile at generate time.
TEMPLATE_ARGS = \
  TARGET_IMAGE BUILDER_IMAGE \
  UPDATE_PCIIDS \
  ATF_VERSION BSP_VERSION UEFI_VERSION \
  BLUEFIELD_OCP_VERSION BLUEFIELD_OCP_BRANCH \
  BOOTIMAGES_PACKAGE FW_PACKAGE BMC_FW_PACKAGES \
  D_DOCA_BASEURL D_DOCA_BASEURL_AUTH \
  D_OFED_BASEURL D_OFED_BASEURL_AUTH \
  D_SOC_BASEURL D_SOC_BASEURL_AUTH \
  D_OFED_SRC_TYPE D_OFED_SRC_ARCHIVE DOCA_SOURCES_URL \
  PROBE_VERSIONS \
  D_DOCA_URL_VERSION \
  REDHAT_REPO \
  ASSETS_DIR \
  release version

# Credential args forwarded to podman as --build-arg (not baked into the
# Containerfile; consumed at build time via ARG / build secrets).
BUILD_ONLY_ARGS = D_DOCA_BASEURL_AUTH_CREDS D_OFED_BASEURL_AUTH_CREDS D_SOC_BASEURL_AUTH_CREDS
FORWARDED_BUILD_ARGS = $(foreach v,$(BUILD_ONLY_ARGS),$(if $($(v)),--build-arg $(v)="$($(v))"))
EXTRA_BUILD_ARGS ?=

# Resolved lazily via $(shell) — only evaluated when referenced.
OCP_RELEASE_IMAGE ?= quay.io/openshift-release-dev/ocp-release:$(OCP_VERSION)-aarch64
RHCOS_VARIANT    := $(if $(filter 10,$(RHEL_MAJOR)),rhel-coreos-10,rhel-coreos)
TARGET_IMAGE   ?= $(shell oc adm release info --image-for $(RHCOS_VARIANT) "$(OCP_RELEASE_IMAGE)")
KERNEL_VERSION ?= $(shell podman run --authfile "$(PULL_SECRET)" --rm --entrypoint /bin/sh "$(TARGET_IMAGE)" -c 'ls /lib/modules | sort -V | tail -1')

.PHONY: help list generate build driver-toolkit-build check-redhat-repo check-pull-secret clean
.DEFAULT_GOAL := help

help:
	@echo "targets:"
	@echo "  make generate [DRIVER_SOURCE=prebuilt|source] [RHEL_SOURCE=rhsm|repo-file] [OPTIONALS=\"...\"]"
	@echo "  make build    [DRIVER_SOURCE=prebuilt|source] [RHEL_SOURCE=rhsm|repo-file REDHAT_REPO=<path>] PULL_SECRET=<path>"
	@echo "  make driver-toolkit-build    build $(DTK_IMAGE) for source builds (skipped if it exists)"
	@echo "  make list              show driver sources and optionals"
	@echo "  make clean             remove the generated Containerfile"
	@echo "variables: OCP_VERSION DOCA_VERSION OFED_VERSION DOCA_DISTRO KERNEL_TYPE IMAGE_TAG"
	@echo "           EXTRA_DIRS=\"<dir> ...\"  overlay private/extra fragment roots"

list:
	./scripts/generate.py $(EXTRA_DIR_FLAGS) --list

generate:
	./scripts/generate.py --driver-source $(DRIVER_SOURCE) \
	  --rhel-source $(RHEL_SOURCE) \
	  $(foreach opt,$(OPTIONALS),--enable $(opt)) \
	  $(EXTRA_DIR_FLAGS) \
	  --set OCP_VERSION=$(OCP_VERSION) \
	  --set D_DOCA_VERSION=$(DOCA_VERSION) \
	  $(if $(DOCA_URL_VERSION),--set D_DOCA_URL_VERSION=$(DOCA_URL_VERSION)) \
	  --set D_OFED_VERSION=$(OFED_VERSION) \
	  --set D_DOCA_DISTRO=$(DOCA_DISTRO) \
	  --set KERNEL_TYPE=$(KERNEL_TYPE) \
	  --set RHEL_MAJOR=$(RHEL_MAJOR) \
	  $(foreach v,$(TEMPLATE_ARGS),$(if $($(v)),--set $(v)=$($(v)))) \
	  --output $(CONTAINERFILE)

# Source builds need a builder image with the exact RHCOS kernel packages.
ifeq ($(DRIVER_SOURCE),source)
build: driver-toolkit-build
endif

ifeq ($(RHEL_SOURCE),repo-file)
build: check-redhat-repo
endif

# When PROBE_VERSIONS is set, run the probe once at parse time and capture
# the version values as Make variables.
ifeq ($(PROBE_VERSIONS),true)
PROBE_OUTPUT := $(shell D_DOCA_VERSION=$(DOCA_VERSION) D_DOCA_DISTRO=$(DOCA_DISTRO) \
  $(if $(DOCA_URL_VERSION),D_DOCA_URL_VERSION=$(DOCA_URL_VERSION)) \
  $(if $(D_DOCA_BASEURL),D_DOCA_BASEURL=$(D_DOCA_BASEURL)) \
  $(if $(BOOTIMAGES_PACKAGE),BOOTIMAGES_PACKAGE=$(BOOTIMAGES_PACKAGE)) \
  ./scripts/probe-versions.sh)
ATF_VERSION  := $(word 2,$(subst =, ,$(filter ATF_VERSION=%,$(PROBE_OUTPUT))))
BSP_VERSION  := $(word 2,$(subst =, ,$(filter BSP_VERSION=%,$(PROBE_OUTPUT))))
UEFI_VERSION := $(word 2,$(subst =, ,$(filter UEFI_VERSION=%,$(PROBE_OUTPUT))))
endif
check-redhat-repo:
	@test -f "$(REDHAT_REPO)" || { echo "ERROR: RHEL_SOURCE=repo-file needs REDHAT_REPO=<path to a redhat.repo file>" >&2; exit 1; }

build: generate check-pull-secret
	podman build -f $(CONTAINERFILE) \
	  --authfile "$(PULL_SECRET)" \
	  $(FORWARDED_BUILD_ARGS) \
	  $(EXTRA_BUILD_ARGS) \
	  --tag "$(IMAGE_TAG)" .

# Build the driver-toolkit builder image unless it already exists (the tag
# embeds OCP_VERSION, so a version bump still gets a fresh build; run
# `podman rmi $(DTK_IMAGE)` to force one).
# The kernel version is discovered from the RHCOS image of the release payload
# (see build/README.md). --arch=arm64 so cross-builds pick aarch64 kernel
# packages (requires qemu-user-static-binfmt on non-aarch64 hosts).
driver-toolkit-build: check-pull-secret
	$(if $(shell podman image exists "$(DTK_IMAGE)" && echo y),\
	@echo "$(DTK_IMAGE) already exists - skipping build (podman rmi it to force a rebuild)",\
	podman build -f build/driver-toolkit.containerfile \
	  --arch=arm64 \
	  --build-arg KERNEL_VERSION="$(KERNEL_VERSION)" \
	  --tag "$(DTK_IMAGE)" .)

check-pull-secret:
	@test -n "$(PULL_SECRET)" || { echo "ERROR: set PULL_SECRET=<path to OpenShift pull secret>" >&2; exit 1; }

clean:
	rm -f $(CONTAINERFILE)
