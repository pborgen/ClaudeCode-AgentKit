output "instance_id" {
  description = "EC2 instance ID."
  value       = aws_instance.this.id
}

output "public_ip" {
  description = "Public IP (for reference only; you connect over Tailscale, not this)."
  value       = aws_instance.this.public_ip
}

output "tailscale_hostname" {
  description = "Tailscale hostname of the box."
  value       = var.hostname
}

output "connect_command" {
  description = "How to SSH in once both devices are on your tailnet."
  value       = "ssh ubuntu@${var.hostname}"
}

output "ssm_fallback_command" {
  description = "Fallback connection via AWS SSM if Tailscale is unavailable."
  value       = "aws ssm start-session --target ${aws_instance.this.id} --region ${var.region}"
}
