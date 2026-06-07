#!/usr/bin/env bash
# Start/stop/connect to the Claude Code dev box from your laptop.
#
#   scripts/box.sh start     # power it on (and wait until running)
#   scripts/box.sh stop      # power it off (disk + Tailscale node persist)
#   scripts/box.sh status    # show current state
#   scripts/box.sh ssh       # start if needed, then SSH in over Tailscale
#
# Finds the instance by its Name tag, so it works from anywhere without
# Terraform state. Override defaults with env vars:
#   BOX_NAME (default: claude-dev)   AWS_REGION (default: us-east-1)
set -euo pipefail

NAME="${BOX_NAME:-claude-dev}"
REGION="${AWS_REGION:-us-east-1}"

iid() {
  aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Name,Values=$NAME" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text
}

state() {
  aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Name,Values=$NAME" \
    --query 'Reservations[].Instances[].State.Name' --output text
}

require_id() {
  local id; id="$(iid)"
  if [ -z "$id" ] || [ "$id" = "None" ]; then
    echo "No instance tagged Name=$NAME in $REGION. Did you 'terraform apply'?" >&2
    exit 1
  fi
  echo "$id"
}

cmd="${1:-}"
case "$cmd" in
  start)
    id="$(require_id)"
    echo "Starting $id ..."
    aws ec2 start-instances --region "$REGION" --instance-ids "$id" >/dev/null
    aws ec2 wait instance-running --region "$REGION" --instance-ids "$id"
    echo "Running. Give it ~30s, then: scripts/box.sh ssh"
    ;;
  stop)
    id="$(require_id)"
    echo "Stopping $id ..."
    aws ec2 stop-instances --region "$REGION" --instance-ids "$id" >/dev/null
    echo "Stop requested."
    ;;
  status)
    echo "$NAME ($REGION): $(state)"
    ;;
  ssh)
    id="$(require_id)"
    if [ "$(state)" != "running" ]; then
      echo "Box is $(state); starting it first ..."
      aws ec2 start-instances --region "$REGION" --instance-ids "$id" >/dev/null
      aws ec2 wait instance-running --region "$REGION" --instance-ids "$id"
      sleep 20
    fi
    exec ssh "ubuntu@$NAME"
    ;;
  *)
    grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'
    exit 1
    ;;
esac
