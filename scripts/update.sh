#!/usr/bin/env bash
# update.sh — rebuild and redeploy the application to the existing EB environment.
# Use this for application code changes that don't require infrastructure updates.
# For infrastructure changes (IAM, buckets, EB config) use deploy.sh instead.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

CONFIG="${ROOT}/scripts/aws-config.yaml"

# --- Tool checks ---
if ! command -v yq >/dev/null 2>&1; then
  echo "yq is required (sudo snap install yq ; or brew install yq)" >&2
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

export AWS_REGION=$(yq '.aws.region'                    "${CONFIG}" | strip_quotes)
export AWS_DEFAULT_REGION=$(yq '.aws.default_region'    "${CONFIG}" | strip_quotes)
export AWS_ACCESS_KEY_ID=$(yq '.aws.access_key_id'      "${CONFIG}" | strip_quotes)
export AWS_SECRET_ACCESS_KEY=$(yq '.aws.secret_access_key' "${CONFIG}" | strip_quotes)
export EBS_STACK_NAME=$(yq '.cdk.ebs_stack_name'        "${CONFIG}" | strip_quotes)
export EB_APP_NAME=$(yq '.elastic_beanstalk.app_name'   "${CONFIG}" | strip_quotes)
export EB_ENV_NAME=$(yq '.elastic_beanstalk.env_name'   "${CONFIG}" | strip_quotes)
CONFIG_MODEL_ID=$(yq '.bedrock.model_id'                "${CONFIG}" | strip_quotes)

# Optional: override the Bedrock model without a CDK redeploy.
# Usage: ./update.sh --model eu.amazon.nova-lite-v1:0
# If omitted, the model ID currently set in aws-config.yaml is used.
OVERRIDE_MODEL_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) OVERRIDE_MODEL_ID="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; echo "Usage: $0 [--model <model-id>]" >&2; exit 1 ;;
  esac
done
BEDROCK_MODEL_ID="${OVERRIDE_MODEL_ID:-${CONFIG_MODEL_ID}}"
echo "Using Bedrock model: ${BEDROCK_MODEL_ID}"

# Validate credentials
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "AWS credentials invalid. Check aws-config.yaml keys." >&2
  exit 1
fi

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

# Verify the EB environment exists and is Ready before attempting an update
echo "Checking EB environment status..."
ENV_STATUS=$(aws elasticbeanstalk describe-environments \
  --application-name "${EB_APP_NAME}" \
  --environment-names "${EB_ENV_NAME}" \
  --region "${AWS_REGION}" \
  --query "Environments[0].Status" \
  --output text 2>/dev/null || echo "None")

if [[ "${ENV_STATUS}" == "None" || "${ENV_STATUS}" == "Terminated" ]]; then
  echo "Environment '${EB_ENV_NAME}' does not exist or is terminated." >&2
  echo "Run deploy.sh to create the full infrastructure first." >&2
  exit 1
fi

if [[ "${ENV_STATUS}" != "Ready" ]]; then
  echo "Environment is currently '${ENV_STATUS}' — wait for it to reach Ready before updating." >&2
  exit 1
fi

echo "Environment is Ready. Proceeding with application update."

# Use the EB-managed S3 bucket (the only bucket EB will process versions from)
EB_BUCKET="elasticbeanstalk-${AWS_REGION}-${ACCOUNT_ID}"

# --- Build ---
echo ""
echo "Building Next.js application..."
cd "${ROOT}/app/web"
npm install --frozen-lockfile || { echo "npm install failed"; exit 1; }
npm run build || { echo "Next.js build failed"; exit 1; }

STANDALONE="${ROOT}/app/web/.next/standalone"
if [[ ! -d "${STANDALONE}" ]]; then
  echo "Standalone build output missing. Ensure next.config.mjs has output: 'standalone'." >&2
  exit 1
fi

# --- Bundle ---
BUNDLE_DIR="$(mktemp -d)"
trap 'rm -rf "${BUNDLE_DIR}"' EXIT

cp -a "${STANDALONE}/." "${BUNDLE_DIR}/"
mkdir -p "${BUNDLE_DIR}/.next"
cp -a "${ROOT}/app/web/.next/static" "${BUNDLE_DIR}/.next/static"
if [[ -d "${ROOT}/app/web/public" ]]; then
  cp -a "${ROOT}/app/web/public/." "${BUNDLE_DIR}/public/"
fi

VERSION_LABEL="v-$(date -u +%Y%m%d%H%M%S)"
ZIP_NAME="${VERSION_LABEL}.zip"
(cd "${BUNDLE_DIR}" && zip -qr "${ROOT}/${ZIP_NAME}" .)

# --- Upload ---
echo "Uploading ${VERSION_LABEL} to s3://${EB_BUCKET}/${EB_APP_NAME}/${ZIP_NAME}"
aws s3 cp "${ROOT}/${ZIP_NAME}" "s3://${EB_BUCKET}/${EB_APP_NAME}/${ZIP_NAME}" \
  --region "${AWS_REGION}" || { echo "Failed to upload to S3"; exit 1; }

aws s3api wait object-exists \
  --bucket "${EB_BUCKET}" \
  --key "${EB_APP_NAME}/${ZIP_NAME}" \
  --region "${AWS_REGION}"

rm -f "${ROOT}/${ZIP_NAME}"

# --- Register version ---
echo "Creating application version ${VERSION_LABEL}..."
aws elasticbeanstalk create-application-version \
  --application-name "${EB_APP_NAME}" \
  --version-label "${VERSION_LABEL}" \
  --source-bundle "S3Bucket=${EB_BUCKET},S3Key=${EB_APP_NAME}/${ZIP_NAME}" \
  --process \
  --region "${AWS_REGION}" >/dev/null || { echo "Failed to create application version"; exit 1; }

echo "Waiting for version to be processed..."
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
    echo "Version processing FAILED. Check the EB console for details." >&2
    exit 1
  fi
  if [[ "${ELAPSED}" -ge "${MAX_WAIT}" ]]; then
    echo "Timed out waiting for version to be processed." >&2
    exit 1
  fi
  sleep 5
  ELAPSED=$((ELAPSED + 5))
done

# --- Deploy ---
echo "Deploying ${VERSION_LABEL} to environment ${EB_ENV_NAME}..."
aws elasticbeanstalk update-environment \
  --application-name "${EB_APP_NAME}" \
  --environment-name "${EB_ENV_NAME}" \
  --version-label "${VERSION_LABEL}" \
  --option-settings "Namespace=aws:elasticbeanstalk:application:environment,OptionName=BEDROCK_MODEL_ID,Value=${BEDROCK_MODEL_ID}" \
  --region "${AWS_REGION}" >/dev/null || { echo "Failed to update environment"; exit 1; }

echo "Waiting for environment to become Ready and Green..."
ENV_MAX_WAIT=600
ENV_ELAPSED=0
while true; do
  ENV_INFO=$(aws elasticbeanstalk describe-environments \
    --application-name "${EB_APP_NAME}" \
    --environment-names "${EB_ENV_NAME}" \
    --region "${AWS_REGION}" \
    --query "Environments[0].[Status,Health]" \
    --output text)
  ENV_STATUS=$(echo "${ENV_INFO}" | awk '{print $1}')
  ENV_HEALTH=$(echo "${ENV_INFO}" | awk '{print $2}')
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

echo ""
echo "✅  Update complete."
echo "Application URL: http://${CNAME}"