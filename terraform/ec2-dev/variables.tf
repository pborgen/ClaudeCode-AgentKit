variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type for the dev box."
  type        = string
  default     = "t3.small"
}

variable "root_volume_gb" {
  description = "Size of the root EBS volume in GB."
  type        = number
  default     = 30
}

variable "tailscale_auth_key" {
  description = "Tailscale auth key used to join the tailnet on first boot. Use a reusable + ephemeral key from https://login.tailscale.com/admin/settings/keys"
  type        = string
  sensitive   = true
}

variable "hostname" {
  description = "Tailscale hostname for the box. You connect with: ssh ubuntu@<hostname>"
  type        = string
  default     = "claude-dev"
}

variable "project_name" {
  description = "Name prefix applied to created resources."
  type        = string
  default     = "claude-code-dev"
}

variable "tags" {
  description = "Extra tags merged onto every resource."
  type        = map(string)
  default     = {}
}
