# BlueField-OCP

## Pre-requisites

### Container image build requirements

- Podman
- qemu-user-static-binfmt (needed for building on non-aarch64 machines)
- Active Red Hat subscription and the `subscription-manager` package.

## Building the Image

1. The project contains Mellanox's bfscripts as a git submoudle, so be sure to clone it as well:

    ```bash
    git clone --recursive https://github.com/rh-ecosystem-edge/bluefield-ocp.git
    ```

2. Obtain the OpenShift pull secret file and export it as an environment variable. you can obtain it from [Red Hat OpenShift Console](https://console.redhat.com/openshift/install/pull-secret).

    ```sh
    export PULL_SECRET=<path to pull secret file>
    ```

3. Get the RHCOS release images from OCP release payload, in this example we use 4.21.8

    ```bash
    export RHCOS_VERSION="4.22.0-rc.5"
    export TARGET_IMAGE=$(oc adm release info --image-for rhel-coreos-10 "quay.io/openshift-release-dev/ocp-release:"$RHCOS_VERSION"-aarch64")
    ```

4. Set NVIDIA DOCA stack versions

    Set Nvidia DPU stack versions:

    ```bash
    export DOCA_VERSION="3.4.0"
    export OFED_VERSION="26.04-0.8.5.0"
    export DOCA_DISTRO="rhel10.2"
    ```

5. Build the container image:

    ```bash
    podman build -f bluefield-ocp.Containerfile \
      --authfile $PULL_SECRET \
      --build-arg RHCOS_VERSION=$RHCOS_VERSION \
      --build-arg TARGET_IMAGE=$TARGET_IMAGE \
      --build-arg D_DOCA_VERSION=$DOCA_VERSION \
      --build-arg D_OFED_VERSION=$OFED_VERSION \
      --build-arg D_DOCA_DISTRO=$DOCA_DISTRO \
      --tag "bluefield-ocp:$RHCOS_VERSION-latest" .
    ```

    Optionally, you can override the DOCA repository baseurl by adding: `-build-arg D_DOCA_BASEURL=<custom_doca_repo_baseurl>` to the above `podman build` command.
