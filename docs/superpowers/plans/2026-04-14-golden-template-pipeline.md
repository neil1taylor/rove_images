# Golden Template Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a production-ready platform engineering runbook for importing VMware golden templates into ROKS via MTV, with all YAML validated, a draw.io architecture diagram, and supporting artifact files ready for engineers to apply directly.

**Architecture:** The spec (`docs/superpowers/specs/2026-04-14-golden-template-pipeline-design.md`) contains the full document content. This plan breaks implementation into: (1) extract all YAML examples into standalone, apply-ready files, (2) validate YAML syntax, (3) create the MTV pipeline draw.io diagram, (4) finalize the runbook with file references, (5) commit at each checkpoint.

**Tech Stack:** Kubernetes/OCP YAML, draw.io XML, Markdown

---

## File Structure

```
docs/
  superpowers/
    specs/
      2026-04-14-golden-template-pipeline-design.md  (existing — the spec)
    plans/
      2026-04-14-golden-template-pipeline.md          (this plan)
manifests/
  namespace.yaml                    — vm-golden-images namespace
  rbac/
    clone-source-clusterrole.yaml   — CDI cross-namespace clone ClusterRole
    clone-source-rolebinding.yaml   — example RoleBinding for a consumer namespace
  resource-quota.yaml               — storage quota for golden images namespace
  storage/
    clone-test-dv.yaml              — example DataVolume for clone testing
  linux/
    instancetype.yaml               — linux-medium VirtualMachineInstancetype
    preference.yaml                 — rhel9-golden VirtualMachinePreference
    consumer-vm.yaml                — full consumer VM example (clone + cloud-init)
  windows/
    instancetype.yaml               — windows-medium VirtualMachineInstancetype
    preference.yaml                 — win2022-golden VirtualMachinePreference
    sysprep-configmap.yaml          — unattend.xml ConfigMap
    virtio-win-cdrom-patch.yaml     — VM spec patch for VirtIO driver remediation
    consumer-vm.yaml                — full consumer VM example (clone + sysprep)
  lifecycle/
    cleanup-cronjob.yaml            — deprecated image cleanup CronJob
  mtv/
    migration-example.yaml          — example Migration CR
diagrams/
  golden-template-pipeline.drawio   — draw.io architecture diagram
```

Each manifest is a standalone file an engineer can `oc apply -f`. No Helm, no Kustomize — plain YAML that matches the spec exactly.

---

### Task 1: Namespace and RBAC Manifests

**Files:**
- Create: `manifests/namespace.yaml`
- Create: `manifests/rbac/clone-source-clusterrole.yaml`
- Create: `manifests/rbac/clone-source-rolebinding.yaml`
- Create: `manifests/resource-quota.yaml`

- [ ] **Step 1: Create namespace manifest**

```yaml
# manifests/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: vm-golden-images
  labels:
    purpose: golden-images
```

- [ ] **Step 2: Create ClusterRole for cross-namespace cloning**

```yaml
# manifests/rbac/clone-source-clusterrole.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: golden-image-clone-source
rules:
  - apiGroups: ["cdi.kubevirt.io"]
    resources: ["datavolumes/source"]
    verbs: ["create"]
```

- [ ] **Step 3: Create example RoleBinding for a consumer namespace**

```yaml
# manifests/rbac/clone-source-rolebinding.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: allow-clone-from-golden-images
  namespace: vm-golden-images
subjects:
  - kind: ServiceAccount
    name: default
    namespace: team-a-vms  # Replace with consumer namespace
roleRef:
  kind: ClusterRole
  name: golden-image-clone-source
  apiGroup: rbac.authorization.k8s.io
```

- [ ] **Step 4: Create resource quota manifest**

```yaml
# manifests/resource-quota.yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: golden-image-storage
  namespace: vm-golden-images
spec:
  hard:
    requests.storage: 2Ti
```

- [ ] **Step 5: Validate YAML syntax**

Run: `for f in manifests/namespace.yaml manifests/rbac/*.yaml manifests/resource-quota.yaml; do echo "--- $f ---"; python3 -c "import yaml, sys; yaml.safe_load(open('$f')); print('OK')"; done`

Expected: All files print `OK`.

