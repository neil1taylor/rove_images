# Image Pipeline Expansion — PRD / Design

**Date:** 2026-04-26
**Status:** Draft, pending user review
**Cluster context:** nrt-prod-cluster1
**Author:** Neil Taylor (with Claude)

---

## 1. Problem and goals

### 1.1 Problem

The repository currently has three working golden-image pipelines: one Linux pipeline and two Windows variants (Server 2022 BIOS, Server 2022 UEFI). MTV migrations from a generic VMware enterprise estate land on OpenShift Virtualization with no matching golden image / preference / instancetype for the majority of source OSes — admins must build images manually or skip the catalogue entry.

### 1.2 Goals

- Provide a working golden-image pipeline for every OS in a generic enterprise VMware estate, so MTV migrations always have a target preference and instancetype.
- Provide a hardened (CIS L1) sibling pipeline for every OS in the matrix, so security-baseline images are first-class catalogue citizens.
- Eliminate the per-pipeline duplication that the current ~440-line BIOS/UEFI pair makes apparent. The 30-pipeline matrix would be unmaintainable if each variant kept the existing copy-paste shape.
- Keep the deployment story simple: `oc apply -k` per variant, no new infrastructure, no new tools.

### 1.3 Non-goals (firm)

- No registry publishing — cluster catalogue only.
- No scheduled rebuilds, no git triggers — on-demand only.
- No new OSes outside the agreed matrix (no Fedora, Debian, Oracle Linux, Photon, Windows client SKUs).
- No retrofit of the existing Linux pipeline or Win Server 2022 pipelines into the new layout *during the pilot* — Batch 4 picks up the Windows refactor; Batch 3 reviews the existing Linux pipeline.
- No CI/CD / Helm / additional templating tools beyond Kustomize.

### 1.4 Success criteria (programme-level)

The expansion is successful when:

1. 30 pipelines exist in `manifests/<class>/<variant>/` form, each deployable with a single `oc apply -k`.
2. Each pipeline completes a successful end-to-end run at least once, producing a usable `DataSource` in the cluster catalogue with correct labels.
3. Adding a 31st variant requires only a new variant directory — no edits to `shared-tasks/`, `boot-trigger-tasks/`, or any other variant. *This is the durable test of whether the templating worked.*
4. MTV migrations have a target preference + instancetype for every OS in a generic enterprise estate.
5. Hardened siblings pass their CIS L1 baseline scan at the threshold defined in §5.2, with documented exceptions tracked in the variant's README.
6. The existing Linux pipeline and Win Server 2022 BIOS/UEFI pipelines are consolidated into the new layout by end of Batch 4, with no behaviour change.
7. The non-goals from §1.3 hold — no registry, no scheduler, no triggers.

---

## 2. Architecture

### 2.1 Repository layout

```
manifests/
├── pipelines/
│   ├── shared-tasks/                      # cluster-applied reusable Tasks (used by all variants)
│   │   ├── upload-source-artefact.yaml    # HTTP→DataVolume, idempotent (handles ISO + cloud-img)
│   │   ├── create-blank-root-disk.yaml
│   │   ├── wait-for-vm-shutdown.yaml      # polls VMI phase until Succeeded
│   │   ├── clone-to-catalog.yaml          # clone build PVC → openshift-virtualization-os-images,
│   │   │                                  # create DataSource with instancetype/preference labels
│   │   └── cleanup-build-namespace.yaml
│   └── boot-trigger-tasks/                # OS-class-specific, not per-OS
│       ├── trigger-cd-boot-uefi.yaml      # OVMF boot-manager dance (existing)
│       ├── trigger-cd-boot-bios.yaml      # legacy BIOS keypress (existing)
│       └── trigger-cd-boot-linux.yaml     # kickstart/preseed/autoinstall — usually no keypress
├── linux/
│   ├── rhel-9/                            # per-variant overlay directory
│   │   ├── kustomization.yaml
│   │   ├── pipeline.yaml                  # thin (~80–100 lines): wires shared Tasks + installer VM
│   │   ├── pipelinerun.yaml
│   │   ├── pipeline-rbac.yaml
│   │   ├── unattended-configmap.yaml      # kickstart (vanilla)
│   │   └── README.md
│   ├── rhel-9-hardened/                   # sibling overlay; same structure, hardened kickstart
│   ├── rhel-8/                            # ... and so on for every variant
│   └── ...
└── windows/
    ├── server-2022-uefi/                  # existing pipelines refactored into this layout in Batch 4
    ├── server-2022-uefi-hardened/
    ├── server-2025-uefi/                  # pilot
    ├── server-2025-uefi-hardened/         # pilot
    └── ...
```

