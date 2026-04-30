# Rocky Linux 9 — vanilla golden image pipeline (Phase 2 pilot)

Builds a Rocky Linux 9 golden image from the public Rocky boot ISO and
publishes it as DataSource `rocky-9` in `openshift-virtualization-os-images`.

**Why Rocky 9 for the pilot:** The original PRD nominated RHEL 9 for
the Phase 2 pilot. RHEL's boot ISO requires a Red Hat entitlement
certificate to access install-time package repos, and we don't have
the cert plumbing in the cluster yet. Rocky 9 has the same RHEL 9
family kernel/userland and uses Anaconda + kickstart identically, so
it proves the pipeline pattern without the entitlement dependency.

RHEL 9 (and 8, plus AlmaLinux 8/9) are still in the matrix for Batch
2 — they'll use the DVD ISO (~10 GB, packages embedded, no network
repo needed) when their pipelines land.

## ISO source

Public Rocky mirror — `https://download.rockylinux.org/pub/rocky/9/isos/x86_64/`.
The `Rocky-9-latest-x86_64-boot.iso` is a permalink the Rocky project
maintains pointing to the latest 9.x point release. No authentication.

## Deploy + run

```bash
source .env
oc config use-context prod  # or your prod context
oc apply -k manifests/linux/rocky-9/
oc create -f manifests/linux/rocky-9/pipelinerun.yaml
RUN=$(oc get pipelinerun -n linux-image-build \
  -o jsonpath='{.items[-1].metadata.name}')
tkn pipelinerun logs $RUN -n linux-image-build -f
```

## Expected runtime

20–40 min — boot ISO is ~1 GB so upload is fast, then Anaconda fetches
~500 MB of packages from the Rocky mirror during install.

## Catalogue output

- `DataSource` `rocky-9` in `openshift-virtualization-os-images`
- Labels: `default-instancetype: u1.medium`,
  `default-preference: centos.stream9` (no native rocky preference;
  `centos.stream9` is the same RHEL 9 family).

## Known gotchas

- **`rocky.9` preference doesn't exist on the cluster.** Using
  `centos.stream9` as the closest match. If a `rocky.9`
  VirtualMachineClusterPreference is added later, update the
  `defaultPreference` param.
- **Cloud-user password is plaintext** in the kickstart for pilot
  simplicity (`cloud-user / changeme123!`). Real estates should rotate
  this via cloud-init at consumer-VM deployment time.
- **Public mirror availability**: if `download.rockylinux.org` is
  unreachable from inside the cluster, swap to a closer mirror (e.g.
  `mirror.cs.uu.nl/rocky/`, `mirror.netcologne.de/rocky/`).
