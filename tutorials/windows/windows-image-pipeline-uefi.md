# Creating a UEFI Windows Image with Tekton Pipelines

This tutorial walks through automating a **UEFI-bootable** Windows Server 2022 golden image build using Tekton Pipelines on OpenShift. The pipeline handles ISO uploads, VM creation, disk cloning, and cleanup automatically using inline task definitions.

This is the UEFI variant of the pipeline. The resulting golden image uses GPT partitioning with an EFI System Partition, matching the `preferredUseEfi: true` and `preferredUseSecureBoot: true` settings in `preference.yaml`. For the BIOS/MBR variant, see [windows-image-pipeline.md](windows-image-pipeline.md).

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
2. **Fully unattended** -- an `Autounattend.xml` answer file handles the entire Windows install, driver loading, and Sysprep with no VNC session needed.

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
                        │  VM (UEFI boot)   │
                        └────────┬─────────┘
                                 │
                                 ▼
                        ┌──────────────────┐
                        │  Trigger CD boot   │
                        │  (send keypress)   │
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
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list"]
  - apiGroups: [""]
    resources: ["pods/exec"]
    verbs: ["create"]
  - apiGroups: ["cdi.kubevirt.io"]
    resources: ["datavolumes/source"]
    verbs: ["create"]
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

## Step 3: Create the Autounattend ConfigMap (fully unattended only)

For fully unattended builds, create the Windows answer file that drives the entire install. This version uses a **UEFI/GPT partition layout** with an EFI System Partition, an MSR partition, and the Windows partition.

