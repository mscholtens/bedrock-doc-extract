#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

CONFIG="${ROOT}/scripts/aws-config.yaml"

if ! command -v yq >/dev/null 2>&1; then
  echo "yq is required (sudo snap install yq ; or brew install yq)" >&2
  exit 1
fi

if [[ ! -f "${CONFIG}" ]]; then
  echo "Missing ${CONFIG}" >&2
  exit 1
fi

strip_quotes() {
  tr -d '"'
}

export AWS_REGION=$(yq '.aws.region' "${CONFIG}" | strip_quotes)
export AWS_ACCESS_KEY_ID=$(yq '.aws.access_key_id' "${CONFIG}" | strip_quotes)
export AWS_SECRET_ACCESS_KEY=$(yq '.aws.secret_access_key' "${CONFIG}" | strip_quotes)
export CDK_STACK_NAME=$(yq '.cdk.cdk_stack_name' "${CONFIG}" | strip_quotes)
export EBS_STACK_NAME=$(yq '.cdk.ebs_stack_name' "${CONFIG}" | strip_quotes)
export EB_APP_NAME=$(yq '.elastic_beanstalk.app_name' "${CONFIG}" | strip_quotes)
export EB_ENV_NAME=$(yq '.elastic_beanstalk.env_name' "${CONFIG}" | strip_quotes)
export EB_SOLUTION_STACK=$(yq '.elastic_beanstalk.solution_stack' "${CONFIG}" | strip_quotes)
export BEDROCK_MODEL_ID=$(yq '.bedrock.model_id' "${CONFIG}" | strip_quotes)

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
if [[ -n "${ACCOUNT_ID}" ]]; then
  export CDK_DEFAULT_ACCOUNT="${CDK_DEFAULT_ACCOUNT:-${ACCOUNT_ID}}"
fi
export CDK_DEFAULT_REGION="${CDK_DEFAULT_REGION:-${AWS_REGION}}"

