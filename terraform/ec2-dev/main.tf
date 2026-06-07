locals {
  name = var.project_name

  tags = merge({
    Project   = var.project_name
    ManagedBy = "terraform"
  }, var.tags)
}

# --------------------------------------------------------------------------
# Networking: a small dedicated VPC with one public subnet.
# The instance gets a public IP for OUTBOUND only (package + Tailscale setup).
# No NAT gateway, so no hidden hourly cost.
# --------------------------------------------------------------------------
resource "aws_vpc" "this" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, { Name = local.name })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = local.name })
}

# Pick an availability zone that actually offers the requested instance type.
# Not every AZ supports every type (e.g. t3.small is unavailable in us-east-1e),
# so we let AWS tell us which AZs are valid instead of hardcoding one.
data "aws_ec2_instance_type_offerings" "this" {
  filter {
    name   = "instance-type"
    values = [var.instance_type]
  }
  location_type = "availability-zone"
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.20.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = sort(data.aws_ec2_instance_type_offerings.this.locations)[0]

  tags = merge(local.tags, { Name = "${local.name}-public" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(local.tags, { Name = "${local.name}-public" })
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# --------------------------------------------------------------------------
# Security group: NO public SSH. Tailscale establishes connections outbound,
# so the box is unreachable from the open internet. The single inbound rule
# (UDP 41641) only lets Tailscale negotiate a faster *direct* path; it still
# falls back to relays if blocked, so it is optional but harmless.
# --------------------------------------------------------------------------
resource "aws_security_group" "this" {
  name        = "${local.name}-sg"
  description = "Claude Code dev box - Tailscale only, no public SSH"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "Tailscale direct path (WireGuard)"
    from_port   = 41641
    to_port     = 41641
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${local.name}-sg" })
}

# --------------------------------------------------------------------------
# Latest Ubuntu 24.04 LTS (Canonical) AMI for the chosen region.
# --------------------------------------------------------------------------
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd*/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# --------------------------------------------------------------------------
# IAM: lets you connect via AWS SSM Session Manager as a fallback if Tailscale
# ever fails (no SSH keys, no open ports needed).
# --------------------------------------------------------------------------
resource "aws_iam_role" "this" {
  name = "${local.name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Lets the box stop ITSELF for the idle-shutdown timer. Scoped by tag so it can
# only act on instances created by this project, never anything else.
resource "aws_iam_role_policy" "self_stop" {
  count = var.idle_shutdown_minutes > 0 ? 1 : 0

  name = "${local.name}-self-stop"
  role = aws_iam_role.this.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ec2:StopInstances"]
      Resource = "*"
      Condition = {
        StringEquals = { "ec2:ResourceTag/Project" = var.project_name }
      }
    }]
  })
}

resource "aws_iam_instance_profile" "this" {
  name = "${local.name}-profile"
  role = aws_iam_role.this.name
}

# --------------------------------------------------------------------------
# The dev box.
# --------------------------------------------------------------------------
resource "aws_instance" "this" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.this.id]
  iam_instance_profile   = aws_iam_instance_profile.this.name

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    tailscale_auth_key    = var.tailscale_auth_key
    hostname              = var.hostname
    idle_shutdown_minutes = var.idle_shutdown_minutes
    git_user_name         = var.git_user_name
    git_user_email        = var.git_user_email
    dotfiles_repo         = var.dotfiles_repo
  })
  # Re-provision if the bootstrap script changes.
  user_data_replace_on_change = true

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required" # IMDSv2 only
  }

  root_block_device {
    volume_size = var.root_volume_gb
    volume_type = "gp3"
    encrypted   = true
  }

  tags = merge(local.tags, { Name = var.hostname })
}