### 2.2 Architectural principles

- **Shared Tasks** are applied once cluster-wide; per-variant pipelines reference them by name.
- **Per-variant Pipeline** is short and readable: a `params:` block, then a `tasks:` list calling shared Tasks plus one or two OS-specific inline `taskSpec`s (the installer VM, the boot-trigger).
- **Kustomize overlay** at each variant directory bundles the per-variant ConfigMaps, RBAC, and PipelineRun template — `oc apply -k manifests/linux/rhel-9/` deploys everything for that variant.
- **Output namespace** is `openshift-virtualization-os-images` (unchanged from current pattern).
- **No conditional logic** in pipelines — variants differ by composition (which Tasks they call, which ConfigMap they reference), not by `when:` clauses or branches inside a single Pipeline. Conditionals are explicitly rejected (Approach 2 in design exploration).

### 2.3 Approach considered and rejected

- **Kustomize overlays over a single base Pipeline** (single base manifest, per-variant overlay patches everything) — rejected because OS-specific divergence (UEFI boot-key dance vs BIOS vs Linux kickstart) becomes a conditional sprawl inside the base Pipeline.
- **Helm chart per OS family** — rejected because it introduces Helm to a plain-YAML repo, and `values.yaml` becomes its own DSL the team has to learn.
- **Tekton-native parameterisation (one Pipeline per OS family with osVariant params)** — rejected because the unattended-install mechanisms and installer-VM specs differ enough between OSes that a single parameterised Pipeline per family becomes a tangle of `when:` and `params:` defaults.

---

## 3. OS matrix

| # | OS | Release | EOL status | Boot | Build method | Vanilla | Hardened |
|---|---|---|---|---|---|---|---|
| 1 | RHEL | 7 | EOL Jun 2024 | BIOS | kickstart | ✓ | ✓ |
| 2 | RHEL | 8 | Maint until May 2029 | UEFI | kickstart | ✓ | ✓ |
| 3 | RHEL | 9 | Full until May 2027 | UEFI | kickstart | ✓ | ✓ |
| 4 | Rocky Linux | 8 | May 2029 | UEFI | kickstart | ✓ | ✓ |
| 5 | Rocky Linux | 9 | May 2032 | UEFI | kickstart | ✓ | ✓ |
| 6 | AlmaLinux | 8 | May 2029 | UEFI | kickstart | ✓ | ✓ |
| 7 | AlmaLinux | 9 | May 2032 | UEFI | kickstart | ✓ | ✓ |
| 8 | Ubuntu | 22.04 LTS | Apr 2027 (std) | UEFI | autoinstall (cloud-init) | ✓ | ✓ |
| 9 | Ubuntu | 24.04 LTS | Apr 2029 (std) | UEFI | autoinstall (cloud-init) | ✓ | ✓ |
| 10 | SLES | 15 SP6 | Jul 2031 (LTSS) | UEFI | AutoYaST | ✓ | ✓ |
| 11 | Win Server | 2012 R2 | EOL Oct 2023 | BIOS | Autounattend | ✓ | ✓ |
| 12 | Win Server | 2016 | EOS Jan 2027 | UEFI | Autounattend | ✓ | ✓ |
| 13 | Win Server | 2019 | EOS Jan 2029 | UEFI | Autounattend | ✓ | ✓ |
| 14 | Win Server | 2022 | EOS Oct 2031 | UEFI | Autounattend | ✓ (existing — refactor in Batch 4) | ✓ |
| 15 | Win Server | 2025 | EOS Oct 2034 | UEFI | Autounattend | ✓ | ✓ |

**Total: 15 vanilla + 15 hardened = 30 pipelines.**

### 3.1 Matrix notes

- **RHEL 7 + Server 2012R2** are flagged BIOS — these predate widespread UEFI in their default install paths. Pipelines for these reuse the existing BIOS scaffold; everything else uses UEFI.
- **EOL OSes are included** (RHEL 7, Server 2012R2) because migration sources often include them; a working golden image is more valuable than a clean catalogue. Hardening on these is best-effort (see R5 in §6.2).
- **SLES** assumes entitled access for AutoYaST + repos. If unavailable, drop SLES (variants 10) and reduce the matrix to 28 pipelines. See decision D3 in §6.3.
- **Out of matrix:** Windows client SKUs (10/11), Fedora, Debian, Oracle Linux, Photon — easy to add later via the same template, but not in scope.

---

## 4. Per-variant componentry