- [ ] **Step 6: Commit**

```bash
git add manifests/namespace.yaml manifests/rbac/ manifests/resource-quota.yaml
git commit -m "feat: add namespace, RBAC, and resource quota manifests for golden images"
```

---

### Task 2: Storage and MTV Manifests

**Files:**
- Create: `manifests/storage/clone-test-dv.yaml`
- Create: `manifests/mtv/migration-example.yaml`

- [ ] **Step 1: Create clone test DataVolume**

```yaml
# manifests/storage/clone-test-dv.yaml
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: rhel9-clone-test
  namespace: test-vms
spec:
  source:
    pvc:
      namespace: vm-golden-images
      name: rhel9-base-20260414  # Replace with actual golden image PVC name
  storage:
    storageClassName: ocs-storagecluster-ceph-rbd  # Or ibmc-file-gold
    resources:
      requests:
        storage: 100Gi
```

- [ ] **Step 2: Create example Migration CR**

```yaml
# manifests/mtv/migration-example.yaml
apiVersion: forklift.konveyor.io/v1beta1
kind: Migration
metadata:
  name: golden-rhel9-import
  namespace: openshift-mtv
spec:
  plan:
    name: golden-rhel9-plan
    namespace: openshift-mtv
```

- [ ] **Step 3: Validate YAML syntax**

Run: `for f in manifests/storage/clone-test-dv.yaml manifests/mtv/migration-example.yaml; do echo "--- $f ---"; python3 -c "import yaml, sys; yaml.safe_load(open('$f')); print('OK')"; done`

Expected: All files print `OK`.

- [ ] **Step 4: Commit**

```bash
git add manifests/storage/ manifests/mtv/
git commit -m "feat: add clone test DataVolume and MTV migration example manifests"
```

---

### Task 3: Linux Track Manifests

**Files:**
- Create: `manifests/linux/instancetype.yaml`
- Create: `manifests/linux/preference.yaml`
- Create: `manifests/linux/consumer-vm.yaml`

- [ ] **Step 1: Create Linux InstanceType**

```yaml
# manifests/linux/instancetype.yaml
apiVersion: instancetype.kubevirt.io/v1beta1
kind: VirtualMachineInstancetype
metadata:
  name: linux-medium
  namespace: vm-golden-images
spec:
  cpu:
    guest: 4
  memory:
    guest: 8Gi
```

- [ ] **Step 2: Create Linux Preference**

```yaml
# manifests/linux/preference.yaml
apiVersion: instancetype.kubevirt.io/v1beta1
kind: VirtualMachinePreference
metadata:
  name: rhel9-golden
  namespace: vm-golden-images
spec:
  cpu:
    preferredCPUTopology: preferSockets
  devices:
    preferredDiskBus: virtio
    preferredInterfaceModel: virtio
    preferredNetworkInterfaceMultiQueue: true
  firmware:
    preferredUseEfi: true
    preferredUseSecureBoot: false
  machine:
    preferredMachineType: q35
```

- [ ] **Step 3: Create Linux consumer VM example**

```yaml
# manifests/linux/consumer-vm.yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: web-server-01
  namespace: team-a-vms
spec:
  instancetype:
    kind: VirtualMachineInstancetype
    name: linux-medium
    inferFromVolume: false
  preference:
    kind: VirtualMachinePreference
    name: rhel9-golden
    inferFromVolume: false
  runStrategy: Always
  dataVolumeTemplates:
    - metadata:
        name: web-server-01-rootdisk
      spec:
        source:
          pvc:
            namespace: vm-golden-images
            name: rhel9-base-20260414  # Replace with actual golden image PVC name
        storage:
          storageClassName: ocs-storagecluster-ceph-rbd
          resources:
            requests:
              storage: 100Gi
  template:
    spec:
      domain:
        devices:
          disks:
            - name: rootdisk
              disk:
                bus: virtio
          interfaces:
            - name: default
              masquerade: {}
        resources: {}
      networks:
        - name: default
          pod: {}
      volumes:
        - name: rootdisk
          dataVolume:
            name: web-server-01-rootdisk
        - name: cloudinitdisk
          cloudInitNoCloud:
            userData: |
              #cloud-config
              hostname: web-server-01
              ssh_authorized_keys:
                - ssh-rsa AAAAB3... user@workstation
```

