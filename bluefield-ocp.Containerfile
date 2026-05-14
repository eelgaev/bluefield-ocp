ARG BUILDER_IMAGE
ARG TARGET_IMAGE
ARG RHCOS_VERSION
ARG BLUEFIELD_OCP_VERSION
ARG BLUEFIELD_OCP_BRANCH
ARG D_DOCA_VERSION
ARG D_DOCA_BASEURL
ARG D_DOCA_BASEURL_AUTH=false
ARG D_DOCA_BASEURL_AUTH_CREDS=
ARG D_OFED_VERSION
ARG KERNEL_TYPE=default




FROM ${TARGET_IMAGE} AS base

ARG RHCOS_VERSION
ARG BLUEFIELD_OCP_VERSION
ARG BLUEFIELD_OCP_BRANCH
ARG D_DOCA_VERSION
ARG D_DOCA_DISTRO
ARG D_DOCA_BASEURL
ARG D_DOCA_BASEURL_AUTH=false
ARG D_DOCA_BASEURL_AUTH_CREDS
ARG D_OFED_VERSION
ARG IMAGE_TAG
ARG COREOS_OPENCONTAINERS_IMAGE_VERSION
ARG BOOTIMAGES_PACKAGE=mlxbf-bootimages-signed
ARG FW_PACKAGE=mlnx-fw-updater-signed
ARG BMC_FW_PACKAGES="bf3-bmc-fw-signed bf3-cec-fw-signed bf3-bmc-gi-signed bf3-bmc-nic-fw*"

ARG KERNEL_TYPE=default

# Pin dnf releasever to the exact RHEL minor version (e.g. 9.6) from /etc/os-release
# and enable EUS repos for exact kernel version matching
RUN source /etc/os-release && \
  echo "${VERSION_ID}" > /etc/dnf/vars/releasever && \
  dnf config-manager --set-enabled rhel-9-for-aarch64-baseos-eus-rpms && \
  dnf config-manager --set-enabled rhel-9-for-aarch64-appstream-eus-rpms