Save as `Autounattend.xml` (the capital `A` matters -- KubeVirt's sysprep volume type and Windows Setup both require this exact casing):

```xml
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <SetupUILanguage>
        <UILanguage>en-US</UILanguage>
      </SetupUILanguage>
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>

    <!-- VirtIO drivers must be under PnpCustomizationsWinPE, not Microsoft-Windows-Setup.
         Scan D: through F: because the drive letter varies with the number of CDROMs attached.
         EFI and MSR partitions do not receive drive letters, so CDROM letters are unchanged. -->
    <component name="Microsoft-Windows-PnpCustomizationsWinPE" processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
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
    </component>

    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <DiskConfiguration>
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <!-- EFI System Partition: FAT32, holds the UEFI bootloader -->
            <CreatePartition wcm:action="add">
              <Order>1</Order>
              <Size>500</Size>
              <Type>EFI</Type>
            </CreatePartition>
            <!-- Microsoft Reserved Partition: required for GPT disks -->
            <CreatePartition wcm:action="add">
              <Order>2</Order>
              <Size>16</Size>
              <Type>MSR</Type>
            </CreatePartition>
            <!-- Windows partition: fills remaining disk -->
            <CreatePartition wcm:action="add">
              <Order>3</Order>
              <Extend>true</Extend>
              <Type>Primary</Type>
            </CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add">
              <Order>1</Order>
              <PartitionID>1</PartitionID>
              <Format>FAT32</Format>
              <Label>EFI</Label>
            </ModifyPartition>
            <!-- MSR partition (PartitionID 2) cannot be formatted or assigned a letter -->
            <ModifyPartition wcm:action="add">
              <Order>2</Order>
              <PartitionID>3</PartitionID>
              <Format>NTFS</Format>
              <Label>Windows</Label>
              <Letter>C</Letter>
            </ModifyPartition>
          </ModifyPartitions>
        </Disk>
      </DiskConfiguration>

      <!-- Use image index instead of name -- works for both retail and evaluation ISOs.
           Index 1 = Standard Core, 2 = Standard Desktop,
           3 = Datacenter Core, 4 = Datacenter Desktop. -->
      <ImageInstall>
        <OSImage>
          <InstallFrom>
            <MetaData wcm:action="add">
              <Key>/IMAGE/INDEX</Key>
              <Value>2</Value>
            </MetaData>
          </InstallFrom>
          <InstallTo>
            <DiskID>0</DiskID>
            <PartitionID>3</PartitionID>
          </InstallTo>
        </OSImage>
      </ImageInstall>

      <UserData>
        <AcceptEula>true</AcceptEula>
      </UserData>
    </component>
  </settings>

  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <ComputerName>WinTemplate</ComputerName>
    </component>
  </settings>

  <!-- Post-install: set admin password, install guest tools, sysprep -->
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
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
        <!-- Use "cmd /c if exist" guards so commands that target the wrong drive letter
             are silently skipped instead of failing and blocking subsequent commands. -->
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <CommandLine>cmd /c if exist D:\virtio-win-gt-x64.msi msiexec /i D:\virtio-win-gt-x64.msi /quiet /norestart</CommandLine>
          <Description>Install VirtIO guest tools from D</Description>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>2</Order>
          <CommandLine>cmd /c if exist E:\virtio-win-gt-x64.msi msiexec /i E:\virtio-win-gt-x64.msi /quiet /norestart</CommandLine>
          <Description>Install VirtIO guest tools from E</Description>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>3</Order>
          <CommandLine>cmd /c if exist D:\virtio-win-guest-tools.exe D:\virtio-win-guest-tools.exe /install /quiet /norestart</CommandLine>
          <Description>Install QEMU guest agent from D</Description>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>4</Order>
          <CommandLine>cmd /c if exist E:\virtio-win-guest-tools.exe E:\virtio-win-guest-tools.exe /install /quiet /norestart</CommandLine>
          <Description>Install QEMU guest agent from E</Description>
        </SynchronousCommand>
        <!-- Install cloudbase-init so cloned VMs skip OOBE and boot straight
             to the login screen, just like RHEL cloud images. -->
        <SynchronousCommand wcm:action="add">
          <Order>5</Order>
          <CommandLine>powershell -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri 'https://cloudbase.it/downloads/CloudbaseInitSetup_Stable_x64.msi' -OutFile 'C:\CloudbaseInitSetup.msi'"</CommandLine>
          <Description>Download cloudbase-init</Description>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>6</Order>
          <CommandLine>cmd /c msiexec /i C:\CloudbaseInitSetup.msi /quiet /norestart RUN_SERVICE_AS_LOCAL_SYSTEM=1 LOGGINGSERIALPORTNAME=COM1</CommandLine>
          <Description>Install cloudbase-init</Description>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>7</Order>
          <CommandLine>powershell -Command "Add-Content 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\cloudbase-init.conf' \"`nmetadata_services=cloudbaseinit.metadata.services.configdrive.ConfigDriveService`nplugins=cloudbaseinit.plugins.common.sethostname.SetHostNamePlugin,cloudbaseinit.plugins.windows.createuser.CreateUserPlugin,cloudbaseinit.plugins.common.setuserpassword.SetUserPasswordPlugin,cloudbaseinit.plugins.common.localscripts.LocalScriptsPlugin,cloudbaseinit.plugins.windows.extendvolumes.ExtendVolumesPlugin,cloudbaseinit.plugins.common.userdata.UserDataPlugin\""</CommandLine>
          <Description>Configure cloudbase-init for ConfigDrive metadata</Description>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>8</Order>
          <CommandLine>cmd /c del C:\CloudbaseInitSetup.msi</CommandLine>
          <Description>Clean up installer</Description>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>9</Order>
          <CommandLine>cmd /c C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown /mode:vm "/unattend:C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\Unattend.xml"</CommandLine>
          <Description>Sysprep with cloudbase-init unattend for next boot</Description>
        </SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
```

> **Security note:** The password in the answer file is only used during the initial build and is wiped by Sysprep. Each VM cloned from the image will prompt for a new password during OOBE.

```bash
oc create configmap autounattend-uefi \
  --from-file=Autounattend.xml \
  --namespace=windows-image-build
```

> **Key detail:** KubeVirt has native support for the `sysprep` volume type. It mounts the ConfigMap as a virtual floppy/CDROM that Windows automatically detects and reads during installation. You do not need to manually place the XML file.

For semi-automated mode, skip this step -- the pipeline will pause for VNC access instead.

---

## Step 4: Create the pipeline

The pipeline uses inline `taskSpec` definitions. Each task runs the `oc` CLI from the cluster's built-in image to apply and wait on resources. ISO DataVolumes are cached between runs -- the upload tasks skip the download if the DV already exists and is Ready.

The key differences from the BIOS pipeline are:

1. The installer VM includes `firmware.bootloader.efi` to boot in UEFI mode
2. The Autounattend ConfigMap name is `autounattend-uefi`
3. A `trigger-cd-boot` task sends a keypress after the VM starts (see note below)

> **Why Secure Boot is disabled during the build:** Some VirtIO driver versions are not WHQL-signed. With Secure Boot enabled, the viostor driver fails to load during WinPE, making the VirtIO disk invisible to Windows Setup. The resulting golden image works fine with Secure Boot enabled at clone time because the drivers are already installed.

> **Why the `trigger-cd-boot` task exists:** In BIOS mode, SeaBIOS auto-boots the CD-ROM. In UEFI mode, the Windows ISO's `cdboot.efi` shows a "Press any key to boot from CD or DVD" prompt that times out after ~5 seconds. If no key is pressed, the CD boot is skipped and the VM drops to the EFI shell with "No bootable option or device was found." The `trigger-cd-boot` task sends a keypress via `virsh send-key` through the virt-launcher pod to satisfy this prompt.

Save as `windows-image-pipeline-uefi.yaml`:

```yaml
apiVersion: tekton.dev/v1
kind: Pipeline
metadata:
  name: windows-image-builder-uefi
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
      default: win2k22
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

    # ── Create the installer VM (UEFI boot) ─────────────────────────
    # Uses runStrategy: RerunOnFailure so the VM stays off after Sysprep's
    # clean shutdown but restarts automatically if it crashes during install.
    # The sysprep volume mounts the Autounattend ConfigMap for fully
    # unattended install. For semi-automated mode, remove the sysprep
    # disk and volume entries and connect via VNC after the VM boots.
    #
    # The firmware.bootloader.efi block tells KubeVirt to boot in UEFI
    # mode. Without this, KubeVirt defaults to BIOS even on q35 machine
    # type, and Windows Setup will refuse to install to the GPT disk.
    # Secure Boot is disabled during the build because some VirtIO driver
    # versions are not WHQL-signed.
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
                runStrategy: RerunOnFailure
                template:
                  metadata:
                    labels:
                      kubevirt.io/vm: windows-installer
                  spec:
                    domain:
                      firmware:
                        bootloader:
                          efi:
                            secureBoot: false
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
                            name: autounattend-uefi
              VMEOF
              echo "Installer VM created and starting (UEFI mode)"

    # ── Trigger CD boot (UEFI-specific) ───────────────────────────────
    # In UEFI mode, cdboot.efi shows "Press any key to boot from CD or
    # DVD" with a ~5-second timeout. Since the task can't react fast
    # enough to catch this prompt, it instead waits for the timeout to
    # expire, then navigates the OVMF Boot Manager to explicitly select
    # the CDROM device. The Boot Manager waits indefinitely for input,
    # so there is no timing race.
    - name: trigger-cd-boot
      runAfter:
        - create-installer-vm
      taskSpec:
        steps:
          - name: send-keypress
            image: image-registry.openshift-image-registry.svc:5000/openshift/cli:latest
            script: |
              #!/bin/bash
              set -euo pipefail
              echo "Waiting for VMI to be Running..."
              oc wait vmi/windows-installer -n windows-image-build \
                --for=jsonpath='{.status.phase}'=Running \
                --timeout=10m
              POD=$(oc get pods -n windows-image-build \
                -l kubevirt.io/vm=windows-installer \
                -o jsonpath='{.items[0].metadata.name}')
              VIRSH="oc exec -n windows-image-build $POD -- virsh -c qemu:///session"

              # Wait for the CD boot prompt to time out and OVMF to reach
              # the "No bootable option" screen (takes ~10 seconds)
              echo "Waiting 15s for UEFI CD boot prompt to time out..."
              sleep 15

              # Enter OVMF Setup from the "No bootable option" screen
              echo "Entering OVMF firmware setup..."
              $VIRSH send-key 1 KEY_ENTER
              sleep 2

              # Navigate to Boot Manager (Down, Down, Enter)
              echo "Navigating to Boot Manager..."
              $VIRSH send-key 1 KEY_DOWN
              sleep 1
              $VIRSH send-key 1 KEY_DOWN
              sleep 1
              $VIRSH send-key 1 KEY_ENTER
              sleep 2

              # Select first device (CDROM) in Boot Manager
              echo "Selecting CDROM device..."
              $VIRSH send-key 1 KEY_ENTER
              sleep 1

              # Send keypresses to catch "Press any key to boot from CD"
              echo "Sending keypresses for CD boot prompt..."
              for i in $(seq 1 10); do
                $VIRSH send-key 1 KEY_SPACE 2>/dev/null || true
                sleep 1
              done
              echo "Boot sequence complete -- Windows installer should be loading"

    # ── Wait for VM shutdown (after install + sysprep) ──────────────
    # With runStrategy: RerunOnFailure, a clean Sysprep shutdown causes
    # the VMI to reach Succeeded then be deleted (VM status = Stopped).
    # The poll checks for both Succeeded and a missing VMI with a Stopped VM.
    - name: wait-for-vm-shutdown
      runAfter:
        - trigger-cd-boot
      timeout: "4h"
      taskSpec:
        steps:
          - name: wait
            image: image-registry.openshift-image-registry.svc:5000/openshift/cli:latest
            timeout: "4h"
            script: |
              #!/bin/bash
              set -euo pipefail
              echo "Waiting for VMI windows-installer to shut down..."
              echo "This will take 45-90 minutes for unattended Windows install + Sysprep."
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
                # With RerunOnFailure, a clean shutdown deletes the VMI.
                # Check if the VM itself is Stopped (meaning Sysprep shut it down).
                if [ "$PHASE" = "NotFound" ]; then
                  VM_STATUS=$(oc get vm windows-installer -n windows-image-build \
                    -o jsonpath='{.status.printableStatus}' 2>/dev/null || echo "Unknown")
                  if [ "$VM_STATUS" = "Stopped" ]; then
                    echo "VMI gone and VM is Stopped -- Sysprep shutdown complete"
                    exit 0
                  fi
                  echo "VMI not found, VM status = $VM_STATUS (may be starting up)"
                fi
                sleep 15
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

              # Create or update the DataSource so the image appears in the catalog
              cat <<DSEOF | oc apply -f -
              apiVersion: cdi.kubevirt.io/v1beta1
              kind: DataSource
              metadata:
                name: $(params.goldenImageName)
                namespace: openshift-virtualization-os-images
                labels:
                  instancetype.kubevirt.io/default-instancetype: u1.2xlarge
                  instancetype.kubevirt.io/default-preference: windows.2k22
              spec:
                source:
                  pvc:
                    name: $(params.goldenImageName)
                    namespace: openshift-virtualization-os-images
              DSEOF
              echo "DataSource created/updated"
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
oc apply -f windows-image-pipeline-uefi.yaml
```

---

## Step 5: Run the pipeline

Save as `windows-image-pipelinerun-uefi.yaml`:

```yaml
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: windows-image-build-uefi-
  namespace: windows-image-build
spec:
  pipelineRef:
    name: windows-image-builder-uefi
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
      value: "win2k22"
    - name: rootDiskSize
      value: "60Gi"
```

```bash
oc create -f windows-image-pipelinerun-uefi.yaml
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
3. Click on the `windows-image-builder-uefi` pipeline to see run history.
4. Click on a specific run to see the task graph and logs.

---

## Step 7: Complete the Windows install via VNC (semi-automated only)

If running in semi-automated mode, the pipeline pauses at the `wait-for-vm-shutdown` task. Connect via VNC to install Windows and run Sysprep.

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
oc get dv -n openshift-virtualization-os-images | grep win2k22
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

- **EFI firmware must be explicitly set.** Without the `firmware.bootloader.efi` block in the VM spec, KubeVirt defaults to BIOS boot even on q35 machine type. The VM will boot in legacy mode and Windows Setup will fail with "Windows cannot be installed to this disk. The selected disk is of the GPT partition style."
- **MSR partition cannot be formatted.** Do not add a `<Format>` element to the MSR partition's `<ModifyPartition>`. MSR partitions cannot be formatted or assigned a drive letter. Windows Setup will fail with a disk configuration error if you try.
- **Secure Boot is disabled during the build.** Some VirtIO driver versions are not WHQL-signed. With Secure Boot enabled in the installer VM, the viostor driver fails to load during WinPE, making the VirtIO disk invisible to Windows Setup. The resulting golden image works with Secure Boot enabled at clone time because the drivers are already installed by then.
- **preference.yaml alignment.** This UEFI pipeline produces an image that matches the `preferredUseEfi: true` and `preferredUseSecureBoot: true` settings in `preference.yaml`. VMs created from the golden image via the catalog will automatically boot in UEFI+SecureBoot mode.
- **Secure Boot requires SMM.** If creating consumer VMs via the CLI with `secureBoot: true`, you must also enable SMM (System Management Mode) by adding `smm: {}` under `features`. Without it, KubeVirt rejects the VM with "SecureBoot requires SMM, which is currently disabled." The OpenShift console handles this automatically.
- **ConfigMap key casing:** The ConfigMap key **must** be `Autounattend.xml` (capital A). KubeVirt's sysprep volume type and Windows Setup both require this exact casing. Using `autounattend.xml` (lowercase) will silently fail -- the VM boots to the manual installer with no error.
- **Component attributes:** All `<component>` elements in the answer file must include `publicKeyToken="31bf3856ad364e35"` and `versionScope="nonSxS"`. Without these, Windows Setup rejects the file as invalid.
- **Driver component:** VirtIO driver paths must be under `Microsoft-Windows-PnpCustomizationsWinPE`, not `Microsoft-Windows-Setup`. Placing them under the wrong component causes a "component or setting does not exist" error.
- **VirtIO CDROM drive letter:** The answer file scans drives D: through F: for VirtIO drivers and guest tools. The EFI and MSR partitions do not receive drive letters, so CDROM letter assignment is unchanged from the BIOS pipeline. If your disk configuration differs significantly, connect via VNC to check the actual drive letters and update the XML.
- **Windows image index:** The answer file uses `/IMAGE/INDEX` (value `2`) to select Standard with Desktop Experience. This works for both retail and evaluation ISOs. If you need a different edition, common indexes are: 1 = Standard Core, 2 = Standard Desktop, 3 = Datacenter Core, 4 = Datacenter Desktop. You can verify with `dism /Get-ImageInfo /ImageFile:D:\sources\install.wim` from a WinPE shell.
- **Golden image name:** The default name `win2k22` matches the DataSource managed by the SSP operator in `openshift-virtualization-os-images`. Using this name makes the image appear automatically in the Virtualization catalog. Custom names require creating a DataSource manually, and the SSP operator will not manage them.
- **VM run strategy:** The VM must use `runStrategy: RerunOnFailure` (not `running: true`). With `running: true`, KubeVirt restarts the VM after Sysprep shuts it down, and the pipeline never detects the shutdown.
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
                - windows-image-builder-uefi
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
- **Task pod cannot pull CLI image.** The three parallel upload tasks can hit the internal registry's pull QPS limit. If you see `TaskRunImagePullFailed`, delete the PipelineRun and retry after 30 seconds.
- **Timeout on `wait-for-vm-shutdown`.** The default is 4 hours. If Windows install + updates take longer, increase the `timeout` on that task.

### ISO download fails in the pipeline

```bash
oc describe dv windows-server-2022-iso -n windows-image-build
```

Common causes:
- URL is not publicly accessible or requires authentication. For private COS buckets, you may need to use a pre-signed URL or configure CDI with credentials.
- TLS certificate issues. Try adding `certConfigMap` to the DataVolume's HTTP source if using a private registry with self-signed certs.

### Unattended install does not start

Take a VNC screenshot to see what's on screen:

```bash
# If virtctl vnc fails (no VNC viewer), proxy the port and use gvnccapture:
virtctl vnc windows-installer -n windows-image-build --proxy-only --port=5902 &
gvnccapture 127.0.0.1:2 screenshot.png
```

Common causes:
- **"The answer file is invalid":** Missing `publicKeyToken` or `versionScope` attributes on component elements. All components need the full attribute set.
- **"A component or setting does not exist":** DriverPaths is under `Microsoft-Windows-Setup` instead of `Microsoft-Windows-PnpCustomizationsWinPE`.
- **"Could not apply DiskConfiguration":** VirtIO storage driver not loaded. Check that DriverPaths are under the correct component and that the drive letter paths match.
- **"Windows cannot be installed to this disk. The selected disk is of the GPT partition style":** The VM is booting in BIOS mode, not UEFI. Check that the `firmware.bootloader.efi` block is present in the VM spec.
- **VM stuck at "BdsDxe: No bootable option or device was found":** The `trigger-cd-boot` task failed to send a keypress in time, or the virt-launcher pod was not found. Check the task logs. You can manually recover by opening the UEFI Boot Manager via VNC, selecting the CDROM device, and pressing a key at the "Press any key" prompt.
- **ConfigMap key is lowercase:** Must be `Autounattend.xml` (capital A) in the ConfigMap.

### Pipeline hangs at wait-for-vm-shutdown

The VM may still be running (installing updates, waiting at a prompt, etc.):

```bash
# Check if the VMI is still running
oc get vmi windows-installer -n windows-image-build

# Check if guest agent is reporting (means Windows is booted)
oc get vmi windows-installer -n windows-image-build -o jsonpath='{.status.guestOSInfo}'

# Take a VNC screenshot
virtctl vnc windows-installer -n windows-image-build --proxy-only --port=5902 &
gvnccapture 127.0.0.1:2 screenshot.png
```

If the guest agent is active but the VM won't shut down, Sysprep may have failed. You can trigger it manually via the QEMU guest agent:

```bash
POD=$(oc get pods -n windows-image-build -l kubevirt.io/vm=windows-installer -o name)
oc exec -n windows-image-build $POD -- virsh -c qemu:///session qemu-agent-command 1 \
  '{"execute":"guest-exec","arguments":{"path":"C:\\Windows\\System32\\Sysprep\\sysprep.exe","arg":["/generalize","/oobe","/shutdown","/mode:vm"],"capture-output":true}}'
```

### Clone to catalog namespace fails

```bash
oc describe dv win2k22 -n openshift-virtualization-os-images
```

Common causes:
- Source PVC does not exist (check the namespace and name match exactly).
- Cross-namespace cloning is not enabled. Check CDI configuration.
- Insufficient storage quota in the target namespace.

---

## Quick Reference

| What | Command |
|------|---------|
| Apply pipeline | `oc apply -f windows-image-pipeline-uefi.yaml` |
| Start a run | `oc create -f windows-image-pipelinerun-uefi.yaml` |
| Watch progress | `oc get pipelinerun -n windows-image-build -w` |
| Stream logs | `tkn pipelinerun logs -f -n windows-image-build` |
| Connect to installer VM | `virtctl vnc windows-installer -n windows-image-build` |
| Check golden image | `oc get dv -n openshift-virtualization-os-images` |
| Cancel a run | `tkn pipelinerun cancel <run-name> -n windows-image-build` |
