#!/usr/bin/env bash
# SnowPro Advanced: Architect — AWS CloudShell setup for Hands-on #06b and #06d
# Copyright © 2026 Innovation In Software Corporation. All rights reserved.
# Run in AWS CloudShell from the root of the unzipped lab folder:
#     export BUCKET=smith-ins-landing-<your-initials>-<4 digits>
#     bash data/aws/cloudshell-setup.sh
set -euo pipefail
: "${BUCKET:?Set BUCKET first, e.g. export BUCKET=smith-ins-landing-ke-4821}"
REGION="${AWS_REGION:-$(aws configure get region || echo us-east-1)}"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

echo "== S3 bucket $BUCKET in $REGION (use the same region as your Snowflake account)"
if ! aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  if [ "$REGION" = "us-east-1" ]; then aws s3api create-bucket --bucket "$BUCKET" >/dev/null
  else aws s3api create-bucket --bucket "$BUCKET" --create-bucket-configuration LocationConstraint="$REGION" >/dev/null; fi
fi
aws s3 cp data/s3_agency_claims/ "s3://$BUCKET/agency_claims/" --recursive --only-show-errors
echo "   agency_claims/: $(aws s3 ls "s3://$BUCKET/agency_claims/" | wc -l) files (60 JSON + 2 CSV)"

echo "== Policy files with your bucket name (paste them in IAM)"
mkdir -p ~/smith-aws
for f in s3-read-policy iceberg-rw-policy; do
  sed "s/<YOUR_BUCKET>/$BUCKET/g" "data/aws/$f.json" > ~/smith-aws/$f.json
done
echo "   ~/smith-aws/s3-read-policy.json     → role smith-snowflake-s3-role      (Hands-on #06b)"
echo "   ~/smith-aws/iceberg-rw-policy.json  → role smith-snowflake-iceberg-role (Hands-on #06d)"
echo "   AWS account ID: $ACCOUNT"
echo "== Done. Keep this tab open; later steps run 'aws s3 ...' commands here."
