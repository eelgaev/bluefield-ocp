#!/bin/bash
# Extract ATF, BSP, and UEFI firmware version strings from DOCA repository
# packages without installing them.  Outputs KEY=VALUE lines to stdout,
# suitable for appending to an argfile.
#
# Required env vars:
#   D_DOCA_VERSION   e.g. 3.4.0
#   D_DOCA_DISTRO    e.g. rhel10.2
# Optional:
#   D_DOCA_URL_VERSION    version used in the URL path (defaults to D_DOCA_VERSION)
#   D_DOCA_BASEURL        override the default public DOCA repo URL
#   BOOTIMAGES_PACKAGE    override the default mlxbf-bootimages-signed package name
set -euo pipefail

: "${D_DOCA_VERSION:?D_DOCA_VERSION is required}"
: "${D_DOCA_DISTRO:?D_DOCA_DISTRO is required}"
DOCA_URL="${D_DOCA_BASEURL:-https://linux.mellanox.com/public/repo/doca/${D_DOCA_URL_VERSION:-${D_DOCA_VERSION}}/${D_DOCA_DISTRO}/arm64-dpu/}"
BOOTIMAGES="${BOOTIMAGES_PACKAGE:-mlxbf-bootimages-signed}"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

cat > "$TMPDIR/doca.repo" <<EOF
[doca]
name=Nvidia DOCA repository
baseurl=${DOCA_URL}
gpgcheck=0
enabled=1
EOF

dnf download \
  --setopt=reposdir="$TMPDIR" \
  --destdir="$TMPDIR/rpms" \
  "$BOOTIMAGES" mlxbf-bfscripts

EXTRACT="$TMPDIR/extract"
mkdir -p "$EXTRACT"
for rpm in "$TMPDIR/rpms"/*.rpm; do
  rpm2cpio "$rpm" | cpio -idm -D "$EXTRACT" 2>/dev/null
done

BFB="$EXTRACT/lib/firmware/mellanox/boot/default.bfb"
CAPSULE="$EXTRACT/lib/firmware/mellanox/boot/capsule/boot_update2.cap"
BFVER="$EXTRACT/usr/bin/bfver"

bfver_out="$("$BFVER" --file "$BFB")"

echo "ATF_VERSION=$(echo "$bfver_out" | grep -m1 'ATF' | cut -d: -f3 | tr -d ' ')"
echo "BSP_VERSION=$(rpm -qp --queryformat '%{VERSION}.%{RELEASE}' "$TMPDIR/rpms/${BOOTIMAGES}"*.rpm)"
echo "UEFI_VERSION=$(echo "$bfver_out" | grep -m1 'UEFI' | cut -d: -f2 | tr -d ' ')"