### 4.1 What is identical across all 30 variants

- The shared Tasks (§2.1) — applied once cluster-wide.
- The Pipeline structural shape: `upload-source-artefact` → `create-blank-root-disk` → `create-installer-vm` → `trigger-boot` → `wait-for-vm-shutdown` → `clone-to-catalog` → `cleanup`.
- Build namespace, ServiceAccount, Role/RoleBinding pattern.
- Output: a `DataVolume` + `DataSource` in `openshift-virtualization-os-images` with instancetype/preference labels.

### 4.2 What varies (4 swappable pieces)

| Swappable | Linux examples | Windows examples |
|---|---|---|
| **(a) Unattended-install ConfigMap** | `kickstart-configmap.yaml` (RHEL/Rocky/Alma) · `autoinstall-configmap.yaml` (Ubuntu) · `autoyast-configmap.yaml` (SLES) | `autounattend-configmap.yaml` (with embedded sysprep + first-boot scripts) |
| **(b) Installer-VM spec** | 1 disk + 1 ISO CDROM. CPU/mem moderate (2 vCPU / 4 Gi). No virtio-win. | 1 disk + 2 CDROMs (OS ISO, virtio-win). CPU/mem higher (4 vCPU / 8 Gi). Hyper-V features + clock policies (existing). |
| **(c) Boot-trigger Task ref** | `trigger-cd-boot-linux` (most distros boot the installer from ISO directly with no keypress; RHEL 7 BIOS may need a brief keypress). | `trigger-cd-boot-uefi` (existing OVMF dance) for 2016/2019/2022/2025; `trigger-cd-boot-bios` (existing) for 2012R2. |
| **(d) Catalog labels** | `default-instancetype: u1.medium` · `default-preference: rhel.9` / `centos.stream9` / `ubuntu` / `opensuse.leap` | `u1.2xlarge` · `windows.2k19` / `windows.2k22` / `windows.2k25` |

### 4.3 Naming convention

Across DV, VM, ConfigMap, Pipeline, PipelineRun, DataSource:

```
<os-short>-<version>[-hardened]

e.g.  rhel-9          rhel-9-hardened
      ubuntu-2404     ubuntu-2404-hardened
      win-2k25-uefi   win-2k25-uefi-hardened
```

The `-hardened` suffix is the only way the variant pair differs in cluster-visible names — preventing the catalogue from showing two ambiguous "RHEL 9" entries.

### 4.4 Per-variant directory contents

```
manifests/<class>/<variant>/
├── kustomization.yaml          # lists the resources below + sets the namespace
├── pipeline.yaml               # thin Pipeline (~80–100 lines)
├── pipelinerun.yaml            # parameterised, ready to `oc create`
├── pipeline-rbac.yaml          # SA + RoleBinding for the build namespace
├── unattended-configmap.yaml   # (a) above — kickstart/autoinstall/AutoYaST/Autounattend
└── README.md                   # variant-specific notes (ISO source URL, hardened baseline ref, gotchas)
```

---

## 5. Hardened-variant policy

### 5.1 Where hardening happens

Hardening lives in the unattended-install ConfigMap, not as a separate pipeline stage. The hardened variant's pipeline is structurally identical to its vanilla sibling — only swappable piece (a) from §4.2 differs. Reasons:

- One pipeline shape across all 30 variants.
- Hardening captured in a single auditable file per variant, versioned in git.
- Avoids a "post-harden" task running after Sysprep/cloud-init clean — that ordering is fragile.

### 5.2 Hardening mechanism per OS class

| OS class | Mechanism | Embedded in | Source |
|---|---|---|---|
| RHEL 7/8/9, Rocky 8/9, Alma 8/9 | OpenSCAP (`oscap xccdf eval --remediate`) using `scap-security-guide` | Kickstart `%post` | `scap-security-guide` package, profile selected at run time |
| Ubuntu 22.04 / 24.04 | OpenSCAP using `ssg-ubuntu` | autoinstall `late-commands` | `ssg-ubuntu2204` / `ssg-ubuntu2404` |
| SLES 15 | OpenSCAP using `ssg-sle15` | AutoYaST `<post-scripts>` | `scap-security-guide` (SUSE build) |
| Windows Server 2012R2 → 2025 | Microsoft Security Compliance Toolkit (LGPO.exe + GPO backups) + small PowerShell wrapper | Autounattend `FirstLogonCommands` (runs before Sysprep generalize) | Microsoft SCT downloaded inside the installer VM (see R3 in §6.2) |

A single SCAP toolchain across all six Linux distros is the strongest argument for this approach — one set of instructions to debug, not five.

