# Terraform - Proxmox Test VM

Spins up a Debian 13 VM on Proxmox for testing the Ansible geocoder role. Uses the Debian cloud image with cloud-init for fully headless provisioning -- no manual OS install needed.

## Prerequisites

- Terraform >= 1.5
- Proxmox VE 8.x with API token (`Datacenter > Permissions > API Tokens`)
- `local` storage must have "Snippets" content type enabled (for cloud-init config)

### Enable snippets on local storage

In Proxmox UI: `Datacenter > Storage > local > Edit > Content` -- add "Snippets" to the list.

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your API token and SSH key

terraform init
terraform plan
terraform apply
```

The VM boots from the Debian 13 cloud image, configures itself via cloud-init (SSH keys, data disk mount, packages), and is ready for Ansible within ~60 seconds.

```bash
# Get the VM IP
terraform output vm_ipv4

# Run Ansible
cd ../ansible
# Update ansible_host in inventory/test.yml with the IP
ansible-playbook -i inventory/test.yml playbook.yml
```

## What cloud-init does

- Creates `root` and `glenn` users with SSH key access
- `glenn` has passwordless sudo
- Formats `/dev/sdb` as ext4 and mounts at `/data`
- Installs `qemu-guest-agent`, `python3`, `sudo`

## Cloud image

The Debian 13 generic cloud image is downloaded once to Proxmox storage and reused for all future VMs. Terraform manages it as a resource -- it won't re-download on subsequent `apply` runs.

## VM spec

| Resource | Default |
|----------|---------|
| CPU | 8 cores (host passthrough) |
| RAM | 32 GB |
| OS disk | 50 GB on `local` (cloud image expanded) |
| Data disk | 300 GB on `vmdata` (mounted at `/data`) |
| Network | vmbr0 (DHCP) |
| Pool | AI |

## Teardown

```bash
terraform destroy
```

This destroys the VM but keeps the cloud image on Proxmox for reuse.