- [ ] **Step 4: Validate YAML syntax**

Run: `for f in manifests/linux/*.yaml; do echo "--- $f ---"; python3 -c "import yaml, sys; yaml.safe_load(open('$f')); print('OK')"; done`

Expected: All files print `OK`.

- [ ] **Step 5: Commit**

```bash
git add manifests/linux/
git commit -m "feat: add Linux golden image InstanceType, Preference, and consumer VM manifests"
```

---

### Task 4: Windows Track Manifests

**Files:**
- Create: `manifests/windows/instancetype.yaml`
- Create: `manifests/windows/preference.yaml`
- Create: `manifests/windows/sysprep-configmap.yaml`
- Create: `manifests/windows/virtio-win-cdrom-patch.yaml`
- Create: `manifests/windows/consumer-vm.yaml`

- [ ] **Step 1: Create Windows InstanceType**

```yaml
# manifests/windows/instancetype.yaml
apiVersion: instancetype.kubevirt.io/v1beta1
kind: VirtualMachineInstancetype
metadata:
  name: windows-medium
  namespace: vm-golden-images
spec:
  cpu:
    guest: 4
  memory:
    guest: 16Gi
```

- [ ] **Step 2: Create Windows Preference**

```yaml
# manifests/windows/preference.yaml
apiVersion: instancetype.kubevirt.io/v1beta1
kind: VirtualMachinePreference
metadata:
  name: win2022-golden
  namespace: vm-golden-images
spec:
  cpu:
    preferredCPUTopology: preferSockets
  devices:
    preferredDiskBus: virtio
    preferredInterfaceModel: virtio
    preferredInputBus: usb
    preferredInputType: tablet
    preferredTPM: {}
  features:
    preferredHyperv:
      vapic: {}
      spinlocks:
        spinlocks: 8191
      relaxed: {}
      vpindex: {}
      runtime: {}
      synic: {}
      stimer:
        direct: {}
      frequencies: {}
      reset: {}
      tlbflush: {}
      ipi: {}
      reenlightenment: {}
  firmware:
    preferredUseEfi: true
    preferredUseSecureBoot: true
  machine:
    preferredMachineType: q35
```

- [ ] **Step 3: Create sysprep ConfigMap with full unattend.xml**

```yaml
# manifests/windows/sysprep-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: win2022-sysprep
  namespace: team-a-vms  # Replace with consumer namespace
data:
  unattend.xml: |
    <?xml version="1.0" encoding="utf-8"?>
    <unattend xmlns="urn:schemas-microsoft-com:unattend">
      <settings pass="specialize">
        <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
                   xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
                   xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
          <InputLocale>en-US</InputLocale>
          <SystemLocale>en-US</SystemLocale>
          <UILanguage>en-US</UILanguage>
          <UserLocale>en-US</UserLocale>
        </component>
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
                   xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
                   xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
          <ComputerName>*</ComputerName>
        </component>
        <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
                   xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
                   xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
          <RunSynchronous>
            <RunSynchronousCommand wcm:action="add">
              <Order>1</Order>
              <Path>powershell.exe -ExecutionPolicy Bypass -File C:\Scripts\post-clone-setup.ps1</Path>
              <Description>Post-clone configuration</Description>
            </RunSynchronousCommand>
          </RunSynchronous>
        </component>
      </settings>
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
              <Value><!-- Set via sealed secret or runtime injection --></Value>
              <PlainText>false</PlainText>
            </AdministratorPassword>
          </UserAccounts>
        </component>
      </settings>
    </unattend>
```

- [ ] **Step 4: Create VirtIO driver remediation patch**

```yaml
# manifests/windows/virtio-win-cdrom-patch.yaml
# Apply via: oc patch vm <vm-name> -n vm-golden-images --type merge --patch-file manifests/windows/virtio-win-cdrom-patch.yaml
spec:
  template:
    spec:
      volumes:
        - name: virtio-win
          containerDisk:
            image: registry.redhat.io/container-native-virtualization/virtio-win
      domain:
        devices:
          disks:
            - name: virtio-win
              cdrom:
                bus: sata
```

