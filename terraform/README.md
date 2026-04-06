# Terraform - Proxmox Test VM

Spins up a Debian 13 VM on Proxmox for testing the Ansible geocoder role.

## Prerequisites

- Terraform >= 1.5
- Proxmox VE 8.x with API token (`Datacenter > Permissions > API Tokens`)
- Debian 13 netinst ISO uploaded to Proxmox local storage

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your API token

terraform init
terraform plan
terraform apply
```

The VM boots from the Debian ISO. Complete the install manually via the Proxmox console (VNC), then run Ansible:

```bash
# After install, get the VM IP from Proxmox or:
terraform output vm_ipv4

# Update ansible inventory
cd ../ansible
# Set ansible_host in inventory/test.yml

ansible-playbook -i inventory/test.yml playbook.yml
```

## VM Spec

| Resource | Default |
|----------|---------|
| CPU | 8 cores (host passthrough) |
| RAM | 32 GB |
| OS disk | 50 GB on `local` |
| Data disk | 300 GB on `vmdata` (mounted at `/data`) |
| Network | vmbr0 (DHCP) |
| Pool | AI |

## Teardown

```bash
terraform destroy
```
