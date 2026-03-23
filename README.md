# RHEL 9 Golden Image Pipeline

Automated CIS Level 1 hardened VM image pipeline for Red Hat Enterprise Linux 9, built with Packer and GitHub Actions. Publishes to Azure Compute Gallery with East/West region replication.

---

## What This Is

This pipeline solves a real problem in regulated and enterprise cloud environments: every VM that gets deployed should start from a known-good, security-hardened baseline — not a raw marketplace image. Deploying from a raw image means each team handles hardening differently, or skips it entirely.

This repo automates the creation of a **golden image** — a pre-hardened RHEL 9 snapshot that gets published to Azure Compute Gallery. Any VM deployed from this image starts life already CIS Level 1 compliant, with SELinux enforcing, firewalld active, auditd running, and unnecessary services stripped out.

The pipeline runs on every push to `main` via GitHub Actions. Packer builds the image in Azure, runs the hardening scripts, validates the result, and publishes the versioned image to the gallery. No manual steps.

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                  GitHub Actions                      │
│  push to main → trigger pipeline                     │
└────────────────────┬────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────┐
│                  Packer Build                        │
│  1. Authenticate to Azure via Service Principal      │
│  2. Spin up temporary build VM (RHEL 9 marketplace)  │
│  3. Run hardening scripts via SSH                    │
│  4. Validate and generalize the image                │
│  5. Capture image version                            │
└────────────────────┬────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────┐
│            Azure Compute Gallery                     │
│  Gallery:    gal_golden_images_charles               │
│  Definition: rhel-9-cis                              │
│  Versions:   0.YYYYMMDD.HHMM (auto-versioned)       │
│  Replication: East US + West US                      │
└─────────────────────────────────────────────────────┘
```

### Why This Design

**Packer** handles image creation because it abstracts the build VM lifecycle — it spins up a temporary VM, runs provisioners, captures the image, and destroys the build VM automatically. No leftover resources, no manual cleanup.

**GitHub Actions** as the CI/CD layer means every image build is traceable to a commit. You know exactly what code produced what image version. The pipeline uses GitHub Secrets for credentials so nothing sensitive lives in the repo.

**Azure Compute Gallery** (formerly Shared Image Gallery) is the distribution layer. It stores versioned image definitions and replicates them across regions. When you deploy a VM from a gallery image, Azure picks the nearest replica — no cross-region bandwidth costs.

**East + West replication** supports the standard DR pattern. Production VMs in East US and DR VMs in West US both get their image from a local replica.

---

## Infrastructure (Terraform)

All Azure resources are provisioned with Terraform under `infra/`. Run once to bootstrap — the pipeline uses these resources on every run.

| Resource | Name | Purpose |
|---|---|---|
| Resource Group | `rg-golden-images-charles` | Container for all pipeline resources |
| Shared Image Gallery | `gal_golden_images_charles` | Stores and replicates image versions |
| Image Definition | `rhel-9-cis` | Metadata: OS type, publisher, offer, SKU |
| Service Principal | `sp-packer-golden-images-charles` | Identity used by Packer to authenticate |
| Role Assignment | Contributor on RG | Allows Packer to create/delete build VMs |

```bash
cd infra/
terraform init
terraform apply
```

After apply, capture the outputs — you'll need them for GitHub Secrets:

```bash
terraform output -raw packer_client_id       # → AZURE_CLIENT_ID
terraform output -raw packer_client_secret   # → AZURE_CLIENT_SECRET
terraform output -raw tenant_id              # → AZURE_TENANT_ID
terraform output -raw subscription_id        # → AZURE_SUBSCRIPTION_ID
```

---

## Packer Configuration

```
packer/
├── rhel9.pkr.hcl          # Main Packer template
├── variables.pkrvars.hcl  # Variable values (no secrets)
└── scripts/
    ├── hardening.sh        # CIS Level 1 controls
    └── cleanup.sh          # Pre-capture generalization
