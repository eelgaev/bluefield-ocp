# Driver Toolkit Build Notes

This directory contains `driver-toolkit.containerfile`, which can build a
driver-toolkit image for a specific OpenShift release.

The build should use `RHCOS_VERSION` as the source of truth. Resolve the
matching RHCOS image from the OpenShift release payload, inspect `/lib/modules`
in that image, and pass the discovered `KERNEL_VERSION` into the local
`driver-toolkit` build.

## Example

```bash
export PULL_SECRET=<path to pull secret file>
export RHCOS_VERSION="4.22.0-rc.5"
export OCP_IMAGE=$(oc adm release info --image-for rhel-coreos-10 "quay.io/openshift-release-dev/ocp-release:$RHCOS_VERSION-aarch64")

export BUILDER_IMAGE="driver-toolkit:$RHCOS_VERSION"

export KERNEL_VERSION="$(podman run --authfile $PULL_SECRET --rm --entrypoint /bin/sh "${OCP_IMAGE}" -c 'ls /lib/modules | sort -V | tail -1')"

podman build -f build/driver-toolkit.containerfile \
  --build-arg KERNEL_VERSION="${KERNEL_VERSION}" \
  -t "${BUILDER_IMAGE}" .
```

## Notes

- `RHCOS_VERSION` selects the correct OpenShift release payload.
- `OCP_IMAGE` is resolved from that payload and is only used to discover the kernel version to build against.
- `BUILDER_IMAGE` is the local image produced by `build/driver-toolkit.containerfile`.
- `KERNEL_VERSION` is taken from the module directory present in `OCP_IMAGE`
  by overriding the image entrypoint, so the local build installs the exact
  kernel package set for that release without starting the image normally.
