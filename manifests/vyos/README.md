# VyOS rolling — network appliance golden image pipeline

Builds a VyOS rolling release golden image from the nightly ISO and
publishes it as DataSource `vyos-rolling` in `openshift-virtualization-os-images`.

Includes a lightweight NoCloud first-boot service (`vyos-nocloud-init`)
that reads `vyos_config_commands` from KubeVirt's `cloudInitNoCloud`
userdata and applies them via the VyOS configuration system on first
boot. This replaces upstream cloud-init, which is not included in the
VyOS rolling ISO.

## ISO source

VyOS nightly builds — `https://github.com/vyos/vyos-nightly-build/releases`.
Only the generic amd64 ISO is published; no cloud images (qcow2) are
available for the rolling release. Update the `vyosIsoUrl` parameter in
`pipelinerun.yaml` to point at the desired nightly build date.

## Deploy + run

```bash
source .env
ibmcloud oc cluster config --cluster nrt-prod-cluster1 --admin
oc new-project vyos-image-build  # first time only
oc apply -f manifests/vyos/pipeline/pipeline-rbac.yaml
oc apply -f manifests/vyos/pipeline/pipeline.yaml
oc apply -f manifests/vyos/instancetype.yaml
oc apply -f manifests/vyos/preference.yaml
oc create -f manifests/vyos/pipeline/pipelinerun.yaml
RUN=$(oc get pipelinerun -n vyos-image-build \
  -o jsonpath='{.items[-1].metadata.name}')
tkn pipelinerun logs $RUN -n vyos-image-build -f
```

## Expected runtime

5-8 min (with cached ISO). First run adds ~3 min for ISO download
(628 MB). VyOS installs in under 2 minutes.

## Catalogue output

- `DataSource` `vyos-rolling` in `openshift-virtualization-os-images`
- Labels: `default-instancetype: vyos-appliance`,
  `default-preference: vyos-rolling`

## Consumer VM example

```yaml
volumes:
  - name: cloudinitdisk
    cloudInitNoCloud:
      userData: |
        #cloud-config
        vyos_config_commands:
          - set system host-name edge-router-01
          - set service ssh port 22
          - set interfaces ethernet eth0 address dhcp
          - set system name-server 8.8.8.8
```

See `consumer-vm.yaml` for a complete example.

## How the install automation works

VyOS's `install image` is an interactive command. The pipeline
automates it via serial console:

1. **Login** — waits for the `login:` prompt, sends `vyos/vyos`
2. **Install** — runs `printf "y\n\nS\n\ny\n\n\n" | install image`
   which pipes answers to stdin prompts (continue, image name, serial
   console, disk, wipe confirm, partition size, boot config). Passwords
   are sent interactively via serial since they read from `/dev/tty`.
3. **Inject** — mounts the persistence partition (`vda3`), writes the
   `vyos-nocloud-init` script and systemd service into the overlay
   upperdir via base64-encoded blobs
4. **Seal** — removes SSH host keys and truncates `machine-id`
5. **Stop** — patches VM `runStrategy` to `Halted`

## Known gotchas

- **Serial console required.** The pipeline uses serial console
  automation (`oc exec` into the virt-launcher pod). This requires the
  `privileged` SCC on the pipeline ServiceAccount.
- **`install image` prompt sequence may vary.** Tested with VyOS
  `2026.04.13-0034-rolling`. If a future build changes the prompts,
  the `printf` answer string in the pipeline may need updating.
- **First-boot service runs as root.** The `vyos-nocloud-init` service
  uses `sg vyattacfg` to apply config commands. It runs once and
  creates a marker file (`/var/lib/vyos-nocloud-init.done`).
- **ISO caching.** The `vyos-rolling-iso` DataVolume is retained
  between runs. Delete it to force a fresh ISO download.
