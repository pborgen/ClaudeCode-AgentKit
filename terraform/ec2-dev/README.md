# EC2 Claude Code dev box

Terraform that stands up an Ubuntu EC2 instance you can SSH into from your
**iPhone** (or anything) over **Tailscale**, preloaded with **Node.js** and
**Claude Code**. No public SSH port is exposed.

## What it creates

- A dedicated VPC + public subnet + internet gateway (outbound only).
- A `t3.small` Ubuntu 24.04 instance (configurable) with a 30 GB encrypted gp3 root disk.
- A security group with **no public SSH** — only Tailscale's optional direct-path UDP port.
- An IAM role granting **SSM Session Manager** access as a fallback connection method.
- First-boot provisioning: 4 GB swap, AWS CLI, Tailscale (with Tailscale SSH), Node.js 22,
  Claude Code, optional git identity + dotfiles, and an idle auto-shutdown timer.

Rough cost: a `t3.small` left running 24/7 is ~$15/mo plus a few dollars for the
EBS volume. With idle auto-shutdown on (default 30 min) plus the start/stop helper,
you mostly pay only while you're actually using it.

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

## Start / stop to save money

The repo ships a helper that finds the box by name (no Terraform state needed),
so you can run it from anywhere:

```bash
scripts/box.sh start    # power on and wait until running
scripts/box.sh ssh      # start if needed, then SSH in
scripts/box.sh stop     # power off (disk + Tailscale node persist)
scripts/box.sh status
```

On top of that, the box **stops itself** after `idle_shutdown_minutes` (default
30) with no terminal session — a safety net for when you forget. A session in
`tmux` or a running build counts as active, so it won't pull the rug out from
under work. Set `idle_shutdown_minutes = 0` to disable.

## Make it feel like home (optional)

Set these in `terraform.tfvars` and they're applied on first boot:

```hcl
git_user_name  = "Your Name"
git_user_email = "you@example.com"
dotfiles_repo  = "https://github.com/you/dotfiles"   # runs ./install.sh if present
```

## Remote state (optional)

Local state is fine for a single user. To back state up in S3 (e.g. you run
Terraform from more than one machine):

```bash
scripts/bootstrap-state.sh my-unique-bucket us-east-1   # once
cp backend.tf.example backend.tf                        # set the bucket name
terraform init -migrate-state
```

## Common tasks

- **Tear down everything:** `terraform destroy`
- **Re-run provisioning:** edit `user_data.sh.tftpl` and `terraform apply` (the instance is replaced).
- **Check provisioning finished:** `ls /var/log/claude-dev-provision.done` on the box, or `cat /var/log/cloud-init-output.log`.
- **Watch the idle timer:** `journalctl -t claude-dev-idle` on the box.

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
