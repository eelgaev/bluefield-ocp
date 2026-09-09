# BlueField-OCP

## Pre-requisites

### Container image build requirements

- Podman
- GNU Make and Python 3 (for generating the Containerfile)
- `oc` (OpenShift CLI, used to resolve the RHCOS image from the release payload)
- qemu-user-static-binfmt (needed for building on non-aarch64 machines)
- Active Red Hat subscription and the `subscription-manager` package.

## Generating the Containerfile

The Containerfile is not checked in: it is generated into
`bluefield-ocp.generated.Containerfile` (gitignored) from fragments under
`containerfile/` by `scripts/generate.py` (Python 3 standard library only).
`make build` regenerates it automatically; to generate it by hand:

```bash
make list                                     # show driver sources and optionals
make generate                                 # default: prebuilt drivers from repos
make generate DRIVER_SOURCE=source            # compile OFED/SoC kernel modules from source
make generate OPTIONALS="ofed-repo soc-repo"  # enable optional features
```

(`make generate` wraps `./scripts/generate.py`, which can also be invoked
directly — see `./scripts/generate.py --help`.)

Fragments are concatenated in order of their numeric filename prefix, so a
driver source or optional can contribute steps at any point of the file:

- `containerfile/base/` — always included.
- `containerfile/driver-source/<name>/` — exactly one, chosen with `DRIVER_SOURCE`:
  - `prebuilt` (default) — kernel-module (kmod-*) packages installed from the
    DOCA repositories.
  - `source` — kernel modules compiled from source in a driver-toolkit builder
    stage (`make build` prepares the builder image automatically, see below).
- `containerfile/rhel-source/<name>/` — exactly one, chosen with `RHEL_SOURCE`:
  - `rhsm` (default) — RHEL packages via the host's RHSM entitlements.
  - `repo-file` — a user-provided repo file overrides
    `/etc/yum.repos.d/redhat.repo`; pass it with `REDHAT_REPO=<path>` (a path
    relative to the repo root that is COPYed into the image from the build
    context, e.g. `../repos/rhel-9.repo`).
- `containerfile/optionals/<name>/` — zero or more, chosen with `OPTIONALS`.
  To add one, create the directory with a `NN-name.containerfile` file starting with a
  `#% desc: ...` line (`#% requires:` / `#% conflicts:` constraints are also
  supported); it is picked up automatically.

## Building the Image

1. The project contains Mellanox's bfscripts as a git submodule, so be sure to clone it as well:

    ```bash
    git clone --recursive https://github.com/rh-ecosystem-edge/bluefield-ocp.git
    ```

2. Obtain the OpenShift pull secret file and export it as an environment variable. you can obtain it from [Red Hat OpenShift Console](https://console.redhat.com/openshift/install/pull-secret).

    ```sh
    export PULL_SECRET=<path to pull secret file>
    ```

3. Generate the Containerfile and build the container image:

    ```bash
    make build                       # prebuilt drivers from repos
    make build DRIVER_SOURCE=source  # compile kernel modules from source
    ```

    `make` resolves the RHCOS image for the selected OpenShift release from the
    release payload and tags the result as `bluefield-ocp:$OCP_VERSION-latest`.

    With `DRIVER_SOURCE=source`, the builder image (`BUILDER_IMAGE`) is
    chosen by release:

    - **OCP 5.0+** — the release payload ships `driver-toolkit-10`; `make`
      resolves it with `oc adm release info --image-for driver-toolkit-10`
      and uses it directly.
    - **Earlier releases** (no driver-toolkit-10 in the payload) — `make`
      first builds `build/driver-toolkit.containerfile` as
      `localhost/driver-toolkit:$OCP_VERSION` (against the exact kernel of
      the selected RHCOS image) (see `build/README.md` for details).

### Overriding the defaults

All versions have defaults in the `Makefile` and can be overridden per
invocation (as `make` variables or exported environment variables):

| Variable | Default | Purpose |
| --- | --- | --- |
| `OCP_VERSION` | `4.22.0` | OpenShift release the image is built for |
| `DOCA_VERSION` | `3.4.0` | NVIDIA DOCA version |
| `OFED_VERSION` | `26.04-0.8.5.0` | NVIDIA OFED version |
| `DOCA_DISTRO` | `rhel10.2` | DOCA distro path in the repository |
| `KERNEL_TYPE` | `default` | `64k` selects the 64k page-size kernel |
| `RHEL_SOURCE` | `rhsm` | `repo-file` overrides `redhat.repo` with `REDHAT_REPO=<path>` |
| `IMAGE_TAG` | `bluefield-ocp:$OCP_VERSION-latest` | Output image tag |

For example:

```bash
make build OCP_VERSION=4.22.1 KERNEL_TYPE=64k
```

The repository baseurls can be overridden with `D_DOCA_BASEURL=<url>`, and —
when the corresponding optionals are enabled — `D_OFED_BASEURL=<url>` /
`D_SOC_BASEURL=<url>`. Pass `DOCA_REPO_OMIT=true` to skip writing
`/etc/yum.repos.d/doca.repo` into the image (default: `false`). Anything else
can be passed through `EXTRA_BUILD_ARGS="--build-arg NAME=value ..."`; see the
`podman build` invocation in the `Makefile` for all available build args.

### Firmware version labels

When `PROBE_VERSIONS=true` is passed to `make generate`, the generated
Containerfile includes `NVIDIA.ATF.version`, `NVIDIA.BSP.version`, and
`NVIDIA.UEFI.version` labels. The actual values are extracted at build time
from the argfile.

`make argfile` runs `scripts/probe-versions.sh` automatically to populate
these values. The script downloads `mlxbf-bootimages-signed` and
`mlxbf-bfscripts` from the DOCA repository, extracts the firmware files, and
writes `ATF_VERSION`, `BSP_VERSION`, and `UEFI_VERSION` into the argfile.

```bash
make generate PROBE_VERSIONS=true
make argfile PROBE_VERSIONS=true
# argfile now contains ATF_VERSION=..., BSP_VERSION=..., UEFI_VERSION=...
```

The probe script requires an aarch64 host (or qemu-user-static) because
`bfver` is an aarch64 binary.
