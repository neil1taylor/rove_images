# Creating a Windows Image with Tekton Pipelines

This tutorial walks through automating the Windows Server 2022 golden image build using Tekton Pipelines on OpenShift. The pipeline handles ISO uploads, VM creation, disk cloning, and cleanup automatically using inline task definitions.

For the manual step-by-step process, see [windows-image-manual.md](windows-image-manual.md). Understanding the manual process first is recommended -- the pipeline automates the same steps.

## Prerequisites

Everything from the manual tutorial, plus:

- [ ] OpenShift Pipelines operator installed on the cluster
- [ ] `tkn` CLI installed (optional but helpful for monitoring)
- [ ] Windows Server 2022 ISO and VirtIO ISO accessible via HTTP URL (e.g. in an IBM Cloud Object Storage bucket)

### Verify OpenShift Pipelines is installed

```bash
oc get csv -n openshift-operators | grep pipelines
```

You should see a ClusterServiceVersion with a phase of `Succeeded`.

### Verify OpenShift Virtualization is installed

```bash
oc get hyperconverged -n openshift-cnv
```

You should see the `kubevirt-hyperconverged` CR.

> **Note:** Earlier versions of OpenShift Virtualization shipped KubeVirt Tekton `ClusterTasks` (e.g. `modify-data-object`, `create-vm-from-manifest`). These were removed in Tekton v1.14+ and the `deployTektonTaskResources` feature gate on the HyperConverged CR is now deprecated and ignored. This pipeline uses inline `taskSpec` definitions with the `oc` CLI instead, so no external task dependencies are needed.

---

## Pipeline Overview

The pipeline has two modes:

1. **Semi-automated** -- the pipeline pauses after creating the installer VM so you can connect via VNC, install Windows, and run Sysprep. After the VM shuts down, the pipeline resumes automatically.
2. **Fully unattended** -- an `autounattend.xml` answer file handles the entire Windows install, driver loading, and Sysprep with no VNC session needed.

```
┌─────────────────┐     ┌─────────────────┐     ┌──────────────────┐
│  Upload Windows  │     │  Upload VirtIO   │     │  Create blank    │
│  ISO as DV       │     │  ISO as DV       │     │  root disk DV    │
└────────┬────────┘     └────────┬────────┘     └────────┬─────────┘
         │                       │                       │
         └───────────────────────┼───────────────────────┘
                                 │  (all three run in parallel)
                                 ▼
                        ┌──────────────────┐
                        │  Create installer │
                        │  VM (boots ISO)   │
                        └────────┬─────────┘
                                 │
                          ┌──────┴──────┐
                          │             │
                    Semi-automated  Fully unattended
                    (VNC install)   (autounattend.xml)
                          │             │
                          └──────┬──────┘
                                 ▼
                        ┌──────────────────┐
                        │  Wait for VM to   │
                        │  shut down         │
                        └────────┬─────────┘
                                 │
                                 ▼
                        ┌──────────────────┐
                        │  Clone root disk   │
                        │  to catalog NS     │
                        └────────┬─────────┘
                                 │
                                 ▼
                        ┌──────────────────┐
                        │  Cleanup build     │
                        │  resources         │
                        └──────────────────┘
```

---

## Step 1: Create a working namespace

```bash
oc new-project windows-image-build
```

---

## Step 2: Create the ServiceAccount and RBAC

The pipeline needs permission to create VMs, DataVolumes, and work across namespaces.

Save as `pipeline-rbac.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: windows-image-pipeline
  namespace: windows-image-build
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: windows-image-pipeline
rules:
  - apiGroups: ["kubevirt.io"]
    resources: ["virtualmachines", "virtualmachineinstances"]
    verbs: ["get", "list", "watch", "create", "delete", "update", "patch"]
  - apiGroups: ["cdi.kubevirt.io"]
    resources: ["datavolumes", "datasources"]
    verbs: ["get", "list", "watch", "create", "delete", "update", "patch"]
  - apiGroups: [""]
    resources: ["persistentvolumeclaims"]
    verbs: ["get", "list", "watch", "create", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: windows-image-pipeline
subjects:
  - kind: ServiceAccount
    name: windows-image-pipeline
    namespace: windows-image-build
roleRef:
  kind: ClusterRole
  name: windows-image-pipeline
  apiGroup: rbac.authorization.k8s.io
```

```bash
oc apply -f pipeline-rbac.yaml
```