ENV D_DOCA_FINALURL=${D_DOCA_BASEURL:-https://linux.mellanox.com/public/repo/doca/${D_DOCA_VERSION}/${D_DOCA_DISTRO}/arm64-dpu/}

RUN --mount=type=secret,id=d-doca-baseurl-auth-creds/username-and-password \
  dnf config-manager --set-enabled codeready-builder-for-rhel-9-$(uname -m)-rpms || \
  dnf config-manager --set-enabled codeready-builder-beta-for-rhel-9-$(uname -m)-rpms; \
  dnf clean all; \
  mkdir -p /tmp/rpms; \
  if [ "${D_DOCA_BASEURL_AUTH}" = "true" ]; then \
  if [ -f /run/secrets/d-doca-baseurl-auth-creds/username-and-password ]; then \
  DOCA_CREDS=$(cat /run/secrets/d-doca-baseurl-auth-creds/username-and-password); \
  elif [ -n "${D_DOCA_BASEURL_AUTH_CREDS}" ]; then \
  DOCA_CREDS="${D_DOCA_BASEURL_AUTH_CREDS}"; \
  fi; \
  if [ -n "${DOCA_CREDS}" ]; then \
  REPO_URL=$(echo "${D_DOCA_FINALURL}" | sed -E "s|(https?://)(.*)|\1${DOCA_CREDS}@\2|"); \
  else \
  REPO_URL="${D_DOCA_FINALURL}"; \
  fi; \
  else \
  REPO_URL="${D_DOCA_FINALURL}"; \
  fi; \
  cat <<EOF > /etc/yum.repos.d/doca.repo
[doca]
name=Nvidia DOCA repository
baseurl=$REPO_URL
gpgcheck=0
enabled=1
EOF

WORKDIR /

RUN if [ "$KERNEL_TYPE" = "64k" ]; then \
  echo "Installing 64k kernel variant..." && \
  KVER=$(rpm -q kernel-core --queryformat '%{VERSION}-%{RELEASE}') && \
  dnf install -y --setopt=install_weak_deps=False \
  kernel-64k-core-${KVER} \
  kernel-64k-modules-${KVER} \
  kernel-64k-modules-core-${KVER} \
  kernel-64k-modules-extra-${KVER} && \
  rpm -e --nodeps kernel kernel-core kernel-modules kernel-modules-core kernel-modules-extra; \
  fi

RUN \
  # Setup /opt for package installations
  rm opt && mkdir -p usr/opt && ln -s usr/opt opt; \
  ls /tmp/rpms; \
  #
  # Remove default packages
  dnf remove -y \
  # Replace openvswitch with doca-openvswitch
  openvswitch-selinux-extra-policy openvswitch* \
  # Remove unused big packages
  geolite2-city \
  ose-azure-acr-image-credential-provider \
  ose-aws-ecr-image-credential-provider \
  ose-gcp-gcr-image-credential-provider; \
  #
  # # Install doca-runtime meta packages without their dependencies
  cd /tmp; \
  dnf download doca-runtime doca-runtime-kernel doca-runtime-user bf-release && \
  rpm -ivh --nodeps \
  doca-runtime-kernel-${D_DOCA_VERSION}*.$(uname -m).rpm \
  doca-runtime-user*.$(uname -m).rpm \
  doca-runtime-${D_DOCA_VERSION}*.$(uname -m).rpm; \
  ## doca-runtime-kernel and doca-devel-kernel are still tied to specific kernel, but we compiled these on our own, so we ignore the specific version dependency
  ## doca-runtime-user requires it's own doca-openvswitch packages, and requires bf-release
  #
  # Install bf-release in a hacky way until we have a proper bf-release package
  cd /tmp; \
  dnf download bf-release && \
  mkdir /tmp/bf-release && \
  rpm --notriggers --replacefiles --justdb -ivh --nodeps bf-release-*.aarch64.rpm && \
  rpm2cpio bf-release-*.aarch64.rpm | cpio -idm -D /tmp/bf-release; \
  rm -rf /tmp/bf-release/var /tmp/bf-release/usr/lib/systemd /tmp/bf-release/usr/share /tmp/bf-release/etc/sysconfig \
  /tmp/bf-release/etc/NetworkManager \
  /tmp/bf-release/etc/crictl* /tmp/bf-release/etc/kubelet.d /tmp/bf-release/etc/cni; \
  cp -rnv /tmp/bf-release/* /; \
  echo "bf-bundle-${D_DOCA_VERSION}_rhcos${RHCOS_VERSION}" > /etc/mlnx-release; \
  #
  dnf clean all

RUN dnf -y install --setopt=install_weak_deps=False \
  doca-runtime \
  collectx-clxapi \
  doca-apsh-config \
  doca-bench \
  doca-caps \
  doca-comm-channel-admin \
  doca-dms \
  doca-openvswitch \
  doca-openvswitch-ipsec \
  doca-openvswitch-selinux-policy \
  doca-openvswitch-test \
  doca-pcc-counters \
  doca-sdk-aes-gcm \
  doca-sdk-apsh \
  doca-sdk-argp \
  doca-sdk-comch \
  doca-sdk-common \
  doca-sdk-compress \
  doca-sdk-devemu \
  doca-sdk-dma \
  doca-sdk-dpa \
  doca-sdk-dpdk-bridge \
  doca-sdk-erasure-coding \
  doca-sdk-eth \
  doca-sdk-flow \
  doca-sdk-pcc \
  doca-sdk-rdma \
  doca-sdk-sha \
  doca-sdk-telemetry \
  doca-sdk-telemetry-exporter \
  doca-sdk-urom \
  doca-socket-relay \
  doca-sosreport \
  dpa-stats \
  dpcp  \
  flexio-sdk \
  ibacm \
  infiniband-diags \
  infiniband-diags-compat \
  libibumad \
  libibverbs \
  libibverbs-utils \
  libpka \
  libpka-engine \
  libpka-testutils \
  librdmacm \
  librdmacm-utils \
  libvma \
  libvma-utils \
  mft \
  mft-oem \
  mlnx-dpdk \
  mlnx-ethtool \
  mlnx-iproute2 \
  mlx-OpenIPMI \
  mlxbf-bfscripts \
  ${BOOTIMAGES_PACKAGE} \
  ${FW_PACKAGE} \
  ofed-scripts \
  opensm \
  opensm-libs \
  opensm-static \
  perftest \
  rdma-core \
  srp_daemon \
  ucx \
  ucx-cma \
  ucx-ib \
  ucx-rdmacm \
  acpid \
  mstflint \
  mft-autocomplete \
  mmc-utils \
  device-mapper \
  lm_sensors \
  efibootmgr \
  i2c-tools \
  ipmitool \
  nvmetcli\
  ${BMC_FW_PACKAGES} \
  vim-common \
  dhcp-client && \
  dnf clean all && \
  #
  rpm -e --nodeps ngauge || true && \
  rpm -e --nodeps spdk || true && \
  rpm -e --nodeps doca-dms || true && \
  rpm -e --nodeps libnl3-devel || true && \
  rpm -e --nodeps kernel-headers || true && \
  rpm -e --nodeps libzstd-devel || true && \
  rpm -e --nodeps ncurses-devel || true && \
  rpm -e --nodeps libpcap-devel || true && \
  rpm -e --nodeps elfutils-libelf-devel || true && \
  rpm -e --nodeps libyaml-devel || true

RUN --mount=type=bind,source=assets,target=/tmp/assets \
  # Copy OFED udev rules
  cp /usr/share/doc/mlnx-ofa_kernel/vf-net-link-name.sh /etc/infiniband/vf-net-link-name.sh && \
  cp /usr/share/doc/mlnx-ofa_kernel/82-net-setup-link.rules /usr/lib/udev/rules.d/82-net-setup-link.rules && \
  #
  echo "hugetlbfs:x:$(getent group hugetlbfs | cut -d: -f3):openvswitch" >> /etc/group && \
  sed -i 's/${tmpdir}/${TMP_DIR}/' /usr/bin/bfcfg && \
  echo "L+ /opt/mellanox - - - - /usr/opt/mellanox" > /etc/tmpfiles.d/link-opt.conf && \
  checkmodule -M -m -o /tmp/sfc_controller.mod /tmp/assets/doca-ovs_sfc.te && \
  semodule_package -o /tmp/sfc_controller.pp -m /tmp/sfc_controller.mod && \
  semodule -i /tmp/sfc_controller.pp && \
  rm -f /tmp/sfc_controller.mod /tmp/sfc_controller.pp && \
  #
  # Patch Openvswitch permissions (Workaround)
  sed -i '/OVS_USER_ID/c\OVS_USER_ID="root:root"' /etc/sysconfig/openvswitch && \
  sed -i '/su/c\su root root' /etc/logrotate.d/openvswitch && \
  # Change log paths
  sed -i 's/\/run\/log/\/var\/log/i' /etc/logrotate.d/set_emu_param && \
  sed -i 's/\/run\/log/\/var\/log/i' /etc/logrotate.d/mlx_ipmid && \
  sed -i 's/\/run\/log/\/var\/log/i' /etc/rsyslog.d/set_emu_param.conf && \
  sed -i 's/\/run\/log/\/var\/log/i' /etc/rsyslog.d/mlx_ipmid.conf && \
  sed -i 's/\/run\/log/\/var\/log/i' /usr/bin/mlx_ipmid_init.sh && \
  sed -i 's/\/run\/log/\/var\/log/i' /usr/lib/systemd/system/set_emu_param.service && \
  sed -i 's/\/run\/log/\/var\/log/i' /usr/lib/systemd/system/mlx_ipmid.service && \
  # Plant the pre-built ipmi_sim SDR persistence file.
  # ipmi_sim (mlx-OpenIPMI) does not auto-generate SDR records from the .emu
  # configuration at runtime on RHCOS; it only reads a pre-existing persistence
  # file. Without it the SDR repo stays empty, no SoC-derived sensor values
  # (soc_power, bluefield_temp, power_envelope) are pushed to the BMC over IPMB,
  # and both ipmitool and Redfish return Reading: null for those sensors.
  mkdir -p /var/ipmi_sim/mellanox && \
  install -m 644 /tmp/assets/ipmi/sdr.30.main /var/ipmi_sim/mellanox/sdr.30.main && \
  #
  # Create a directory for BFB update scripts and copy assets
  mkdir -p /opt/mellanox/bfb && \
  cp /tmp/assets/bfb-build/common/install.env/atf-uefi /opt/mellanox/bfb/ && \
  cp /tmp/assets/bfb-build/common/install.env/bmc /opt/mellanox/bfb/ && \
  cp /tmp/assets/bfb-build/common/install.env/nic-fw /opt/mellanox/bfb/ && \
  cp /tmp/assets/infojson.sh /opt/mellanox/bfb/infojson.sh

RUN chmod +x /usr/bin/install-rhcos.sh; \
  systemctl enable acpid.service || true; \
  systemctl enable mlx_ipmid.service || true; \
  systemctl enable set_emu_param.service || true; \
  bash /opt/mellanox/bfb/infojson.sh > /opt/mellanox/bfb/info.json

# Finalize the container image
RUN set -xe; kver=$(ls /usr/lib/modules); env DRACUT_NO_XATTR=1 dracut -vf /usr/lib/modules/$kver/initramfs.img "$kver"; \
  sed -i 's|/opt/mellanox|/usr/opt/mellanox|g' /etc/ld.so.conf.d/*.conf; \
  rm /opt && ln -s /var/opt /opt; \
  ldconfig && \
  dnf clean all -y && \
  rm -rf /var/cache/* /var/log/* /etc/machine-id && \
  find /usr/share/locale -mindepth 1 -maxdepth 1 ! -name 'en' ! -name 'en_US' -exec rm -rf {} + && \
  rm -rf /usr/share/man /usr/share/doc /usr/share/vim && \
  update-pciids && \
  ostree container commit

LABEL "rhcos.version"="${RHCOS_VERSION}"
LABEL "rhcos.kernel.type"="${KERNEL_TYPE}"
LABEL "com.coreos.osname"=rhcos
LABEL "OCP.version"="${RHCOS_VERSION}"
LABEL "NVIDIA.DOCA.version"="${D_DOCA_VERSION}"
LABEL "NVIDIA.OFED.version"="${D_OFED_VERSION}"
LABEL "bluefield-ocp.version"="${BLUEFIELD_OCP_VERSION}"
LABEL "bluefield-ocp.branch"="${BLUEFIELD_OCP_BRANCH}"
