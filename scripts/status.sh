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

export AWS_REGION=$(yq '.aws.region'                "${CONFIG}" | strip_quotes)
export AWS_ACCESS_KEY_ID=$(yq '.aws.access_key_id'  "${CONFIG}" | strip_quotes)
export AWS_SECRET_ACCESS_KEY=$(yq '.aws.secret_access_key' "${CONFIG}" | strip_quotes)
export CDK_STACK_NAME=$(yq '.cdk.cdk_stack_name'    "${CONFIG}" | strip_quotes)
export EBS_STACK_NAME=$(yq '.cdk.ebs_stack_name'    "${CONFIG}" | strip_quotes)
export EB_APP_NAME=$(yq '.elastic_beanstalk.app_name' "${CONFIG}" | strip_quotes)
export EB_ENV_NAME=$(yq '.elastic_beanstalk.env_name' "${CONFIG}" | strip_quotes)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # no colour

section() { echo ""; echo -e "${BOLD}══════════════════════════════════════════════════"; echo -e "  $1"; echo -e "══════════════════════════════════════════════════${NC}"; }

bucket_summary() {
  local bucket="$1"
  if aws s3api head-bucket --bucket "${bucket}" --region "${AWS_REGION}" >/dev/null 2>&1; then
    local count size
    count=$(aws s3 ls "s3://${bucket}" --recursive --region "${AWS_REGION}" 2>/dev/null | wc -l | tr -d ' ')
    size=$(aws s3 ls "s3://${bucket}" --recursive --human-readable --summarize --region "${AWS_REGION}" 2>/dev/null \
           | grep "Total Size" | awk '{print $3, $4}' || echo "0 B")
    echo "  ✅  ${bucket}"
    echo "      objects: ${count}  |  size: ${size}"
  else
    echo "  ❌  ${bucket}  (does not exist)"
  fi
}

# ---------------------------------------------------------------------------
# Credentials
# ---------------------------------------------------------------------------
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "AWS credentials invalid. Check aws-config.yaml." >&2
  exit 1
fi

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

echo ""
echo -e "${BOLD}Bedrock Doc Extract — Environment Status${NC}"
echo "Account : ${ACCOUNT_ID}"
echo "Region  : ${AWS_REGION}"
echo "Time    : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"

# ---------------------------------------------------------------------------
# CloudFormation stacks
# ---------------------------------------------------------------------------
section "CloudFormation Stacks"

echo "  CDK Bootstrap (${CDK_STACK_NAME}):"
if aws cloudformation describe-stacks --stack-name "${CDK_STACK_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1; then
  STATUS=$(aws cloudformation describe-stacks --stack-name "${CDK_STACK_NAME}" --region "${AWS_REGION}" \
    --query 'Stacks[0].StackStatus' --output text)
  echo "    Status: ${STATUS}"
else
  echo "    Not deployed."
fi

echo ""
echo "  App Stack (${EBS_STACK_NAME}):"
if aws cloudformation describe-stacks --stack-name "${EBS_STACK_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1; then
  STATUS=$(aws cloudformation describe-stacks --stack-name "${EBS_STACK_NAME}" --region "${AWS_REGION}" \
    --query 'Stacks[0].StackStatus' --output text)
  echo "    Status: ${STATUS}"
  echo ""
  echo "    Outputs:"
  aws cloudformation describe-stacks --stack-name "${EBS_STACK_NAME}" --region "${AWS_REGION}" \
    --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' --output text \
    | while IFS=$'\t' read -r key value; do
        printf "      %-28s %s\n" "${key}" "${value}"
      done
else
  echo "    Not deployed."
fi

# ---------------------------------------------------------------------------
# S3 Buckets
# ---------------------------------------------------------------------------
section "S3 Buckets"

EB_MANAGED_BUCKET="elasticbeanstalk-${AWS_REGION}-${ACCOUNT_ID}"
CDK_ASSETS_BUCKET="cdk-hnb659fds-assets-${ACCOUNT_ID}-${AWS_REGION}"

# Resolve CDK stack buckets from outputs if the stack exists
TEMP_BUCKET=""
if aws cloudformation describe-stacks --stack-name "${EBS_STACK_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1; then
  TEMP_BUCKET=$(aws cloudformation describe-stacks --stack-name "${EBS_STACK_NAME}" --region "${AWS_REGION}" \
    --query 'Stacks[0].Outputs[?OutputKey==`TempBucketName`].OutputValue | [0]' --output text 2>/dev/null || true)
fi

echo "  EB managed bucket (source bundles):"
bucket_summary "${EB_MANAGED_BUCKET}"

echo ""
echo "  CDK assets bucket (bootstrap):"
bucket_summary "${CDK_ASSETS_BUCKET}"

if [[ -n "${TEMP_BUCKET}" && "${TEMP_BUCKET}" != "None" ]]; then
  echo ""
  echo "  Temp uploads bucket (Textract input):"
  bucket_summary "${TEMP_BUCKET}"