- [ ] **Step 5: Create Windows consumer VM example**

```yaml
# manifests/windows/consumer-vm.yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: app-server-01
  namespace: team-a-vms
spec:
  instancetype:
    kind: VirtualMachineInstancetype
    name: windows-medium
    inferFromVolume: false
  preference:
    kind: VirtualMachinePreference
    name: win2022-golden
    inferFromVolume: false
  runStrategy: Always
  dataVolumeTemplates:
    - metadata:
        name: app-server-01-rootdisk
      spec:
        source:
          pvc:
            namespace: vm-golden-images
            name: win2022-std-sysprep-20260414  # Replace with actual golden image PVC name
        storage:
          storageClassName: ocs-storagecluster-ceph-rbd
          resources:
            requests:
              storage: 100Gi
  template:
    spec:
      domain:
        devices:
          disks:
            - name: rootdisk
              disk:
                bus: virtio
          interfaces:
            - name: default
              masquerade: {}
        resources: {}
      networks:
        - name: default
          pod: {}
      volumes:
        - name: rootdisk
          dataVolume:
            name: app-server-01-rootdisk
        - name: sysprep
          sysprep:
            configMap:
              name: win2022-sysprep
```

- [ ] **Step 6: Validate YAML syntax**

Run: `for f in manifests/windows/*.yaml; do echo "--- $f ---"; python3 -c "import yaml, sys; yaml.safe_load(open('$f')); print('OK')"; done`

Expected: All files print `OK`. Note: `sysprep-configmap.yaml` contains embedded XML in a YAML string — the YAML parser validates the YAML structure, not the XML content. The XML was validated during spec self-review.

- [ ] **Step 7: Commit**

```bash
git add manifests/windows/
git commit -m "feat: add Windows golden image InstanceType, Preference, sysprep, and consumer VM manifests"
```

---

### Task 5: Lifecycle Manifests

**Files:**
- Create: `manifests/lifecycle/cleanup-cronjob.yaml`

- [ ] **Step 1: Create cleanup CronJob**

```yaml
# manifests/lifecycle/cleanup-cronjob.yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: golden-image-cleanup-check
  namespace: vm-golden-images
spec:
  schedule: "0 6 * * 1"  # Weekly Monday 6am
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: golden-image-manager
          containers:
            - name: cleanup-check
              image: bitnami/kubectl:latest
              command:
                - /bin/bash
                - -c
                - |
                  echo "=== Deprecated golden images ==="
                  oc get pvc -n vm-golden-images -l image-status=deprecated -o name
                  echo ""
                  echo "=== Check for referencing VMs before deleting ==="
                  # Engineers review output and delete manually
          restartPolicy: OnFailure
```

- [ ] **Step 2: Validate YAML syntax**