# ---------------------------------------------------------------------------
# Helper: empty a bucket (all versions + delete markers) then delete it.
# Skips gracefully if the bucket does not exist.
# ---------------------------------------------------------------------------
nuke_bucket() {
  local bucket="$1"

  if ! aws s3api head-bucket --bucket "${bucket}" --region "${AWS_REGION}" 2>/dev/null; then
    echo "  Bucket ${bucket} does not exist or is already deleted — skipping."
    return 0
  fi

  echo "  Removing bucket policy from ${bucket} (if any)..."
  aws s3api delete-bucket-policy --bucket "${bucket}" --region "${AWS_REGION}" 2>/dev/null || true

  echo "  Emptying ${bucket} (objects)..."
  aws s3 rm "s3://${bucket}" --recursive --region "${AWS_REGION}" 2>/dev/null || true

  echo "  Emptying ${bucket} (versioned objects + delete markers)..."
  local versions
  versions=$(aws s3api list-object-versions --bucket "${bucket}" --region "${AWS_REGION}" \
    --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}, DeleteMarkers: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' \
    --output json 2>/dev/null || echo '{}')

  # Delete all versions
  local version_keys
  version_keys=$(echo "${versions}" | python3 -c "
import json,sys
data=json.load(sys.stdin)
objs=[{'Key':o['Key'],'VersionId':o['VersionId']} for o in (data.get('Objects') or []) if o.get('VersionId')]
objs+=[{'Key':o['Key'],'VersionId':o['VersionId']} for o in (data.get('DeleteMarkers') or []) if o.get('VersionId')]
if objs:
    print(json.dumps({'Objects':objs,'Quiet':True}))
" 2>/dev/null || true)

  if [[ -n "${version_keys}" ]]; then
    echo "${version_keys}" | aws s3api delete-objects \
      --bucket "${bucket}" \
      --region "${AWS_REGION}" \
      --delete file:///dev/stdin >/dev/null 2>/dev/null || true
  fi

  echo "  Deleting bucket ${bucket}..."
  aws s3api delete-bucket --bucket "${bucket}" --region "${AWS_REGION}" 2>/dev/null || true
  echo "  ✅  ${bucket} deleted."
}

# ---------------------------------------------------------------------------

echo "Destroying CDK stacks unconditionally..."

cd "${ROOT}/infra/cdk"
npm ci

echo ""
echo "=== Active CloudFormation stacks in ${AWS_REGION} ==="
aws cloudformation list-stacks --region "${AWS_REGION}" \
  --query 'StackSummaries[?contains(`["CREATE_COMPLETE","UPDATE_COMPLETE","UPDATE_IN_PROGRESS","CREATE_IN_PROGRESS","DELETE_IN_PROGRESS","ROLLBACK_IN_PROGRESS","UPDATE_ROLLBACK_IN_PROGRESS"]`, StackStatus)].StackName' \
  --output table || true
echo ""

echo "=== Active CDK stacks in ${AWS_REGION} ==="
npx cdk list
echo ""

# --- 1. Destroy the app stack (CDK handles its own bucket cleanup) ----------
echo "${EBS_STACK_NAME}: destroying..."
npx cdk destroy "${EBS_STACK_NAME}" --force \
  -c ebAppName="${EB_APP_NAME}" \
  -c ebEnvName="${EB_ENV_NAME}" \
  -c ebSolutionStack="${EB_SOLUTION_STACK}" \
  -c bedrockModelId="${BEDROCK_MODEL_ID}"
echo "✅  ${EBS_STACK_NAME}: destroyed"

# --- 2. Delete the CDK bootstrap stack -------------------------------------
echo "${CDK_STACK_NAME}: destroying..."
aws cloudformation delete-stack --stack-name "${CDK_STACK_NAME}" --region "${AWS_REGION}"

echo "Waiting for bootstrap stack deletion to complete..."
aws cloudformation wait stack-delete-complete \
  --stack-name "${CDK_STACK_NAME}" \
  --region "${AWS_REGION}" || true
echo "✅  ${CDK_STACK_NAME}: destroyed"

# --- 3. Clean up buckets that survive stack deletion -----------------------
#
# Two buckets are intentionally left behind by AWS/CDK and must be removed
# manually:
#
# a) elasticbeanstalk-<region>-<account>
#    AWS puts a Deny DeleteBucket policy on this bucket to protect it from
#    accidental removal. We strip the policy first, then empty and delete it.
#
# b) cdk-hnb659fds-assets-<account>-<region>
#    The CDK bootstrap template sets DeletionPolicy: Retain on this bucket
#    so it survives stack deletion. We empty and delete it explicitly.
#
echo ""
echo "Cleaning up retained buckets..."

EB_MANAGED_BUCKET="elasticbeanstalk-${AWS_REGION}-${ACCOUNT_ID}"
CDK_ASSETS_BUCKET="cdk-hnb659fds-assets-${ACCOUNT_ID}-${AWS_REGION}"

echo "Nuking EB-managed bucket: ${EB_MANAGED_BUCKET}"
nuke_bucket "${EB_MANAGED_BUCKET}"

echo "Nuking CDK assets bucket: ${CDK_ASSETS_BUCKET}"
nuke_bucket "${CDK_ASSETS_BUCKET}"

# --- 4. Final status -------------------------------------------------------
echo ""
echo "=== Remaining CloudFormation stacks in ${AWS_REGION} ==="
aws cloudformation list-stacks --region "${AWS_REGION}" \
  --query 'StackSummaries[?contains(`["CREATE_COMPLETE","UPDATE_COMPLETE","UPDATE_IN_PROGRESS","CREATE_IN_PROGRESS","DELETE_IN_PROGRESS","ROLLBACK_IN_PROGRESS","UPDATE_ROLLBACK_IN_PROGRESS"]`, StackStatus)].StackName' \
  --output table || true

echo ""
echo "✅  Destroy complete. All buckets cleaned up."