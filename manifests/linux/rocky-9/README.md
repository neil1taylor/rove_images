# Rocky Linux 9 — vanilla golden image pipeline (Phase 2 pilot)

Builds a Rocky 9 golden image by importing the upstream **GenericCloud
qcow2** and cloning it into `openshift-virtualization-os-images` as
DataSource `rocky-9`. No Anaconda, no kickstart, no installer VM —
the cloud image is already a sealed, cloud-init-ready Rocky 9 install.

## Why cloud image instead of boot ISO

Phase 2's first attempt used the boot-ISO + Anaconda + kickstart
pattern (matching the existing Win 2022 pipelines). All four runs
failed at `wait-shutdown` after 2–4h: the boot ISO needs to fetch
~500 MB of packages from a public mirror at install time, and the
cluster's outbound throughput to `download.rockylinux.org` /
`mirror.netcologne.de` was too slow to complete inside the task
timeout window. Pivoting to the cloud image eliminates the install
step entirely — the pipeline now just imports a ~600 MB qcow2 and
clones it.

The architectural insight: for Linux distros that publish cloud
images (Rocky, Alma, Ubuntu, Fedora, Debian, openSUSE), the cloud
image is the right golden-image source. Installer ISO + kickstart is
only needed when no cloud image exists (e.g., Windows Server, RHEL
without a subscription, in-house custom builds).

## Image source

Upstream Rocky permalink:
- `https://download.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2`

Mirrored at `mirror.netcologne.de/rocky/9/images/x86_64/` if upstream
is slow. ~600 MB compressed; expands to fill the 30 GiB PVC at first
boot (cloud-init grows the rootfs).

## Pipeline shape

Just two tasks:

1. `upload-source-artefact` — pull qcow2 to `rocky-9-cloudimage` DV
   in `linux-image-build` (CDI converts qcow2 to raw inside the PVC).
2. `clone-to-catalog` — clone that PVC into
   `openshift-virtualization-os-images` as DataVolume + DataSource
   `rocky-9` with the appropriate labels.

No build VM, no shutdown wait, no cleanup of installer state.

The hardened sibling (Phase 3) will add a third task between the two:
boot the cloud image, run `oscap xccdf eval --remediate` against the
CIS L1 profile, shut down. Then clone.

## Deploy + run

```bash
source .env
oc config use-context prod   # or your prod context
oc apply -k manifests/linux/rocky-9/
oc create -f manifests/linux/rocky-9/pipelinerun.yaml
RUN=$(oc get pipelinerun -n linux-image-build \
  -o jsonpath='{.items[-1].metadata.name}')
tkn pipelinerun logs $RUN -n linux-image-build -f
```

## Expected runtime

10–20 min total — most of which is the qcow2 download.

## Catalogue output

- `DataSource` `rocky-9` in `openshift-virtualization-os-images`
- Labels: `default-instancetype: u1.medium`,
  `default-preference: centos.stream9`.

Consumer VMs that bind to this DataSource get a clean Rocky 9 install
with cloud-init waiting for first-boot userdata (set hostname, ssh
keys, network config, custom packages, etc).

## Known gotchas

- **No `rocky.9` cluster preference exists.** Using `centos.stream9`
  as the closest match. Upstream OpenShift Virt may add `rocky.9`
  later — update the `defaultPreference` param when it does.
- **First boot grows the rootfs.** The qcow2 is sized at ~10 GiB
  logical; CDI imports it into a 30 GiB PVC. Cloud-init's
  `growpart`/`resizefs` modules expand the rootfs to 30 GiB on first
  boot. If cloud-init isn't run (e.g., consumer VM has no userdata),
  the rootfs stays small.
- **`download.rockylinux.org` can be slow.** If the import takes
  >30 min, switch to `mirror.netcologne.de/rocky/9/images/x86_64/`.