Run: `python3 -c "import yaml, sys; yaml.safe_load(open('manifests/lifecycle/cleanup-cronjob.yaml')); print('OK')"`

Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add manifests/lifecycle/
git commit -m "feat: add golden image cleanup CronJob manifest"
```

---

### Task 6: Draw.io Architecture Diagram

**Files:**
- Create: `diagrams/golden-template-pipeline.drawio`

The diagram shows the end-to-end pipeline from VMware source through MTV import to consumer VM provisioning, with the Linux/Windows track split and storage decision point.

- [ ] **Step 1: Create the draw.io XML**

The diagram has four swim lanes:
1. **VMware (Source)** — source VM, seal/prep, power off
2. **MTV Pipeline** — migration plan, VDDK transfer, virtv2v conversion, DataVolume creation
3. **Golden Image Namespace** — PVC storage, InstanceType/Preference CRDs, validation boot, re-seal
4. **Consumer Namespace** — clone request, CDI clone (with ODF vs File branching), cloud-init/sysprep, running VM

Connections show data flow. The Linux/Windows split is shown as a decision diamond after "Post-Import" with two parallel tracks converging at "Clone-Ready Golden Image."

```xml
<mxfile host="app.diagrams.net" modified="2026-04-14T00:00:00.000Z" agent="Claude" version="24.0.0" type="device">
  <diagram name="Golden Template Pipeline" id="golden-template-pipeline">
    <mxGraphModel dx="1422" dy="762" grid="1" gridSize="10" guides="1" tooltips="1" connect="1" arrows="1" fold="1" page="1" pageScale="1" pageWidth="1600" pageHeight="900" math="0" shadow="0">
      <root>
        <mxCell id="0" />
        <mxCell id="1" parent="0" />

        <!-- Swim Lane: VMware Source -->
        <mxCell id="lane1" value="VMware (vCenter)" style="shape=table;startSize=30;container=1;collapsible=0;childLayout=tableLayout;fixedRows=1;rowLines=0;fontStyle=1;align=center;resizeLast=1;fillColor=#dae8fc;strokeColor=#6c8ebf;fontSize=14;" vertex="1" parent="1">
          <mxGeometry x="20" y="20" width="300" height="860" as="geometry" />
        </mxCell>

        <!-- Swim Lane: MTV Pipeline -->
        <mxCell id="lane2" value="MTV Pipeline" style="shape=table;startSize=30;container=1;collapsible=0;childLayout=tableLayout;fixedRows=1;rowLines=0;fontStyle=1;align=center;resizeLast=1;fillColor=#d5e8d4;strokeColor=#82b366;fontSize=14;" vertex="1" parent="1">
          <mxGeometry x="340" y="20" width="300" height="860" as="geometry" />
        </mxCell>

        <!-- Swim Lane: Golden Image NS -->
        <mxCell id="lane3" value="vm-golden-images Namespace" style="shape=table;startSize=30;container=1;collapsible=0;childLayout=tableLayout;fixedRows=1;rowLines=0;fontStyle=1;align=center;resizeLast=1;fillColor=#fff2cc;strokeColor=#d6b656;fontSize=14;" vertex="1" parent="1">
          <mxGeometry x="660" y="20" width="360" height="860" as="geometry" />
        </mxCell>

        <!-- Swim Lane: Consumer NS -->
        <mxCell id="lane4" value="Consumer Namespace" style="shape=table;startSize=30;container=1;collapsible=0;childLayout=tableLayout;fixedRows=1;rowLines=0;fontStyle=1;align=center;resizeLast=1;fillColor=#f8cecc;strokeColor=#b85450;fontSize=14;" vertex="1" parent="1">
          <mxGeometry x="1040" y="20" width="300" height="860" as="geometry" />
        </mxCell>

        <!-- VMware Source Nodes -->
        <mxCell id="vm_source" value="Source VM&#xa;(vSphere)" style="rounded=1;whiteSpace=wrap;html=1;fillColor=#dae8fc;strokeColor=#6c8ebf;" vertex="1" parent="1">
          <mxGeometry x="60" y="80" width="220" height="50" as="geometry" />
        </mxCell>
        <mxCell id="vm_prep_linux" value="Linux Prep&#xa;cloud-init, clear machine-id,&#xa;remove SSH host keys" style="rounded=1;whiteSpace=wrap;html=1;fillColor=#dae8fc;strokeColor=#6c8ebf;" vertex="1" parent="1">
          <mxGeometry x="60" y="160" width="220" height="60" as="geometry" />
        </mxCell>
        <mxCell id="vm_prep_win" value="Windows Prep&#xa;VirtIO drivers, qemu-ga,&#xa;sysprep /generalize /oobe" style="rounded=1;whiteSpace=wrap;html=1;fillColor=#dae8fc;strokeColor=#6c8ebf;" vertex="1" parent="1">
          <mxGeometry x="60" y="240" width="220" height="60" as="geometry" />
        </mxCell>
        <mxCell id="vm_sealed" value="Sealed VM&#xa;(powered off)" style="rounded=1;whiteSpace=wrap;html=1;fillColor=#dae8fc;strokeColor=#6c8ebf;fontStyle=1;" vertex="1" parent="1">
          <mxGeometry x="60" y="330" width="220" height="50" as="geometry" />
        </mxCell>

        <!-- Arrows: VMware -->
        <mxCell id="a1" edge="1" source="vm_source" target="vm_prep_linux" parent="1">
          <mxGeometry relative="1" as="geometry" />
        </mxCell>
        <mxCell id="a1b" edge="1" source="vm_source" target="vm_prep_win" parent="1">
          <mxGeometry relative="1" as="geometry" />
        </mxCell>
        <mxCell id="a2" edge="1" source="vm_prep_linux" target="vm_sealed" parent="1">
          <mxGeometry relative="1" as="geometry" />
        </mxCell>
        <mxCell id="a2b" edge="1" source="vm_prep_win" target="vm_sealed" parent="1">
          <mxGeometry relative="1" as="geometry" />
        </mxCell>

        <!-- MTV Pipeline Nodes -->
        <mxCell id="mtv_plan" value="MTV Migration Plan&#xa;(Cold Migration)" style="rounded=1;whiteSpace=wrap;html=1;fillColor=#d5e8d4;strokeColor=#82b366;" vertex="1" parent="1">
          <mxGeometry x="380" y="330" width="220" height="50" as="geometry" />
        </mxCell>
        <mxCell id="mtv_vddk" value="VDDK Transfer&#xa;(VMDK → raw)" style="rounded=1;whiteSpace=wrap;html=1;fillColor=#d5e8d4;strokeColor=#82b366;" vertex="1" parent="1">
          <mxGeometry x="380" y="410" width="220" height="50" as="geometry" />
        </mxCell>
        <mxCell id="mtv_v2v" value="virtv2v Conversion&#xa;(driver check/injection)" style="rounded=1;whiteSpace=wrap;html=1;fillColor=#d5e8d4;strokeColor=#82b366;" vertex="1" parent="1">
          <mxGeometry x="380" y="490" width="220" height="50" as="geometry" />
        </mxCell>

        <!-- Arrows: VMware → MTV -->
        <mxCell id="a3" edge="1" source="vm_sealed" target="mtv_plan" parent="1">
          <mxGeometry relative="1" as="geometry" />
        </mxCell>
        <mxCell id="a4" edge="1" source="mtv_plan" target="mtv_vddk" parent="1">
          <mxGeometry relative="1" as="geometry" />
        </mxCell>
        <mxCell id="a5" edge="1" source="mtv_vddk" target="mtv_v2v" parent="1">
          <mxGeometry relative="1" as="geometry" />
        </mxCell>

        <!-- Golden Image NS Nodes -->
        <mxCell id="gi_dv" value="DataVolume + PVC&#xa;(golden image disk)" style="rounded=1;whiteSpace=wrap;html=1;fillColor=#fff2cc;strokeColor=#d6b656;" vertex="1" parent="1">
          <mxGeometry x="700" y="490" width="280" height="50" as="geometry" />
        </mxCell>
        <mxCell id="gi_validate" value="Validation Boot&#xa;(verify KVM boot, VirtIO, guest agent)" style="rounded=1;whiteSpace=wrap;html=1;fillColor=#fff2cc;strokeColor=#d6b656;" vertex="1" parent="1">
          <mxGeometry x="700" y="570" width="280" height="50" as="geometry" />
        </mxCell>
        <mxCell id="gi_decision" value="OS?" style="rhombus;whiteSpace=wrap;html=1;fillColor=#fff2cc;strokeColor=#d6b656;" vertex="1" parent="1">
          <mxGeometry x="795" y="645" width="90" height="60" as="geometry" />
        </mxCell>
        <mxCell id="gi_linux" value="Linux Track&#xa;Re-seal (machine-id, SSH keys,&#xa;cloud-init clean)&#xa;+ InstanceType + Preference" style="rounded=1;whiteSpace=wrap;html=1;fillColor=#d5e8d4;strokeColor=#82b366;" vertex="1" parent="1">
          <mxGeometry x="700" y="730" width="130" height="90" as="geometry" />
        </mxCell>
        <mxCell id="gi_windows" value="Windows Track&#xa;Re-sysprep, VirtIO verify,&#xa;Preference (Hyper-V&#xa;enlightenments)" style="rounded=1;whiteSpace=wrap;html=1;fillColor=#dae8fc;strokeColor=#6c8ebf;" vertex="1" parent="1">
          <mxGeometry x="850" y="730" width="130" height="90" as="geometry" />
        </mxCell>

        <!-- Storage Decision -->
        <mxCell id="storage_note" value="Storage Class:&#xa;ODF Ceph RBD (instant COW clone)&#xa;IBM Cloud File (full copy)" style="shape=note;whiteSpace=wrap;html=1;size=14;fillColor=#e1d5e7;strokeColor=#9673a6;fontSize=10;" vertex="1" parent="1">
          <mxGeometry x="700" y="390" width="280" height="60" as="geometry" />
        </mxCell>

        <!-- Arrows: MTV → Golden NS -->
        <mxCell id="a6" edge="1" source="mtv_v2v" target="gi_dv" parent="1">
          <mxGeometry relative="1" as="geometry" />
        </mxCell>
        <mxCell id="a7" edge="1" source="gi_dv" target="gi_validate" parent="1">
          <mxGeometry relative="1" as="geometry" />
        </mxCell>
        <mxCell id="a8" edge="1" source="gi_validate" target="gi_decision" parent="1">
          <mxGeometry relative="1" as="geometry" />
        </mxCell>
        <mxCell id="a9" value="Linux" style="" edge="1" source="gi_decision" target="gi_linux" parent="1">
          <mxGeometry relative="1" as="geometry" />
        </mxCell>
        <mxCell id="a10" value="Windows" style="" edge="1" source="gi_decision" target="gi_windows" parent="1">
          <mxGeometry relative="1" as="geometry" />
        </mxCell>

        <!-- Consumer NS Nodes -->
        <mxCell id="con_clone" value="CDI Clone Request&#xa;(DataVolumeTemplate&#xa;sources golden PVC)" style="rounded=1;whiteSpace=wrap;html=1;fillColor=#f8cecc;strokeColor=#b85450;" vertex="1" parent="1">
          <mxGeometry x="1080" y="570" width="220" height="60" as="geometry" />
        </mxCell>
        <mxCell id="con_identity" value="Identity Injection&#xa;Linux: cloud-init (cloudInitNoCloud)&#xa;Windows: sysprep (ConfigMap)" style="rounded=1;whiteSpace=wrap;html=1;fillColor=#f8cecc;strokeColor=#b85450;" vertex="1" parent="1">
          <mxGeometry x="1080" y="660" width="220" height="60" as="geometry" />
        </mxCell>
        <mxCell id="con_vm" value="Running VM&#xa;(unique identity,&#xa;InstanceType + Preference)" style="rounded=1;whiteSpace=wrap;html=1;fillColor=#f8cecc;strokeColor=#b85450;fontStyle=1;" vertex="1" parent="1">
          <mxGeometry x="1080" y="750" width="220" height="60" as="geometry" />
        </mxCell>

        <!-- Arrows: Golden NS → Consumer NS -->
        <mxCell id="a11" style="dashed=1;" edge="1" source="gi_dv" target="con_clone" parent="1">
          <mxGeometry relative="1" as="geometry" />
        </mxCell>
        <mxCell id="a12" edge="1" source="con_clone" target="con_identity" parent="1">
          <mxGeometry relative="1" as="geometry" />
        </mxCell>
        <mxCell id="a13" edge="1" source="con_identity" target="con_vm" parent="1">
          <mxGeometry relative="1" as="geometry" />
        </mxCell>

        <!-- RBAC Note -->
        <mxCell id="rbac_note" value="Cross-NS RBAC&#xa;(ClusterRole +&#xa;RoleBinding)" style="shape=note;whiteSpace=wrap;html=1;size=14;fillColor=#e1d5e7;strokeColor=#9673a6;fontSize=10;" vertex="1" parent="1">
          <mxGeometry x="1000" y="490" width="120" height="60" as="geometry" />
        </mxCell>
        <mxCell id="a_rbac" style="dashed=1;strokeColor=#9673a6;" edge="1" source="rbac_note" target="con_clone" parent="1">
          <mxGeometry relative="1" as="geometry" />
        </mxCell>
      </root>
    </mxGraphModel>
  </diagram>
