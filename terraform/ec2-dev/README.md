# EC2 Claude Code dev box

Terraform that stands up an Ubuntu EC2 instance you can SSH into from your
**iPhone** (or anything) over **Tailscale**, preloaded with **Node.js** and
**Claude Code**. No public SSH port is exposed.

## What it creates

- A dedicated VPC + public subnet + internet gateway (outbound only).
- A `t3.small` Ubuntu 24.04 instance (configurable) with a 30 GB encrypted gp3 root disk.
- A security group with **no public SSH** — only Tailscale's optional direct-path UDP port.
- An IAM role granting **SSM Session Manager** access as a fallback connection method.
- First-boot provisioning: 4 GB swap, Tailscale (with Tailscale SSH), Node.js 22, Claude Code.

Rough cost: a `t3.small` left running 24/7 is ~$15/mo plus a few dollars for the
EBS volume. `terraform destroy` (or stopping the instance) when you're done keeps it cheap.

## Prerequisites (on your Mac)

1. **AWS CLI** configured with credentials: `aws configure` (and `aws sts get-caller-identity` to confirm).
2. **Terraform** ≥ 1.5: `brew install terraform`.
3. A **Tailscale account** (free): https://tailscale.com — then create an auth key at
   https://login.tailscale.com/admin/settings/keys. Enable *Reusable*; leave
   *Ephemeral* **off** so the box survives stop/start (see [Notes](#notes--security)).

## Deploy

```bash
cd terraform/ec2-dev
cp terraform.tfvars.example terraform.tfvars   # then edit, paste your tailscale_auth_key
terraform init
terraform apply
```

First boot provisioning takes ~3–5 minutes after `apply` finishes. Watch for the
box to appear in your Tailscale admin console as `claude-dev`.

## Connect from your iPhone

1. Install **Tailscale** from the App Store and sign in to the same account.
2. Install an SSH client — **Blink Shell** or **Termius**.
3. SSH in (Tailscale handles auth — no key needed):
   ```
   ssh ubuntu@claude-dev
   ```
4. Start Claude Code:
   ```
   claude
   ```
   On first run it'll walk you through signing in to your Anthropic account.

### Fallback: connect without Tailscale

If Tailscale is ever down, use SSM from your Mac:
```bash
aws ssm start-session --target $(terraform output -raw instance_id) --region us-east-1
```

## Common tasks

- **Tear down everything:** `terraform destroy`
- **Stop the box to save money (keeps the disk):** `aws ec2 stop-instances --instance-ids $(terraform output -raw instance_id)` — start again with `start-instances`.
- **Re-run provisioning:** edit `user_data.sh.tftpl` and `terraform apply` (the instance is replaced).
- **Check provisioning finished:** `ls /var/log/claude-dev-provision.done` on the box, or `cat /var/log/cloud-init-output.log`.

## Notes & security

- **Stop/start survives, but only with a non-ephemeral node.** The bootstrap
  script runs once at first boot; Tailscale state persists on the EBS volume, so a
  stopped-then-started box reconnects automatically — *unless* the node is
  ephemeral, in which case it's removed from the tailnet while offline and can't
  rejoin. So use a **reusable, non-ephemeral** key and **disable key expiry** on
  the node (admin console → the machine → *Disable key expiry*).
- The Tailscale auth key is passed via EC2 user-data, which is readable from the
  instance's metadata service. Keep the key scoped to this use and rotate it if leaked.
- State (`terraform.tfstate`) and `terraform.tfvars` contain secrets and are gitignored.
  For team use, move state to an [S3 backend](https://developer.hashicorp.com/terraform/language/settings/backends/s3).
- Set up [Tailscale ACLs](https://tailscale.com/kb/1018/acls) if your tailnet has
  other users/devices you don't want reaching this box.
