# Creating a Windows Image in the ROKS-Virt Catalog (Manual)

This tutorial walks through manually creating a Windows Server 2022 golden image for OpenShift Virtualization on ROKS. By the end, you will have a reusable Windows image available in the cluster catalog that any team member can use to spin up new VMs.

If you want to automate this with Tekton Pipelines instead, see [windows-image-pipeline.md](windows-image-pipeline.md).

## Prerequisites

Before you begin, make sure you have the following:

- [ ] Access to an IBM Cloud ROKS cluster with OpenShift Virtualization enabled
- [ ] `oc` CLI installed and authenticated to the cluster
- [ ] `virtctl` CLI installed ([download from your cluster's console](https://docs.openshift.com/container-platform/latest/virt/install/virt-installing-virtctl.html))
- [ ] A Windows Server 2022 evaluation ISO ([download from Microsoft](https://www.microsoft.com/en-us/evalcenter/evaluate-windows-server-2022))
- [ ] The VirtIO drivers ISO ([download from Fedora](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso))
- [ ] A VNC client (or use `virtctl vnc` which opens one for you)

### Verify your tools

```bash
oc version
virtctl version
oc whoami
```

All three commands should return without errors. If `virtctl` is not found, install it:

```bash
# Download from your cluster's ConsoleCLIDownload resource
oc get ConsoleCLIDownload virtctl-clidownloads-kubevirt-hyperconverged -o yaml
```

### Verify OpenShift Virtualization is running

```bash
oc get csv -n openshift-cnv | grep kubevirt
```

You should see a ClusterServiceVersion with a phase of `Succeeded`.

---

## Step 1: Create a working namespace

Create a namespace to do the image-building work in. You will delete this namespace when you are done.

```bash
oc new-project windows-image-build
```

---

## Step 2: Upload the Windows ISO

Upload the Windows Server 2022 ISO to the cluster as a DataVolume. This makes it available as a virtual CDROM drive.

```bash
virtctl image-upload dv windows-server-2022-iso \
  --size=7Gi \
  --image-path=./windows-server-2022.iso \
  --namespace=windows-image-build \
  --storage-class=ocs-storagecluster-ceph-rbd-virtualization \
  --access-mode=ReadWriteMany \
  --insecure
```

> **Note:** Replace `ocs-storagecluster-ceph-rbd-virtualization` with your cluster's storage class. Run `oc get storageclass` to see what is available.

Wait for the upload to finish. You can check progress with:

```bash
oc get dv windows-server-2022-iso -n windows-image-build -w
```

The status should reach `Succeeded`.

---

## Step 3: Upload the VirtIO drivers ISO

Windows does not include drivers for the virtual hardware that KubeVirt uses. You need to attach the VirtIO drivers ISO during installation.

```bash
virtctl image-upload dv virtio-win-iso \
  --size=2Gi \
  --image-path=./virtio-win.iso \
  --namespace=windows-image-build \
  --storage-class=ocs-storagecluster-ceph-rbd-virtualization \
  --access-mode=ReadWriteMany \
  --insecure
```

Verify it completed:

```bash
oc get dv virtio-win-iso -n windows-image-build
```

---

## Step 4: Create the installer VM

Save the following as `windows-installer-vm.yaml`:

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: windows-installer
  namespace: windows-image-build
spec:
  running: true
  template:
    metadata:
      labels:
        kubevirt.io/vm: windows-installer
    spec:
      domain:
        cpu:
          cores: 4
        resources:
          requests:
            memory: 8Gi
        clock:
          utc: {}
          timer:
            hpet:
              present: false
            hyperv: {}
            pit:
              tickPolicy: delay
            rtc:
              tickPolicy: catchup
        features:
          acpi: {}
          apic: {}
          hyperv:
            spinlocks:
              spinlocks: 8191
            vapic: {}
            relaxed: {}
        devices:
          disks:
            - name: rootdisk
              disk:
                bus: virtio
              bootOrder: 2
            - name: windows-iso
              cdrom:
                bus: sata
              bootOrder: 1
            - name: virtio-drivers
              cdrom:
                bus: sata
          interfaces:
            - name: default
              masquerade: {}
      networks:
        - name: default
          pod: {}
      volumes:
        - name: rootdisk
          dataVolume:
            name: windows-root-disk
        - name: windows-iso
          dataVolume:
            name: windows-server-2022-iso
        - name: virtio-drivers
          dataVolume:
            name: virtio-win-iso
  dataVolumeTemplates:
    - metadata:
        name: windows-root-disk
      spec:
        storage:
          storageClassName: ocs-storagecluster-ceph-rbd-virtualization
          accessModes:
            - ReadWriteMany
          resources:
            requests:
              storage: 60Gi
        source:
          blank: {}
```

Apply it:

```bash
oc apply -f windows-installer-vm.yaml
```

Watch the VM come up:

```bash
oc get vm windows-installer -n windows-image-build -w
```

Wait until the `READY` column shows `True`.

---

## Step 5: Install Windows

### Connect to the VM console

```bash
virtctl vnc windows-installer -n windows-image-build
```

This opens a VNC window to the VM. You should see the Windows installer booting from the ISO.

### Walk through the installer

1. Select your language and keyboard layout, then click **Install now**.
2. Choose **Windows Server 2022 Standard (Desktop Experience)**.
3. Accept the license terms.
4. Choose **Custom: Install Windows only (advanced)**.

### Load the VirtIO storage driver

At this point you will see **no disks listed**. This is expected -- Windows does not have the VirtIO driver yet.

1. Click **Load driver**.
2. Click **Browse**.
3. Navigate to the second CDROM drive (the VirtIO ISO).
4. Browse to `viostor\2k22\amd64` (or `2k19` for Server 2019).
5. Select the driver and click **Next**.
6. The 60 GB disk should now appear. Select it and click **Next**.

Windows will now install. This takes 10-20 minutes. The VM will reboot several times.

### After Windows boots

Once you reach the Windows desktop:

1. **Open Device Manager** and check for any devices with missing drivers (yellow triangle icons).
2. **Install remaining VirtIO drivers:**
   - Open the VirtIO CDROM drive in File Explorer.
   - Run `virtio-win-gt-x64.msi` to install all guest drivers.
   - Run `virtio-win-guest-tools` installer to get the QEMU guest agent.
3. **Verify networking** -- open a browser or run `ipconfig` in PowerShell to confirm the VM has network connectivity.
4. **Install Windows Updates** -- open Settings > Windows Update and install all available updates. Reboot as needed.

---

## Step 6: Prepare the image with Sysprep

Sysprep removes machine-specific data (hostname, SID, activation) so the image can be cloned safely.

1. Open PowerShell as Administrator in the VM.
2. Run:

```powershell
# Remove any temporary files to reduce image size
Remove-Item -Path "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "C:\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue

# Clear the event logs
wevtutil el | ForEach-Object { wevtutil cl $_ }

# Run Sysprep
C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown /mode:vm
```

> **Important:** The `/shutdown` flag tells Sysprep to power off the VM when it finishes. Do NOT boot the VM again after this point -- the next boot will trigger the Out-of-Box Experience (OOBE) setup, which should happen on the cloned VM, not the template.

3. Wait for the VM to shut down. Verify it is stopped:

```bash
oc get vmi -n windows-image-build
```

The VirtualMachineInstance should no longer be listed (or show a stopped state).

Stop the VM object so it does not restart:

```bash
virtctl stop windows-installer -n windows-image-build
```

---

## Step 7: Clone the disk to the catalog namespace

The golden image needs to live in the `openshift-virtualization-os-images` namespace. This is where the ROKS-virt catalog looks for boot sources.

Save the following as `golden-image-dv.yaml`:

```yaml
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: win2k22
  namespace: openshift-virtualization-os-images
  labels:
    instancetype.kubevirt.io/default-instancetype: u1.2xlarge
    instancetype.kubevirt.io/default-preference: windows.2k22
spec:
  source:
    pvc:
      name: windows-root-disk
      namespace: windows-image-build
  storage:
    storageClassName: ocs-storagecluster-ceph-rbd-virtualization
    accessModes:
      - ReadWriteMany
    resources:
      requests:
        storage: 60Gi
```

Apply it:

```bash
oc apply -f golden-image-dv.yaml
```

Watch the clone progress:

```bash
oc get dv win2k22 -n openshift-virtualization-os-images -w
```

This will take several minutes depending on disk size. Wait for `Succeeded`.

### What the labels mean

| Label | Purpose |
|-------|---------|
| `instancetype.kubevirt.io/default-instancetype` | Sets the default VM size when creating from this image (CPU, memory) |
| `instancetype.kubevirt.io/default-preference` | Tells the catalog which OS-specific settings to apply (clock, drivers, firmware) |

To see available instance types and preferences:

```bash
oc get virtualmachineclusterinstancetypes
oc get virtualmachineclusterpreferences
```

---

## Step 8: Verify the image appears in the catalog

### From the CLI

```bash
oc get datavolumes -n openshift-virtualization-os-images | grep windows
```

You should see `win2k22` with a status of `Succeeded`. This name matches the DataSource managed by the SSP operator, so the image will appear in the Virtualization catalog automatically.

### From the OpenShift Console

1. Open the OpenShift web console.
2. Navigate to **Virtualization > Catalog**.
3. You should see a **Windows Server 2022** tile.
4. Click it to verify you can start the VM creation wizard.

---

## Step 9: Test the image

Create a test VM from the catalog to make sure everything works.

```bash
virtctl create vm \
  --name=windows-test-vm \
  --instancetype=u1.2xlarge \
  --preference=windows.2k22 \
  --volume-clone-pvc=src:openshift-virtualization-os-images/win2k22 \
  --namespace=windows-image-build | oc apply -f -
```

Connect to it:

```bash
virtctl vnc windows-test-vm -n windows-image-build
```

If the golden image includes cloudbase-init (see [windows-image-pipeline.md](windows-image-pipeline.md)), you should see the Windows lock screen -- cloudbase-init handles first-boot setup automatically, just like cloud-init on RHEL images. If cloudbase-init is not installed, you will see the Windows OOBE setup screen instead. Either way, this confirms the image was sysprepped correctly and boots from a clone.

After verifying, clean up the test VM:

```bash
oc delete vm windows-test-vm -n windows-image-build
```

---

## Step 10: Clean up the build namespace

Once the golden image is confirmed working, delete the build namespace to free up storage:

```bash
oc delete project windows-image-build
```

This removes the installer VM, the uploaded ISOs, and the source root disk. The golden image in `openshift-virtualization-os-images` is not affected.

---

## Troubleshooting

### Upload hangs or fails

```bash
# Check CDI upload proxy is running
oc get pods -n openshift-cnv | grep cdi-uploadproxy

# Check the DataVolume events for errors
oc describe dv <name> -n windows-image-build
```

Common causes:
- Storage class does not support the requested access mode. Try `ReadWriteOnce` instead of `ReadWriteMany`.
- Not enough storage quota in the namespace.
- CDI upload proxy is not exposed or has TLS issues (try `--insecure` flag).

### VM does not boot

```bash
# Check the VMI events
oc describe vmi windows-installer -n windows-image-build

# Check the virt-launcher pod logs
oc logs -n windows-image-build $(oc get pods -n windows-image-build -l kubevirt.io/vm=windows-installer -o name)
```

Common causes:
- Not enough memory or CPU available on the worker nodes.
- Storage class does not support block volumes.

### No disks visible during Windows install

You forgot to load the VirtIO storage driver. Go back to Step 5 and follow the "Load driver" instructions.

### Cloning the disk fails

```bash
oc describe dv win2k22 -n openshift-virtualization-os-images
```

Common causes:
- Source PVC does not exist (check the namespace and name match exactly).
- Cross-namespace cloning is not enabled. Check that CDI has the `HonorWaitForFirstConsumer` feature gate enabled.

### Image does not appear in the catalog

- Verify the DataVolume is in the `openshift-virtualization-os-images` namespace (not your build namespace).
- Verify the labels are set correctly. The preference label must match an existing `VirtualMachineClusterPreference`.
- Check available preferences: `oc get virtualmachineclusterpreferences | grep windows`.

---

## Quick Reference

| What | Command |
|------|---------|
| List storage classes | `oc get storageclass` |
| List instance types | `oc get virtualmachineclusterinstancetypes` |
| List OS preferences | `oc get virtualmachineclusterpreferences` |
| List catalog images | `oc get dv -n openshift-virtualization-os-images` |
| Connect to VM console | `virtctl vnc <vm-name> -n <namespace>` |
| Start a VM | `virtctl start <vm-name> -n <namespace>` |
| Stop a VM | `virtctl stop <vm-name> -n <namespace>` |
| Check DataVolume status | `oc get dv <name> -n <namespace> -w` |
