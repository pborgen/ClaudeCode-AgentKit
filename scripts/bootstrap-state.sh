#!/usr/bin/env bash
# Create an S3 bucket for Terraform remote state (versioned, encrypted, private).
# Run ONCE before switching to the S3 backend.
#
#   scripts/bootstrap-state.sh <globally-unique-bucket-name> [region]
#
# Then copy terraform/ec2-dev/backend.tf.example to backend.tf, fill in the
# bucket name, and run: terraform init -migrate-state
set -euo pipefail

BUCKET="${1:?usage: bootstrap-state.sh <bucket-name> [region]}"
REGION="${2:-us-east-1}"

if [ "$REGION" = "us-east-1" ]; then
  aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
else
  aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
    --create-bucket-configuration "LocationConstraint=$REGION"
fi

aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'

echo "Created state bucket: s3://$BUCKET ($REGION)"
echo "Next: set this bucket in terraform/ec2-dev/backend.tf then 'terraform init -migrate-state'."
