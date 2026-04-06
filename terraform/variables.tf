variable "proxmox_endpoint" {
  description = "Proxmox API endpoint URL"
  type        = string
  default     = "https://192.168.0.238:8006"
}

variable "proxmox_api_token" {
  description = "Proxmox API token (user!tokenid=secret)"
  type        = string
  sensitive   = true
}

variable "proxmox_node" {
  description = "Proxmox node name"
  type        = string
  default     = "pve"
}

variable "vm_name" {
  description = "VM hostname"
  type        = string
  default     = "geocoder-test"
}

variable "vm_id" {
  description = "Proxmox VM ID (0 = auto-assign)"
  type        = number
  default     = 0
}

variable "vm_cores" {
  description = "Number of CPU cores"
  type        = number
  default     = 8
}

variable "vm_memory" {
  description = "RAM in MB"
  type        = number
  default     = 32768
}

variable "os_disk_size" {
  description = "OS disk size in GB"
  type        = number
  default     = 50
}

variable "data_disk_size" {
  description = "Data disk size in GB (/data mount)"
  type        = number
  default     = 300
}

variable "os_disk_storage" {
  description = "Proxmox storage pool for OS disk"
  type        = string
  default     = "local"
}

variable "data_disk_storage" {
  description = "Proxmox storage pool for data disk"
  type        = string
  default     = "vmdata"
}

variable "iso_file" {
  description = "Debian ISO image on Proxmox local storage"
  type        = string
  default     = "local:iso/debian-13.3.0-amd64-netinst.iso"
}

variable "network_bridge" {
  description = "Network bridge"
  type        = string
  default     = "vmbr0"
}

variable "resource_pool" {
  description = "Proxmox resource pool"
  type        = string
  default     = "AI"
}

variable "ssh_public_key" {
  description = "SSH public key for root access"
  type        = string
  default     = ""
}
