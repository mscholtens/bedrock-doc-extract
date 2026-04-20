#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

CONFIG="${ROOT}/scripts/aws-config.yaml"

# --- Tool checks ---
if ! command -v yq >/dev/null 2>&1; then
  echo "yq is required. Go-yq: sudo snap install yq" >&2
  exit 1
fi
if ! command -v aws >/dev/null 2>&1; then
  echo "aws CLI is required." >&2
  exit 1
fi
if ! command -v npm >/dev/null 2>&1; then
  echo "npm is required." >&2
  exit 1
fi
if ! command -v zip >/dev/null 2>&1; then
  echo "zip is required." >&2
  exit 1
fi

if [[ ! -f "${CONFIG}" ]]; then
  echo "Missing ${CONFIG}." >&2
  exit 1
fi

strip_quotes() {
  tr -d '"'
}

export AWS_REGION=$(yq '.aws.region' "${CONFIG}" | strip_quotes)
export AWS_DEFAULT_REGION=$(yq '.aws.default_region' "${CONFIG}" | strip_quotes)
export AWS_ACCESS_KEY_ID=$(yq '.aws.access_key_id' "${CONFIG}" | strip_quotes)
export AWS_SECRET_ACCESS_KEY=$(yq '.aws.secret_access_key' "${CONFIG}" | strip_quotes)
export CDK_STACK_NAME=$(yq '.cdk.cdk_stack_name' "${CONFIG}" | strip_quotes)
export EBS_STACK_NAME=$(yq '.cdk.ebs_stack_name' "${CONFIG}" | strip_quotes)
export EB_APP_NAME=$(yq '.elastic_beanstalk.app_name' "${CONFIG}" | strip_quotes)
export EB_ENV_NAME=$(yq '.elastic_beanstalk.env_name' "${CONFIG}" | strip_quotes)
export EB_SOLUTION_STACK=$(yq '.elastic_beanstalk.solution_stack' "${CONFIG}" | strip_quotes)
export BEDROCK_MODEL_ID=$(yq '.bedrock.model_id' "${CONFIG}" | strip_quotes)

# Validate credentials
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "AWS credentials invalid. Check aws-config.yaml keys." >&2
  exit 1
fi

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export CDK_DEFAULT_ACCOUNT="${CDK_DEFAULT_ACCOUNT:-${ACCOUNT_ID}}"
export CDK_DEFAULT_REGION="${CDK_DEFAULT_REGION:-${AWS_REGION}}"

BOOTSTRAP_STACK="${CDK_STACK_NAME}"

if ! aws cloudformation describe-stacks --stack-name "${BOOTSTRAP_STACK}" --region "${AWS_REGION}" >/dev/null 2>&1; then
  echo "CDK bootstrap stack not found; bootstrapping ${AWS_REGION} for account ${ACCOUNT_ID}..."
  npx --yes aws-cdk@2 bootstrap "aws://${ACCOUNT_ID}/${AWS_REGION}"
else
  echo "CDK already bootstrapped in ${AWS_REGION}."
fi

echo "Deploying CDK stack ${EBS_STACK_NAME}..."
cd "${ROOT}/infra/cdk"
npm ci
npx cdk deploy "${EBS_STACK_NAME}" --require-approval never \
  -c ebAppName="${EB_APP_NAME}" \
  -c ebEnvName="${EB_ENV_NAME}" \
  -c ebSolutionStack="${EB_SOLUTION_STACK}" \
  -c bedrockModelId="${BEDROCK_MODEL_ID}"

# FIX: Use the EB-managed S3 bucket for the source bundle.
# EB processes application versions from its own regional bucket
# (elasticbeanstalk-<region>-<account>), NOT a custom bucket.
# The event log confirmed EB is using this bucket for environment data.
# Uploading to any other bucket causes versions to remain UNPROCESSED forever.
EB_BUCKET="elasticbeanstalk-${AWS_REGION}-${ACCOUNT_ID}"

# Ensure the EB-managed bucket exists (created automatically on first EB use,
# but calling create-storage-location is the safe way to guarantee it).
echo "Ensuring EB storage bucket exists: ${EB_BUCKET}"
aws elasticbeanstalk create-storage-location --region "${AWS_REGION}" >/dev/null 2>&1 || true

echo "Building Next.js application bundle..."
cd "${ROOT}/app/web"
echo "Installing dependencies..."
npm install --frozen-lockfile || { echo "npm install failed"; exit 1; }

echo "Running Next.js build..."
npm run build || { echo "Next.js build failed"; exit 1; }

STANDALONE="${ROOT}/app/web/.next/standalone"
if [[ ! -d "${STANDALONE}" ]]; then
  echo "Standalone build output missing. Ensure next.config.mjs has output: 'standalone'." >&2
  exit 1
fi

BUNDLE_DIR="$(mktemp -d)"
if [[ ! -d "${BUNDLE_DIR}" ]]; then
  echo "Failed to create temporary directory for the bundle." >&2
  exit 1
fi
trap 'rm -rf "${BUNDLE_DIR}"' EXIT

cp -a "${STANDALONE}/." "${BUNDLE_DIR}/"
mkdir -p "${BUNDLE_DIR}/.next"
cp -a "${ROOT}/app/web/.next/static" "${BUNDLE_DIR}/.next/static"
if [[ -d "${ROOT}/app/web/public" ]]; then
  cp -a "${ROOT}/app/web/public/." "${BUNDLE_DIR}/public/"
fi