fi

# ---------------------------------------------------------------------------
# Elastic Beanstalk — Application Versions
# ---------------------------------------------------------------------------
section "EB Application Versions  (${EB_APP_NAME})"

VERSIONS=$(aws elasticbeanstalk describe-application-versions \
  --application-name "${EB_APP_NAME}" \
  --region "${AWS_REGION}" \
  --query 'ApplicationVersions[*].[VersionLabel,Status,DateCreated]' \
  --output text 2>/dev/null || true)

if [[ -z "${VERSIONS}" ]]; then
  echo "  No application versions found."
else
  printf "  %-28s %-12s %s\n" "VERSION LABEL" "STATUS" "CREATED"
  printf "  %-28s %-12s %s\n" "─────────────────────────────" "───────────" "───────────────────────"
  echo "${VERSIONS}" | sort -k3 -r | head -5 | \
    while IFS=$'\t' read -r label status created; do
      # Colour-code status
      if [[ "${status}" == "PROCESSED" ]]; then
        colour="${GREEN}"
      elif [[ "${status}" == "FAILED" ]]; then
        colour="${RED}"
      else
        colour="${YELLOW}"
      fi
      printf "  %-28s ${colour}%-12s${NC} %s\n" "${label}" "${status}" "${created}"
    done
fi

# ---------------------------------------------------------------------------
# Elastic Beanstalk — Environment
# ---------------------------------------------------------------------------
section "EB Environment  (${EB_ENV_NAME})"

ENV_JSON=$(aws elasticbeanstalk describe-environments \
  --application-name "${EB_APP_NAME}" \
  --environment-names "${EB_ENV_NAME}" \
  --region "${AWS_REGION}" \
  --output json 2>/dev/null || echo '{"Environments":[]}')

ENV_COUNT=$(echo "${ENV_JSON}" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['Environments']))")

if [[ "${ENV_COUNT}" == "0" ]]; then
  echo "  Environment not found (not yet deployed)."
else
  ENV_STATUS=$(echo "${ENV_JSON}"     | python3 -c "import json,sys; e=json.load(sys.stdin)['Environments'][0]; print(e.get('Status','?'))")
  ENV_HEALTH=$(echo "${ENV_JSON}"     | python3 -c "import json,sys; e=json.load(sys.stdin)['Environments'][0]; print(e.get('Health','?'))")
  ENV_HEALTHST=$(echo "${ENV_JSON}"   | python3 -c "import json,sys; e=json.load(sys.stdin)['Environments'][0]; print(e.get('HealthStatus','?'))")
  ENV_VERSION=$(echo "${ENV_JSON}"    | python3 -c "import json,sys; e=json.load(sys.stdin)['Environments'][0]; print(e.get('VersionLabel','?'))")
  CNAME=$(echo "${ENV_JSON}"          | python3 -c "import json,sys; e=json.load(sys.stdin)['Environments'][0]; print(e.get('CNAME',''))")

  printf "  %-20s %s\n" "Status:"        "${ENV_STATUS}"
  printf "  %-20s %s\n" "Health:"        "${ENV_HEALTH}"
  printf "  %-20s %s\n" "Health status:" "${ENV_HEALTHST}"
  printf "  %-20s %s\n" "Active version:" "${ENV_VERSION}"

  # EC2 instances in this environment
  echo ""
  echo "  EC2 Instances:"
  INSTANCES=$(aws elasticbeanstalk describe-environment-resources \
    --environment-name "${EB_ENV_NAME}" \
    --region "${AWS_REGION}" \
    --query 'EnvironmentResources.Instances[*].Id' \
    --output text 2>/dev/null || true)

  if [[ -z "${INSTANCES}" ]]; then
    echo "    None found."
  else
    for instance_id in ${INSTANCES}; do
      INST_STATE=$(aws ec2 describe-instances \
        --instance-ids "${instance_id}" \
        --region "${AWS_REGION}" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text 2>/dev/null || echo "unknown")
      INST_TYPE=$(aws ec2 describe-instances \
        --instance-ids "${instance_id}" \
        --region "${AWS_REGION}" \
        --query 'Reservations[0].Instances[0].InstanceType' \
        --output text 2>/dev/null || echo "unknown")
      printf "    %-20s type: %-12s state: %s\n" "${instance_id}" "${INST_TYPE}" "${INST_STATE}"
    done
  fi

  # HTTP probe
  if [[ -n "${CNAME}" && "${CNAME}" != "None" ]]; then
    echo ""
    echo "  HTTP probe: http://${CNAME}"
    HTTP_CODE=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 10 "http://${CNAME}/" 2>/dev/null || echo "000")
    RESPONSE_TIME=$(curl -sS -o /dev/null -w "%{time_total}s" --max-time 10 "http://${CNAME}/" 2>/dev/null || echo "timeout")
    if [[ "${HTTP_CODE}" =~ ^2 ]]; then colour="${GREEN}"; elif [[ "${HTTP_CODE}" =~ ^[45] ]]; then colour="${RED}"; else colour="${YELLOW}"; fi
    echo -e "    HTTP status   : ${colour}${HTTP_CODE}${NC}"
    echo    "    Response time : ${RESPONSE_TIME}"
  fi