### 5.3 Hardened baseline

**Default: CIS Benchmark Level 1 Server** across all 15 hardened variants.

- L1 is the universal common denominator — applies to every OS, doesn't break common server roles, and SCAP/SCT both ship CIS L1 profiles for every OS in scope.
- DISA STIG is more restrictive and common in regulated environments; profiles aren't uniformly mature across all OSes (Rocky/Alma reuse the RHEL profile — "close enough" but not formally accredited).
- A stricter baseline later is a third sibling variant (`-stig`) using the same pipeline shape.

Decision pending — see D1 in §6.3.

### 5.4 Catalogue distinction

Hardened siblings appear in the catalogue alongside vanilla with:

- **Name:** `<variant>-hardened` (per §4.3).
- **DataSource label:** `compliance.kubevirt.io/baseline: cis-l1` (custom — consumers can filter by it; ignored if unused).
- **Preference / instancetype:** unchanged from vanilla (a hardened RHEL 9 still wants the `rhel.9` preference).

### 5.5 Audit trail

For each hardened build the pipeline emits an artefact:

- A SCAP results XML (Linux) or LGPO log (Windows) attached as a build-namespace `ConfigMap` named `<variant>-<run-id>-compliance-report`, retained for 30 days, then garbage-collected by the existing cleanup CronJob.
- The kickstart/Autounattend file itself is the canonical "what we hardened" record — already in git.

Whether 30-day retention suffices depends on regulatory posture. Decision pending — D2 in §6.3.

---

## 6. Pilot and sequencing

### 6.1 Pilot scope (Batch 1)

**4 pipelines:** RHEL 9 vanilla + hardened, Win Server 2025 vanilla + hardened.

Hardened siblings are included in the pilot deliberately — if we ship vanilla-only and discover the SCAP/SCT mechanism is fragile during Batch 2, we must retrofit hardening across every variant already shipped. Validating both classes in Batch 1 proves the templating pattern end-to-end before mass production.

Why these two OSes:

- **RHEL 9** exercises the kickstart + OpenSCAP path that Rocky/Alma reuse with minor profile changes — proving it here unblocks 6 downstream variants.
- **Win Server 2025** exercises the Autounattend + Sysprep + LGPO path on the newest variant (most likely to surface tooling gaps); the existing Win Server 2022 UEFI pipeline gives a known-good reference.
- Together they cover both OS classes, both unattended-install mechanisms in scope, and both hardening toolchains.

### 6.2 Pilot acceptance criteria

The pilot is "done" when **all** of these hold:

1. All 4 PipelineRuns complete successfully on `nrt-prod-cluster1` from a clean build namespace, end-to-end, without manual intervention.
2. All 4 produce a `DataSource` in `openshift-virtualization-os-images` with correct instancetype + preference labels and (for hardened) the `compliance.kubevirt.io/baseline: cis-l1` label.
3. A test consumer VM created from each DataSource boots, reaches a login prompt, and reports `AgentConnected=True`.
4. Hardened variants pass a CIS L1 scan post-build: ≥ 90% pass rate of applicable rules on `oscap xccdf eval` (Linux) and on Microsoft Policy Analyzer comparison (Windows), with non-applicable rules excluded from the denominator. Non-passing applicable rules are documented exceptions in the variant's README, not surprises.
5. Existing Win Server 2022 BIOS/UEFI pipelines remain functional — refactoring them is *not* part of the pilot.
6. `oc apply -k manifests/<class>/<variant>/` deploys a complete pipeline including RBAC and ConfigMaps, with no imperative `oc create` steps.
7. **Pattern-reuse test:** scaffolding a 5th variant (e.g. RHEL 8) in a scratch branch requires only adding `manifests/linux/rhel-8/` — zero edits to `shared-tasks/` or `boot-trigger-tasks/`. *This is the actual templating proof.*
8. Per-variant README in each pilot directory covers ISO source URL, hardened baseline reference, expected runtime, and known gotchas.

### 6.3 Sequencing after pilot

Each batch gets its own implementation plan (`writing-plans` invocation per batch). This PRD covers the full matrix; the immediate next step is Batch 1 only.

