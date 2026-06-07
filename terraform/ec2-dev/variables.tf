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
  description = "Tailscale auth key used to join the tailnet on first boot. Use a reusable, NON-ephemeral key from https://login.tailscale.com/admin/settings/keys so the node survives stop/start."
  type        = string
  sensitive   = true
}

variable "idle_shutdown_minutes" {
  description = "Auto-stop the instance after this many minutes with no interactive (pseudo-terminal) session. Set 0 to disable."
  type        = number
  default     = 30
}

variable "git_user_name" {
  description = "Optional: git user.name to configure for the ubuntu user."
  type        = string
  default     = ""
}

variable "git_user_email" {
  description = "Optional: git user.email to configure for the ubuntu user."
  type        = string
  default     = ""
}

variable "dotfiles_repo" {
  description = "Optional: a public git repo to clone to ~/.dotfiles on first boot. If it contains an executable install.sh, it is run."
  type        = string
  default     = ""
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
