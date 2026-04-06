# Copyright 2026 Glenn Plas / Bitless BVBA
# SPDX-License-Identifier: Apache-2.0

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.78"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}