```

### Build VM Spec

Packer spins up a temporary VM using the RHEL 9 marketplace image:

```hcl
image_publisher = "RedHat"
image_offer     = "RHEL"
image_sku       = "9-lvm-gen2"
vm_size         = "Standard_D2s_v3"
```

The build VM exists only long enough to run the hardening scripts. Packer destroys it after image capture.

---

## Hardening Controls (CIS Level 1)

All controls run via `hardening.sh` during the Packer provisioner phase:

| Control | Implementation |
|---|---|
| SELinux | Set to `enforcing` in `/etc/selinux/config` |
| Firewall | `firewalld` enabled and started |
| Package updates | `dnf update -y` on every build |
| Audit daemon | `auditd` enabled with basic ruleset |
| SSH hardening | Root login disabled, protocol 2 enforced |
| Sysctl | Network hardening params set (IP forwarding off, ICMP redirect disabled) |
| PAM | Password complexity and lockout policy configured |
| Unused services | Unnecessary daemons disabled |

### Why CIS Level 1

Level 1 is the baseline — controls that have minimal impact on functionality but meaningfully reduce attack surface. Level 2 is more aggressive and can break workloads if applied blindly. For a golden image that many teams will consume, Level 1 is the right default. Teams that need Level 2 controls can layer them on top for their specific workloads.

---

## GitHub Actions Pipeline

The workflow lives at `.github/workflows/packer-build.yml` and triggers on every push to `main`.

### Required Secrets

Set these in **Settings → Secrets and variables → Actions**:

| Secret | Source |
|---|---|
| `AZURE_CLIENT_ID` | `terraform output -raw packer_client_id` |
| `AZURE_CLIENT_SECRET` | `terraform output -raw packer_client_secret` |
| `AZURE_TENANT_ID` | `terraform output -raw tenant_id` |
| `AZURE_SUBSCRIPTION_ID` | `terraform output -raw subscription_id` |
| `AZURE_RESOURCE_GROUP` | `rg-golden-images-charles` |

### Pipeline Steps

```
1. Checkout code
2. Install Packer
3. Azure login (via service principal JSON creds)
4. packer init
5. packer validate
6. packer build
   └── Spin up build VM
   └── Run hardening.sh
   └── Run cleanup.sh
   └── Capture image → publish to gallery
   └── Destroy build VM
```

Build takes approximately 15-20 minutes end to end. Image version is auto-generated as `0.YYYYMMDD.HHMM`.

---

## Repository Structure

```
rhel-hardening-001/
├── .github/
│   └── workflows/
│       └── packer-build.yml      # CI/CD pipeline
├── infra/
│   ├── main.tf                   # Azure resources
│   ├── variables.tf
│   ├── outputs.tf
│   └── terraform.tfvars
├── packer/
│   ├── rhel9.pkr.hcl             # Packer template
│   ├── variables.pkrvars.hcl     # Variable values
│   └── scripts/
│       ├── hardening.sh          # CIS Level 1 controls
│       └── cleanup.sh            # Pre-capture cleanup
└── README.md
```

---

## Running Locally

To trigger a build manually without going through GitHub Actions:

```bash
cd packer/

# Set credentials as environment variables
export ARM_CLIENT_ID="<client_id>"
export ARM_CLIENT_SECRET="<client_secret>"
export ARM_TENANT_ID="<tenant_id>"
export ARM_SUBSCRIPTION_ID="<subscription_id>"

# Build
packer init rhel9.pkr.hcl
packer validate -var-file=variables.pkrvars.hcl rhel9.pkr.hcl
packer build -var-file=variables.pkrvars.hcl rhel9.pkr.hcl
```

The published image will appear in the Azure portal under:
**Compute Galleries → gal_golden_images_charles → rhel-9-cis → Versions**

---

## Deploying a VM From the Image

Once an image version is published, reference it in Terraform:

```hcl
source_image_id = "/subscriptions/<sub>/resourceGroups/rg-golden-images-charles/providers/Microsoft.Compute/galleries/gal_golden_images_charles/images/rhel-9-cis/versions/latest"
```

Or in the Azure portal: **Virtual Machines → Create → See all images → My images → rhel-9-cis**

---

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `Tenant not found` | `AZURE_TENANT_ID` secret is wrong or missing | Re-add from `terraform output -raw tenant_id` |
| `gallery_name not found` | Gallery name mismatch between Terraform output and Packer vars | Confirm `gal_golden_images_charles` in both |
| `image_publisher` error | Wrong publisher for RHEL | Use `RedHat` not `Canonical` |
| `cleanup.sh` fails on dbus symlink | `/var/lib/dbus` directory missing | `mkdir -p /var/lib/dbus` added to cleanup.sh |
| Build VM left running | Packer crashed before capture | Delete manually in portal under `rg-golden-images-charles` |
