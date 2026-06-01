FROM registry.access.redhat.com/ubi10:latest AS builder

ARG KERNEL_VERSION

RUN \
  KERNEL_PKG_SUFFIX="${KERNEL_VERSION:+-${KERNEL_VERSION}}" && \
  rpm -qa | grep '^kernel' | xargs -r rpm -v -e --nodeps && \
  dnf install -y \
  kernel-64k${KERNEL_PKG_SUFFIX} \
  kernel-64k-core${KERNEL_PKG_SUFFIX} \
  kernel-64k-modules${KERNEL_PKG_SUFFIX} \
  kernel-64k-modules-core${KERNEL_PKG_SUFFIX} \
  kernel-64k-modules-extra${KERNEL_PKG_SUFFIX} \
  kernel-64k-devel${KERNEL_PKG_SUFFIX} \
  kernel-64k-devel-matched${KERNEL_PKG_SUFFIX} \
  kernel-headers${KERNEL_PKG_SUFFIX} \
  kernel-rpm-macros \
  kernel-srpm-macros.noarch

# Additional packages that are mandatory for driver-containers
RUN dnf -y install elfutils-libelf-devel kmod binutils kabi-dw glibc

# Find and install the GCC version used to compile the kernel
# If it cannot be found (fails on some architectures), install the default gcc
RUN export INSTALLED_KERNEL=$(rpm -q --qf "%{VERSION}-%{RELEASE}.%{ARCH}"  kernel-devel) && \
  GCC_VERSION=$(cat /lib/modules/${INSTALLED_KERNEL}/config | grep -Eo "gcc \(GCC\) ([0-9\.]+)" | grep -Eo "([0-9\.]+)") && \
  dnf -y install gcc-${GCC_VERSION} gcc-c++-${GCC_VERSION} || dnf -y install gcc gcc-c++

# Additional packages that are needed for a subset (e.g DPDK) of driver-containers
RUN dnf -y install xz diffutils flex bison

# Packages needed to build driver-containers
RUN dnf -y install git make rpm-build

# Packages needed to sign and run externally build kernel modules
RUN if [ $(arch) == "x86_64" ] || [ $(arch) == "aarch64" ]; then \
  ARCH_DEP_PKGS="mokutil"; fi \
  && dnf -y install openssl keyutils $ARCH_DEP_PKGS

RUN dnf clean all

ARG TAGS=''
RUN if echo "${TAGS:-}" | grep -q scos > /dev/null 2>&1; then sed -i 's/rhel-coreos/stream-coreos/g' /manifests/*; fi

LABEL io.k8s.description="driver-toolkit is a container with the kernel packages necessary for building driver containers for deploying kernel modules/drivers on OpenShift" \
  name="driver-toolkit" \
  io.openshift.release.operator=true \
  version="0.1"

# Last layer for metadata for mapping the driver-toolkit to a specific kernel version
RUN export INSTALLED_KERNEL=$(rpm -q --qf "%{VERSION}-%{RELEASE}.%{ARCH}"  kernel-devel); \
  export INSTALLED_RT_KERNEL=$(rpm -q --qf "%{VERSION}-%{RELEASE}.%{ARCH}+rt"  kernel-rt-core); \
  echo "{ \"KERNEL_VERSION\": \"${INSTALLED_KERNEL}\", \"RT_KERNEL_VERSION\": \"${INSTALLED_RT_KERNEL}\", \"RHEL_VERSION\": \"$(</etc/dnf/vars/releasever)\" }" > /etc/driver-toolkit-release.json