# FIX: Write a Procfile so EB knows how to start the Next.js standalone server.
# Without it, EB has no entry point and the app will not start even if the
# version processes successfully. The standalone build emits server.js at the
# root of the standalone directory.
cat > "${BUNDLE_DIR}/Procfile" <<'EOF'
web: node server.js
EOF

VERSION_LABEL="v-$(date -u +%Y%m%d%H%M%S)"
ZIP_NAME="${VERSION_LABEL}.zip"
(cd "${BUNDLE_DIR}" && zip -qr "${ROOT}/${ZIP_NAME}" .)

echo "Uploading application version ${VERSION_LABEL} to s3://${EB_BUCKET}/${EB_APP_NAME}/${ZIP_NAME}"
aws s3 cp "${ROOT}/${ZIP_NAME}" "s3://${EB_BUCKET}/${EB_APP_NAME}/${ZIP_NAME}" \
  --region "${AWS_REGION}" || { echo "Failed to upload to S3"; exit 1; }

# Confirm the object is visible in S3 before registering the version
aws s3api wait object-exists \
  --bucket "${EB_BUCKET}" \
  --key "${EB_APP_NAME}/${ZIP_NAME}" \
  --region "${AWS_REGION}"

rm -f "${ROOT}/${ZIP_NAME}"

echo "Creating Elastic Beanstalk application version..."
aws elasticbeanstalk create-application-version \
  --application-name "${EB_APP_NAME}" \
  --version-label "${VERSION_LABEL}" \
  --source-bundle "S3Bucket=${EB_BUCKET},S3Key=${EB_APP_NAME}/${ZIP_NAME}" \
  --process \
  --region "${AWS_REGION}" || { echo "Failed to create application version"; exit 1; }

# Wait for EB to finish processing the version before deploying it.
echo "Waiting for application version to be processed..."
MAX_WAIT=120
ELAPSED=0
while true; do
  STATUS=$(aws elasticbeanstalk describe-application-versions \
    --application-name "${EB_APP_NAME}" \
    --version-labels "${VERSION_LABEL}" \
    --region "${AWS_REGION}" \
    --query 'ApplicationVersions[0].Status' \
    --output text)
  echo "  Version status: ${STATUS}"
  if [[ "${STATUS}" == "PROCESSED" ]]; then
    echo "Version processed successfully."
    break
  fi
  if [[ "${STATUS}" == "FAILED" ]]; then
    echo "Application version processing FAILED. Check the EB console for details." >&2
    exit 1
  fi
  if [[ "${ELAPSED}" -ge "${MAX_WAIT}" ]]; then
    echo "Timed out waiting for version to be processed." >&2
    exit 1
  fi
  sleep 5
  ELAPSED=$((ELAPSED + 5))
done

echo "Updating Elastic Beanstalk environment..."
aws elasticbeanstalk update-environment \
  --application-name "${EB_APP_NAME}" \
  --environment-name "${EB_ENV_NAME}" \
  --version-label "${VERSION_LABEL}" \
  --region "${AWS_REGION}" >/dev/null || { echo "Failed to update environment"; exit 1; }

# Replace the built-in waiter (which times out after ~20 attempts) with a
# custom polling loop. EB environment updates can take 3-5 minutes; we wait
# up to 10 minutes and check both Status=Ready and Health=Green.
echo "Waiting for environment to become Ready and Green (this may take several minutes)..."
ENV_MAX_WAIT=600
ENV_ELAPSED=0
while true; do
  ENV_INFO=$(aws elasticbeanstalk describe-environments \
    --application-name "${EB_APP_NAME}" \
    --environment-names "${EB_ENV_NAME}" \
    --region "${AWS_REGION}" \
    --query "Environments[0].[Status,Health]" \
    --output text)
  ENV_STATUS=$(echo "${ENV_INFO}" | awk "{print \$1}")
  ENV_HEALTH=$(echo "${ENV_INFO}" | awk "{print \$2}")
  echo "  Environment status: ${ENV_STATUS}  health: ${ENV_HEALTH}"
  if [[ "${ENV_STATUS}" == "Ready" && "${ENV_HEALTH}" == "Green" ]]; then
    echo "Environment is Ready and Green."
    break
  fi
  if [[ "${ENV_STATUS}" == "Terminated" ]]; then
    echo "Environment was terminated unexpectedly." >&2
    exit 1
  fi
  if [[ "${ENV_ELAPSED}" -ge "${ENV_MAX_WAIT}" ]]; then
    echo "Timed out waiting for environment to become Ready. Check the EB console." >&2
    exit 1
  fi
  sleep 10
  ENV_ELAPSED=$((ENV_ELAPSED + 10))
done

CNAME="$(aws elasticbeanstalk describe-environments \
  --application-name "${EB_APP_NAME}" \
  --environment-names "${EB_ENV_NAME}" \
  --region "${AWS_REGION}" \
  --query 'Environments[0].CNAME' \
  --output text)"

if [[ -z "${CNAME}" || "${CNAME}" == "None" ]]; then
  echo "Could not resolve environment CNAME." >&2
  exit 1
fi

echo ""
echo "=== Active CloudFormation stacks in ${AWS_REGION} ==="
aws cloudformation list-stacks \
  --region "${AWS_REGION}" \
  --query 'StackSummaries[?contains(`["CREATE_COMPLETE","UPDATE_COMPLETE","UPDATE_IN_PROGRESS","CREATE_IN_PROGRESS","DELETE_IN_PROGRESS","ROLLBACK_IN_PROGRESS","UPDATE_ROLLBACK_IN_PROGRESS"]`, StackStatus)].StackName' \
  --output table || true
echo ""
echo "Application URL: http://${CNAME}"
echo "(Open this URL in your browser after the environment finishes updating.)"