fi

# ---------------------------------------------------------------------------
# IAM Roles
# ---------------------------------------------------------------------------
section "IAM Roles"

# Resolve role names from the live environment if it exists
EB_INSTANCE_ROLE=""
EB_SERVICE_ROLE=""

if [[ "${ENV_COUNT}" != "0" ]] 2>/dev/null; then
  # Get instance profile name from EB option settings
  EB_INSTANCE_PROFILE=$(aws elasticbeanstalk describe-configuration-settings     --application-name "${EB_APP_NAME}"     --environment-name "${EB_ENV_NAME}"     --region "${AWS_REGION}"     --query "ConfigurationSettings[0].OptionSettings[?Namespace=='aws:autoscaling:launchconfiguration'&&OptionName=='IamInstanceProfile'].Value | [0]"     --output text 2>/dev/null || echo "")

  EB_SERVICE_ROLE_NAME=$(aws elasticbeanstalk describe-configuration-settings     --application-name "${EB_APP_NAME}"     --environment-name "${EB_ENV_NAME}"     --region "${AWS_REGION}"     --query "ConfigurationSettings[0].OptionSettings[?Namespace=='aws:elasticbeanstalk:environment'&&OptionName=='ServiceRole'].Value | [0]"     --output text 2>/dev/null || echo "")

  if [[ -n "${EB_INSTANCE_PROFILE}" && "${EB_INSTANCE_PROFILE}" != "None" ]]; then
    EB_INSTANCE_ROLE=$(aws iam get-instance-profile       --instance-profile-name "${EB_INSTANCE_PROFILE}"       --query 'InstanceProfile.Roles[0].RoleName'       --output text 2>/dev/null || echo "")
  fi

  if [[ -n "${EB_SERVICE_ROLE_NAME}" && "${EB_SERVICE_ROLE_NAME}" != "None" ]]; then
    # ServiceRole may be stored as ARN or name — extract just the name
    EB_SERVICE_ROLE="${EB_SERVICE_ROLE_NAME##*/}"
  fi
fi

print_role_policies() {
  local role="$1"
  local label="$2"

  if [[ -z "${role}" || "${role}" == "None" ]]; then
    echo "  ${label}: (not found)"
    return
  fi

  echo "  ${label}: ${role}"

  # Managed policies
  MANAGED=$(aws iam list-attached-role-policies     --role-name "${role}"     --query 'AttachedPolicies[*].PolicyName'     --output text 2>/dev/null || echo "")
  if [[ -n "${MANAGED}" ]]; then
    for p in ${MANAGED}; do
      echo "    [managed] ${p}"
    done
  fi

  # Inline policies — expand Bedrock/Textract statements fully
  INLINE_NAMES=$(aws iam list-role-policies     --role-name "${role}"     --query 'PolicyNames'     --output text 2>/dev/null || echo "")
  if [[ -n "${INLINE_NAMES}" ]]; then
    for pname in ${INLINE_NAMES}; do
      echo "    [inline]  ${pname}"
      aws iam get-role-policy         --role-name "${role}"         --policy-name "${pname}"         --query 'PolicyDocument.Statement[*].[Effect,join(`,`,Actions||[Action]),join(`,`,Resources||[Resource])]'         --output text 2>/dev/null         | while IFS=$'	' read -r effect actions resources; do
            printf "              Effect:    %s
" "${effect}"
            printf "              Actions:   %s
" "${actions}"
            printf "              Resources: %s
" "${resources}"
            echo ""
          done
    done
  fi
}

print_role_policies "${EB_INSTANCE_ROLE}" "EC2 Instance Role"
echo ""
print_role_policies "${EB_SERVICE_ROLE}"  "EB Service Role"

# ---------------------------------------------------------------------------
# EB Recent Events
# ---------------------------------------------------------------------------
section "EB Recent Events  (last 8)"

aws elasticbeanstalk describe-events \
  --application-name "${EB_APP_NAME}" \
  --region "${AWS_REGION}" \
  --max-records 8 \
  --output text \
  --query 'Events[*].[EventDate,Severity,Message]' 2>/dev/null \
  | while IFS=$'\t' read -r date severity message; do
      case "${severity}" in
        ERROR|WARN)  colour="${RED}"    ;;
        INFO)        colour="${GREEN}"  ;;
        *)           colour="${NC}"     ;;
      esac
      printf "  %s ${colour}%-6s${NC} %s\n" "${date:0:19}" "${severity}" "${message}"
    done || echo "  No events found."

echo ""