</mxfile>
```

- [ ] **Step 2: Commit**

```bash
git add diagrams/
git commit -m "feat: add draw.io architecture diagram for golden template pipeline"
```

---

### Task 7: Update Spec with Manifest References

**Files:**
- Modify: `docs/superpowers/specs/2026-04-14-golden-template-pipeline-design.md`

Add a "Manifest Files" section at the top of the spec (after Overview) that maps each section to its standalone YAML file, so engineers can go straight to the apply-ready manifest.

- [ ] **Step 1: Add manifest reference section**

Insert after the Overview section (after the `---` on line 17):

```markdown
## Manifest Files

All YAML examples in this document are available as standalone, apply-ready files:

| Section | Manifest | Description |
|---|---|---|
| Prerequisites | [`manifests/namespace.yaml`](../../manifests/namespace.yaml) | `vm-golden-images` namespace |
| Prerequisites | [`manifests/resource-quota.yaml`](../../manifests/resource-quota.yaml) | Storage quota |
| Landing Zone | [`manifests/rbac/clone-source-clusterrole.yaml`](../../manifests/rbac/clone-source-clusterrole.yaml) | CDI cross-namespace clone ClusterRole |
| Landing Zone | [`manifests/rbac/clone-source-rolebinding.yaml`](../../manifests/rbac/clone-source-rolebinding.yaml) | Example consumer RoleBinding |
| MTV Import | [`manifests/mtv/migration-example.yaml`](../../manifests/mtv/migration-example.yaml) | Example Migration CR |
| Storage | [`manifests/storage/clone-test-dv.yaml`](../../manifests/storage/clone-test-dv.yaml) | Clone test DataVolume |
| Linux Track | [`manifests/linux/instancetype.yaml`](../../manifests/linux/instancetype.yaml) | `linux-medium` InstanceType |
| Linux Track | [`manifests/linux/preference.yaml`](../../manifests/linux/preference.yaml) | `rhel9-golden` Preference |
| Linux Track | [`manifests/linux/consumer-vm.yaml`](../../manifests/linux/consumer-vm.yaml) | Full consumer VM example |
| Windows Track | [`manifests/windows/instancetype.yaml`](../../manifests/windows/instancetype.yaml) | `windows-medium` InstanceType |
| Windows Track | [`manifests/windows/preference.yaml`](../../manifests/windows/preference.yaml) | `win2022-golden` Preference |
| Windows Track | [`manifests/windows/sysprep-configmap.yaml`](../../manifests/windows/sysprep-configmap.yaml) | Sysprep ConfigMap with `unattend.xml` |
| Windows Track | [`manifests/windows/virtio-win-cdrom-patch.yaml`](../../manifests/windows/virtio-win-cdrom-patch.yaml) | VirtIO driver remediation patch |
| Windows Track | [`manifests/windows/consumer-vm.yaml`](../../manifests/windows/consumer-vm.yaml) | Full consumer VM example |
| Lifecycle | [`manifests/lifecycle/cleanup-cronjob.yaml`](../../manifests/lifecycle/cleanup-cronjob.yaml) | Deprecated image cleanup CronJob |

