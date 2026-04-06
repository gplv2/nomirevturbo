provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token

  insecure = true # Self-signed cert on Proxmox

  ssh {
    agent = true
  }
}

resource "proxmox_virtual_environment_vm" "geocoder" {
  name      = var.vm_name
  node_name = var.proxmox_node
  vm_id     = var.vm_id > 0 ? var.vm_id : null
  pool_id   = var.resource_pool

  description = "Nomirevturbo geocoder test VM - managed by Terraform"
  tags        = ["terraform", "geocoder", "test"]

  # Hardware
  cpu {
    cores = var.vm_cores
    type  = "host"
  }

  memory {
    dedicated = var.vm_memory
  }

  # Boot from ISO for initial install
  cdrom {
    file_id = var.iso_file
  }

  # OS disk
  disk {
    datastore_id = var.os_disk_storage
    interface    = "scsi0"
    size         = var.os_disk_size
    file_format  = "raw"
  }

  # Data disk (/data) for PBF downloads + geocoder index
  disk {
    datastore_id = var.data_disk_storage
    interface    = "scsi1"
    size         = var.data_disk_size
    file_format  = "raw"
  }

  # SCSI controller
  scsi_hardware = "virtio-scsi-single"

  # Network
  network_device {
    bridge = var.network_bridge
    model  = "virtio"
  }

  # Boot order: disk first, then cdrom (after install, remove ISO)
  boot_order = ["scsi0", "ide2"]

  # BIOS
  bios = "seabios"

  # Agent
  agent {
    enabled = true
  }

  operating_system {
    type = "l26"
  }
}

output "vm_id" {
  description = "Proxmox VM ID"
  value       = proxmox_virtual_environment_vm.geocoder.vm_id
}

output "vm_name" {
  description = "VM name"
  value       = proxmox_virtual_environment_vm.geocoder.name
}

output "vm_ipv4" {
  description = "VM IPv4 address (available after guest agent starts)"
  value       = try(proxmox_virtual_environment_vm.geocoder.ipv4_addresses, "pending - install OS and start qemu-guest-agent")
}