---

## Step 3: Create the autounattend ConfigMap (fully unattended only)

For fully unattended builds, create the Windows answer file that drives the entire install.

Save as `Autounattend.xml` (the capital `A` matters -- KubeVirt's sysprep volume type and Windows Setup both look for this exact casing):

```xml
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">

  <!-- Install phase: partition disk and select image -->
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE"
               processorArchitecture="amd64" language="neutral"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <SetupUILanguage>
        <UILanguage>en-US</UILanguage>
      </SetupUILanguage>
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>

    <component name="Microsoft-Windows-Setup"
               processorArchitecture="amd64" language="neutral"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <!-- Load VirtIO drivers -- scan multiple drive letters since the
           letter varies depending on how many CDROMs are attached -->
      <DriverPaths>
        <PathAndCredentials wcm:action="add" wcm:keyValue="1">
          <Path>D:\viostor\2k22\amd64</Path>
        </PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="2">
          <Path>D:\NetKVM\2k22\amd64</Path>
        </PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="3">
          <Path>D:\Balloon\2k22\amd64</Path>
        </PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="4">
          <Path>E:\viostor\2k22\amd64</Path>
        </PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="5">
          <Path>E:\NetKVM\2k22\amd64</Path>
        </PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="6">
          <Path>E:\Balloon\2k22\amd64</Path>
        </PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="7">
          <Path>F:\viostor\2k22\amd64</Path>
        </PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="8">
          <Path>F:\NetKVM\2k22\amd64</Path>
        </PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="9">
          <Path>F:\Balloon\2k22\amd64</Path>
        </PathAndCredentials>
      </DriverPaths>

      <DiskConfiguration>
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add">
              <Order>1</Order>
              <Type>Primary</Type>
              <Extend>true</Extend>
            </CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add">
              <Order>1</Order>
              <PartitionID>1</PartitionID>
              <Format>NTFS</Format>
              <Label>Windows</Label>
              <Letter>C</Letter>
              <Active>true</Active>
            </ModifyPartition>
          </ModifyPartitions>
        </Disk>
      </DiskConfiguration>

      <ImageInstall>
        <OSImage>
          <InstallFrom>
            <MetaData wcm:action="add">
              <Key>/IMAGE/NAME</Key>
              <Value>Windows Server 2022 SERVERSTANDARD</Value>
            </MetaData>
          </InstallFrom>
          <InstallTo>
            <DiskID>0</DiskID>
            <PartitionID>1</PartitionID>
          </InstallTo>
        </OSImage>
      </ImageInstall>

      <UserData>
        <AcceptEula>true</AcceptEula>
      </UserData>
    </component>
  </settings>

  <!-- Post-install: set admin password, install guest tools, sysprep -->
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64" language="neutral"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <AdministratorPassword>
          <Value>P@ssw0rd!</Value>
          <PlainText>true</PlainText>
        </AdministratorPassword>
      </UserAccounts>
      <AutoLogon>
        <Enabled>true</Enabled>
        <Username>Administrator</Username>
        <Password>
          <Value>P@ssw0rd!</Value>
          <PlainText>true</PlainText>
        </Password>
        <LogonCount>1</LogonCount>
      </AutoLogon>
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <CommandLine>powershell -Command "foreach ($d in 'D','E','F') { $p = \"${d}:\virtio-win-gt-x64.msi\"; if (Test-Path $p) { Start-Process msiexec -ArgumentList '/i',$p,'/quiet','/norestart' -Wait; break } }"</CommandLine>
          <Description>Install VirtIO guest tools</Description>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>2</Order>
          <CommandLine>powershell -Command "foreach ($d in 'D','E','F') { $p = \"${d}:\virtio-win-guest-tools.exe\"; if (Test-Path $p) { Start-Process $p -ArgumentList '/install','/quiet','/norestart' -Wait; break } }"</CommandLine>
          <Description>Install QEMU guest agent</Description>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>3</Order>
          <CommandLine>C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown /mode:vm</CommandLine>
          <Description>Sysprep and shutdown</Description>
        </SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
```

> **Security note:** The password in the answer file is only used during the initial build and is wiped by Sysprep. Each VM cloned from the image will prompt for a new password during OOBE.

```bash
oc create configmap autounattend \
  --from-file=Autounattend.xml \
  --namespace=windows-image-build
```

> **Key detail:** KubeVirt has native support for the `sysprep` volume type. It mounts the ConfigMap as a virtual floppy/CDROM that Windows automatically detects and reads during installation. You do not need to manually place the XML file.

For semi-automated mode, skip this step -- the pipeline will pause for VNC access instead.

---

## Step 4: Create the pipeline

The pipeline uses inline `taskSpec` definitions. Each task runs the `oc` CLI from the cluster's built-in image to apply and wait on resources.

Save as `windows-image-pipeline.yaml`:

```yaml
apiVersion: tekton.dev/v1
kind: Pipeline
metadata:
  name: windows-image-builder
  namespace: windows-image-build
spec:
  params:
    - name: windowsIsoUrl
      description: URL to the Windows Server ISO (e.g. from COS bucket)
      type: string
    - name: virtioIsoUrl
      description: URL to the VirtIO drivers ISO
      type: string
    - name: storageClass
      description: Storage class for all PVCs
      type: string
      default: ocs-storagecluster-ceph-rbd-virtualization
    - name: goldenImageName
      description: Name for the golden image DataVolume in the catalog
      type: string
      default: windows-server-2022
    - name: rootDiskSize
      description: Size of the root disk
      type: string
      default: "60Gi"
  tasks:
    # ── Upload the Windows ISO ──────────────────────────────────────
    - name: upload-windows-iso
      taskSpec:
        params:
          - name: url
            type: string
          - name: storageClass
            type: string
        steps:
          - name: create-dv
            image: image-registry.openshift-image-registry.svc:5000/openshift/cli:latest
            script: |
              #!/bin/bash
              set -euo pipefail
              if oc wait datavolume/windows-server-2022-iso \
                -n windows-image-build \
                --for=condition=Ready \
                --timeout=5s 2>/dev/null; then
                echo "Windows ISO DataVolume already exists and is Ready -- skipping download"
                exit 0
              fi
              echo "Creating Windows ISO DataVolume..."
              cat <<DVEOF | oc apply -f -
              apiVersion: cdi.kubevirt.io/v1beta1
              kind: DataVolume
              metadata:
                name: windows-server-2022-iso
                namespace: windows-image-build
              spec:
                source:
                  http:
                    url: "$(params.url)"
                storage:
                  storageClassName: $(params.storageClass)
                  accessModes:
                    - ReadWriteMany
                  resources:
                    requests:
                      storage: 7Gi
              DVEOF
              echo "Waiting for DataVolume to complete..."
              oc wait datavolume/windows-server-2022-iso \
                -n windows-image-build \
                --for=condition=Ready \
                --timeout=60m
              echo "Windows ISO DataVolume ready"
      params:
        - name: url
          value: $(params.windowsIsoUrl)
        - name: storageClass
          value: $(params.storageClass)

    # ── Upload the VirtIO drivers ISO ───────────────────────────────
    - name: upload-virtio-iso
      taskSpec:
        params:
          - name: url
            type: string
          - name: storageClass
            type: string
        steps:
          - name: create-dv
            image: image-registry.openshift-image-registry.svc:5000/openshift/cli:latest
            script: |
              #!/bin/bash
              set -euo pipefail
              if oc wait datavolume/virtio-win-iso \
                -n windows-image-build \
                --for=condition=Ready \
                --timeout=5s 2>/dev/null; then
                echo "VirtIO ISO DataVolume already exists and is Ready -- skipping download"
                exit 0
              fi
              echo "Creating VirtIO ISO DataVolume..."
              cat <<DVEOF | oc apply -f -
              apiVersion: cdi.kubevirt.io/v1beta1
              kind: DataVolume
              metadata:
                name: virtio-win-iso
                namespace: windows-image-build
              spec:
                source:
                  http:
                    url: "$(params.url)"
                storage:
                  storageClassName: $(params.storageClass)
                  accessModes:
                    - ReadWriteMany
                  resources:
                    requests:
                      storage: 2Gi
              DVEOF
              echo "Waiting for DataVolume to complete..."
              oc wait datavolume/virtio-win-iso \
                -n windows-image-build \
                --for=condition=Ready \
                --timeout=60m
              echo "VirtIO ISO DataVolume ready"
      params:
        - name: url
          value: $(params.virtioIsoUrl)
        - name: storageClass
          value: $(params.storageClass)

    # ── Create blank root disk ──────────────────────────────────────
    - name: create-root-disk
      taskSpec:
        params:
          - name: storageClass
            type: string
          - name: rootDiskSize
            type: string
        steps:
          - name: create-dv
            image: image-registry.openshift-image-registry.svc:5000/openshift/cli:latest
            script: |
              #!/bin/bash
              set -euo pipefail
              cat <<DVEOF | oc apply -f -
              apiVersion: cdi.kubevirt.io/v1beta1
              kind: DataVolume
              metadata:
                name: windows-root-disk
                namespace: windows-image-build
              spec:
                source:
                  blank: {}
                storage:
                  storageClassName: $(params.storageClass)
                  accessModes:
                    - ReadWriteMany
                  resources:
                    requests:
                      storage: $(params.rootDiskSize)
              DVEOF
              echo "Waiting for DataVolume to complete..."
              oc wait datavolume/windows-root-disk \
                -n windows-image-build \
                --for=condition=Ready \
                --timeout=30m
              echo "Root disk DataVolume ready"
      params:
        - name: storageClass
          value: $(params.storageClass)
        - name: rootDiskSize
          value: $(params.rootDiskSize)

    # ── Create the installer VM ─────────────────────────────────────
    # The sysprep volume mounts the autounattend ConfigMap for fully
    # unattended install. For semi-automated mode, remove the sysprep
    # disk and volume entries and connect via VNC after the VM boots.
    - name: create-installer-vm
      runAfter:
        - upload-windows-iso
        - upload-virtio-iso
        - create-root-disk
      taskSpec:
        steps:
          - name: create-vm
            image: image-registry.openshift-image-registry.svc:5000/openshift/cli:latest
            script: |
              #!/bin/bash
              set -euo pipefail
              cat <<'VMEOF' | oc apply -f -
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
                          - name: sysprep
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
                        persistentVolumeClaim:
                          claimName: windows-root-disk
                      - name: windows-iso
                        persistentVolumeClaim:
                          claimName: windows-server-2022-iso
                      - name: virtio-drivers
                        persistentVolumeClaim:
                          claimName: virtio-win-iso
                      - name: sysprep
                        sysprep:
                          configMap:
                            name: autounattend
              VMEOF
              echo "Installer VM created and starting"

    # ── Wait for VM shutdown (after install + sysprep) ──────────────
    - name: wait-for-vm-shutdown
      runAfter:
        - create-installer-vm
      timeout: "4h"
      taskSpec:
        steps:
          - name: wait
            image: image-registry.openshift-image-registry.svc:5000/openshift/cli:latest
            timeout: "4h"
            script: |
              #!/bin/bash
              set -euo pipefail
              echo "Waiting for VMI windows-installer to reach Succeeded (shutdown)..."
              echo "This will take 30-90 minutes for unattended Windows install + Sysprep."
              while true; do
                PHASE=$(oc get vmi windows-installer -n windows-image-build \
                  -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
                echo "$(date): VMI phase = $PHASE"
                if [ "$PHASE" = "Succeeded" ]; then
                  echo "VM has shut down successfully (Sysprep complete)"
                  exit 0
                fi
                if [ "$PHASE" = "Failed" ]; then
                  echo "ERROR: VMI failed"
                  exit 1
                fi
                sleep 30
              done

    # ── Clone root disk to catalog namespace ────────────────────────
    - name: clone-to-catalog
      runAfter:
        - wait-for-vm-shutdown
      taskSpec:
        params:
          - name: goldenImageName
            type: string
          - name: storageClass
            type: string
          - name: rootDiskSize
            type: string
        steps:
          - name: clone
            image: image-registry.openshift-image-registry.svc:5000/openshift/cli:latest
            script: |
              #!/bin/bash
              set -euo pipefail
              cat <<DVEOF | oc apply -f -
              apiVersion: cdi.kubevirt.io/v1beta1
              kind: DataVolume
              metadata:
                name: $(params.goldenImageName)
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
                  storageClassName: $(params.storageClass)
                  accessModes:
                    - ReadWriteMany
                  resources:
                    requests:
                      storage: $(params.rootDiskSize)
              DVEOF
              echo "Waiting for clone to complete..."
              oc wait datavolume/$(params.goldenImageName) \
                -n openshift-virtualization-os-images \
                --for=condition=Ready \
                --timeout=60m
              echo "Golden image cloned successfully"
      params:
        - name: goldenImageName
          value: $(params.goldenImageName)
        - name: storageClass
          value: $(params.storageClass)
        - name: rootDiskSize
          value: $(params.rootDiskSize)

    # ── Cleanup build resources ─────────────────────────────────────
    - name: cleanup
      runAfter:
        - clone-to-catalog
      taskSpec:
        steps:
          - name: cleanup
            image: image-registry.openshift-image-registry.svc:5000/openshift/cli:latest
            script: |
              #!/bin/bash
              set -euo pipefail
              echo "Cleaning up build resources..."
              oc delete vm windows-installer -n windows-image-build --ignore-not-found
              oc delete dv windows-root-disk -n windows-image-build --ignore-not-found
              echo "Cleanup complete (ISO DataVolumes retained for future runs)"
```

```bash
oc apply -f windows-image-pipeline.yaml
```

---

## Step 5: Run the pipeline

Save as `windows-image-pipelinerun.yaml`:

```yaml
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: windows-image-build-
  namespace: windows-image-build
spec:
  pipelineRef:
    name: windows-image-builder
  taskRunTemplate:
    serviceAccountName: windows-image-pipeline
  timeouts:
    pipeline: "5h"
    tasks: "4h30m"
  params:
    - name: windowsIsoUrl
      value: "https://go.microsoft.com/fwlink/p/?LinkID=2195280&clcid=0x409&culture=en-us&country=US"
    - name: virtioIsoUrl
      value: "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
    - name: storageClass
      value: "ocs-storagecluster-ceph-rbd-virtualization"
    - name: goldenImageName
      value: "windows-server-2022"
    - name: rootDiskSize
      value: "60Gi"
```

```bash
oc create -f windows-image-pipelinerun.yaml
```

> **Note:** We use `oc create` (not `oc apply`) because `generateName` creates a unique name each run. For semi-automated mode (VNC), remove the `sysprep` disk and volume from the pipeline's `create-installer-vm` task before applying.

---

## Step 6: Monitor the pipeline

### From the CLI

```bash
# Watch pipeline progress
oc get pipelinerun -n windows-image-build -w

# Stream logs (requires tkn CLI)
tkn pipelinerun logs -f -n windows-image-build
```

### From the OpenShift Console

1. Navigate to **Pipelines > Pipelines** in the OpenShift console.
2. Select the `windows-image-build` namespace.
3. Click on the `windows-image-builder` pipeline to see run history.
4. Click on a specific run to see the task graph and logs.

---

## Step 7: Complete the Windows install via VNC (semi-automated only)

If running in semi-automated mode (`unattended: "false"`), the pipeline pauses at the `wait-for-vm-shutdown` task. Connect via VNC to install Windows and run Sysprep.

```bash
virtctl vnc windows-installer -n windows-image-build
```

Follow the Windows installation steps from the [manual tutorial](windows-image-manual.md#step-5-install-windows), including:

1. Install Windows from the ISO
2. Load VirtIO drivers when prompted
3. Install VirtIO guest tools after first boot
4. Install Windows Updates
5. Run Sysprep with `/generalize /oobe /shutdown /mode:vm`

After the VM shuts down from Sysprep, the pipeline automatically resumes and completes the clone and cleanup steps.

For fully unattended mode, this step is skipped entirely.

---

## Step 8: Verify the result

```bash
# Check the golden image exists in the catalog namespace
oc get dv -n openshift-virtualization-os-images | grep windows

# Check it appears in the Virtualization > Catalog page in the console
```

---

## Storage Class Selection

The pipeline defaults to `ocs-storagecluster-ceph-rbd-virtualization`, the CNV-optimized Ceph RBD storage class. If your cluster does not have this class, check what is available:

```bash
oc get sc | grep -E "rbd|virtualization"
```

Common options:
- `ocs-storagecluster-ceph-rbd-virtualization` -- CNV-optimized, preferred when available
- `ocs-storagecluster-ceph-rbd` -- standard Ceph RBD, works but lacks CNV tuning

---

## Things to Watch Out For

- **ConfigMap key casing:** The ConfigMap key **must** be `Autounattend.xml` (capital A). KubeVirt's sysprep volume type and Windows Setup both require this exact casing. Using `autounattend.xml` (lowercase) will silently fail -- the VM boots to the manual installer with no error.
- **VirtIO CDROM drive letter:** The answer file scans drives D: through F: for VirtIO drivers. If your disk configuration differs significantly, connect via VNC to check the actual drive letters and update the XML.
- **Windows image name:** The `Value` in `ImageInstall` must match the exact edition name in the ISO. Common values:
  - `Windows Server 2022 SERVERSTANDARD` (Standard with Desktop Experience)
  - `Windows Server 2022 SERVERSTANDARDCORE` (Standard Core, no GUI)
  - `Windows Server 2022 SERVERDATACENTER` (Datacenter with Desktop Experience)
- **Timeout:** The 4-hour timeout on `wait-for-vm-shutdown` should be sufficient for an unattended install, but Windows Updates can be unpredictable. If the answer file includes an update step, increase the timeout.

---

## Scheduling Recurring Builds

To rebuild the golden image regularly (e.g. to pick up Windows Updates), use a CronJob to trigger the pipeline:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: monthly-windows-image-build
  namespace: windows-image-build
spec:
  schedule: "0 2 1 * *"  # 2 AM on the 1st of each month
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: windows-image-pipeline
          containers:
            - name: trigger
              image: registry.redhat.io/openshift-pipelines/pipelines-cli-tkn-rhel8:latest
              command:
                - tkn
              args:
                - pipeline
                - start
                - windows-image-builder
                - --param=windowsIsoUrl=https://go.microsoft.com/fwlink/p/?LinkID=2195280&clcid=0x409&culture=en-us&country=US
                - --param=virtioIsoUrl=https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso
                - --namespace=windows-image-build
                - --serviceaccount=windows-image-pipeline
          restartPolicy: Never
```

> **Tip:** For recurring builds, the unattended pipeline is essential -- you do not want a CronJob waiting for someone to VNC in.

---

## Troubleshooting

### Pipeline task fails

```bash
# Get the PipelineRun name
oc get pipelinerun -n windows-image-build

# See which task failed and why
tkn pipelinerun describe <run-name> -n windows-image-build

# Get logs for a specific task
tkn taskrun logs <taskrun-name> -n windows-image-build
```

Common causes:
- **ServiceAccount missing permissions.** Check the ClusterRoleBinding is applied.
- **Task pod cannot pull CLI image.** Verify the internal registry is accessible: `oc get is cli -n openshift`.
- **Timeout on `wait-for-vm-shutdown`.** The default is 4 hours. If Windows install + updates take longer, increase the `timeout` on that task.

### ISO download fails in the pipeline

```bash
oc describe dv windows-server-2022-iso -n windows-image-build
```

Common causes:
- URL is not publicly accessible or requires authentication. For private COS buckets, you may need to use a pre-signed URL or configure CDI with credentials.
- TLS certificate issues. Try adding `certConfigMap` to the DataVolume's HTTP source if using a private registry with self-signed certs.

### Unattended install does not start

Connect via VNC to see what is happening:

```bash
virtctl vnc windows-installer -n windows-image-build
```

Common causes:
- The `autounattend.xml` is not being detected. Verify the ConfigMap was created and the `sysprep` volume is correctly mounted.
- Driver path is wrong. Check the actual drive letter of the VirtIO CDROM.
- Image name mismatch. The `Value` in `ImageInstall` must exactly match the edition in the ISO.

### Pipeline hangs at wait-for-vm-shutdown

The VM may still be running (installing updates, waiting at a prompt, etc.):

```bash
# Check if the VMI is still running
oc get vmi windows-installer -n windows-image-build

# Connect via VNC to see what's happening
virtctl vnc windows-installer -n windows-image-build
```

If the VM is stuck at a prompt, the answer file is incomplete. Fix the XML and re-run.

### Clone to catalog namespace fails

```bash
oc describe dv windows-server-2022 -n openshift-virtualization-os-images
```

Common causes:
- Source PVC does not exist (check the namespace and name match exactly).
- Cross-namespace cloning is not enabled. Check CDI configuration.
- Insufficient storage quota in the target namespace.

---

## Quick Reference

| What | Command |
|------|---------|
| Apply pipeline | `oc apply -f windows-image-pipeline.yaml` |
| Start a run | `oc create -f windows-image-pipelinerun.yaml` |
| Watch progress | `oc get pipelinerun -n windows-image-build -w` |
| Stream logs | `tkn pipelinerun logs -f -n windows-image-build` |
| Connect to installer VM | `virtctl vnc windows-installer -n windows-image-build` |
| Check golden image | `oc get dv -n openshift-virtualization-os-images` |
| Cancel a run | `tkn pipelinerun cancel <run-name> -n windows-image-build` |