| Batch | Scope | Pipelines | Risk to retire |
|---|---|---|---|
| 1 (pilot) | RHEL 9, Win Server 2025 — vanilla + hardened | 4 | Templating pattern, both hardening toolchains |
| 2 | RHEL 8, Rocky 8/9, Alma 8/9 — vanilla + hardened | 10 | Profile reuse for RHEL-family clones |
| 3 | Ubuntu 22.04 / 24.04, SLES 15 — vanilla + hardened | 6 | Non-kickstart unattended (autoinstall, AutoYaST) |
| 4 | Win Server 2019 / 2022 — vanilla + hardened, **plus** refactor existing 2022 pipelines into new layout | 4 | Backwards-compatibility for the existing working pipeline |
| 5 | RHEL 7, Win Server 2012R2 / 2016 — vanilla + hardened (BIOS-class) | 6 | EOL toolchain availability (ssg for RHEL 7, SCT compatibility on 2012R2) |
| **Total** | | **30** | |

---

## 7. Risks and decisions

### 7.1 Key risks

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| R1 | Vendor-direct ISO URLs drift or expire mid-build, breaking pipelines. | High | Medium | Each variant README pins the expected upstream URL pattern; pipeline param overrides per run; flag for revisit if breakage rate > 1/month. |
| R2 | `scap-security-guide` version drift between runs (vendor-direct sourcing) means hardened variants aren't reproducible across time. | High | Medium | Capture ssg version in the build's compliance-report artefact; raise to user if reproducibility becomes a compliance requirement. |
| R3 | Microsoft Security Compliance Toolkit downloads aren't versioned/stable URLs. | High | High (blocks Win hardened) | **Pre-pilot spike:** validate SCT download path during Batch 1; if unstable, mirror SCT to internal storage as a one-off exception to the vendor-direct sourcing rule. |
| R4 | Existing Win Server 2022 pipelines break during Batch 4 refactor. | Medium | High | Refactor in a parallel directory first (`server-2022-uefi-v2/`), validate, then swap; old directory retained for one batch as rollback. |
| R5 | EOL OSes (RHEL 7, Win Server 2012R2) lack maintained SCAP/SCT content; hardening profile may be stale or missing. | Medium | Low (Batch 5 only) | Document baseline gaps in those variants' READMEs; user accepts EOL = best-effort hardening. |
| R6 | OVMF boot-key dance and BIOS keypress timing are flaky (already observed on existing pipelines). | Medium | Medium | Boot-trigger Tasks isolated and reusable — fixes propagate to all variants in the class at once, rather than per-pipeline. |
| R7 | SLES entitlement / repo access not in place. | Medium | Medium (drops 2 of 30) | Confirm during PRD review (D3 below); if absent, drop SLES from matrix. |
| R8 | Privileged pod requirement for libguestfs/buildah at namespace level conflicts with cluster SCC policy. | Low | High | The current pipelines already work at `nrt-prod-cluster1`; pattern is proven. |
| R9 | Scope creep into "while we're at it, let's add registry/scheduling/triggers." | Medium | Medium | §1.3 non-goals are firm; revisit only via a new PRD. |

### 7.2 Open decisions

These must be resolved in or before the Batch 1 technical plan:

- **D1.** Hardened baseline — CIS L1 (recommended) or DISA STIG?
- **D2.** Audit retention — 30-day in-cluster (recommended) or push to long-term storage (S3/COS)?
- **D3.** SLES inclusion — confirm entitled access; drop from matrix if absent.
- **D4.** Build namespace strategy — single `image-build` or per-class (`linux-image-build` / `windows-image-build`, mirroring today)?
- **D5.** `Task` vs `ClusterTask` vs `StepActions` for the shared-tasks layer. *Recommend `Task` per build namespace, applied via Kustomize, to avoid cluster-scoped RBAC sprawl.*
- **D6.** Microsoft SCT mirror — confirmed pre-pilot during the R3 spike, or accept the risk?
- **D7.** Installer-VM spec location — inline in each variant's pipeline (recommended) vs shared per-class Task.

---

## 8. Inputs captured

The decisions that shaped this PRD, captured as a record:

| # | Question | Answer |
|---|---|---|
| Q1 | Audience and primary driver | A — Internal infra team only; operational coverage for MTV migrations |
| Q2 | Source-estate visibility | C — Assume generic enterprise mix |
| Q3 | EOL OS handling | A — Include them |
| Q4 | Hardened/compliance variants | A — Mandatory hardened sibling per OS |
| Q5 | Source artefact hosting | B — Vendor-direct URLs each run |
| Q6 | Output: catalogue vs registry | A — Cluster catalogue only |
| Q7 | Build cadence | A — On-demand only |
| Q8 | Delivery sequencing | A — Templating + 2 pilot OSes (RHEL 9 + Win Server 2025), then batches |

Templating approach selected: Option 1 — reusable Tasks + thin per-OS Pipelines + Kustomize overlays per variant directory.