**Architecture diagram:** [`diagrams/golden-template-pipeline.drawio`](../../diagrams/golden-template-pipeline.drawio)

---
```

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/specs/2026-04-14-golden-template-pipeline-design.md
git commit -m "docs: add manifest file reference table and diagram link to spec"
```

---

### Task 8: Final Validation

- [ ] **Step 1: Validate all YAML files parse correctly**

Run: `find manifests -name '*.yaml' -exec sh -c 'echo "--- {} ---"; python3 -c "import yaml, sys; yaml.safe_load(open(\"{}\")); print(\"OK\")"' \;`

Expected: All files print `OK`.

- [ ] **Step 2: Verify all relative links in the spec resolve**

Run: `grep -oP '\(\.\./.+?\)' docs/superpowers/specs/2026-04-14-golden-template-pipeline-design.md | tr -d '()' | while read f; do base="docs/superpowers/specs"; resolved=$(cd "$base" && realpath "$f" 2>/dev/null); if [ -f "$resolved" ]; then echo "OK: $f"; else echo "MISSING: $f"; fi; done`

Expected: All files print `OK:`.

- [ ] **Step 3: Verify the draw.io file is well-formed XML**

Run: `python3 -c "import xml.etree.ElementTree as ET; ET.parse('diagrams/golden-template-pipeline.drawio'); print('OK')"`

Expected: `OK`

- [ ] **Step 4: Commit if any fixes were needed**

```bash
git add -A
git status  # should show nothing to commit if all passed
```
