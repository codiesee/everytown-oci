#!/usr/bin/env bash
# Deploy database, Astro site, Lambda API, DB migrations, and Knowledge Base ingestion.
# Expects AWS credentials in the environment.
# Required env: EXPECTED_ACCOUNT_ID (12 digits), AWS_REGION. Refuses a different AWS identity.
# Optional env: STACK (app stack, default everytown-oci), DB_STACK (default everytown-oci-db),
#   VPC_ID, SUBNET_IDS (comma-separated; otherwise discover default VPC/subnets),
#   DB_MIN_CAPACITY (Aurora ACUs; 0 = auto-pause after an idle hour), EXTRA_DOCS (dir of extra KB docs),
#   RESERVED_CONCURRENCY (Lambda cap, template default 10), MONTHLY_BUDGET_USD (account-wide cost budget;
#   template default 0 skips it in a shared account), BUDGET_ALERT_EMAIL,
#   SEED_SYNTHETIC_DATA=1 (explicitly replace demo organizations), RECORD_GITHUB_DEPLOYMENT=1.
#   Unset values keep the stack's previous setting.
# Shared account/Region observability settings are intentionally left untouched. CloudWatch Transaction Search and
#   Bedrock model invocation logging require a separate impact review and setup.
#   When infra/.phoenix.env exists (from scripts/deploy_observability.sh), its PHOENIX_URL and PHOENIX_API_KEY are
#   passed to the app, which then also sends its traces to Phoenix; otherwise the stack keeps its previous settings.
set -euo pipefail
cd "$(dirname "$0")/.."

STACK=${STACK:-everytown-oci}
DB_STACK=${DB_STACK:-everytown-oci-db}
: "${EXPECTED_ACCOUNT_ID:?Set EXPECTED_ACCOUNT_ID to the intended 12-digit AWS account ID}"
: "${AWS_REGION:?Set AWS_REGION to the intended deployment Region}"
[[ "$EXPECTED_ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || { echo "EXPECTED_ACCOUNT_ID must be 12 digits." >&2; exit 1; }
export AWS_DEFAULT_REGION=$AWS_REGION
REGION=$AWS_DEFAULT_REGION
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
[[ "$ACCOUNT" = "$EXPECTED_ACCOUNT_ID" ]] || { echo "AWS account mismatch: expected $EXPECTED_ACCOUNT_ID, got $ACCOUNT." >&2; exit 1; }
ARTIFACTS=oci-artifacts-$ACCOUNT-$REGION

sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1
}

# Prints a stack output, or nothing when the stack or output does not exist.
out() {
  local value
  value=$(aws cloudformation describe-stacks --stack-name "$1" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text 2>/dev/null) || return 0
  [ "$value" = None ] || printf '%s' "$value"
}

# Refuse a legacy app stack before creating or updating any resources.
OLD_STORE=$(out "$STACK" StoreBucket)
[ -z "$OLD_STORE" ] || { echo "Legacy StoreBucket $OLD_STORE exists; refusing automatic deletion." >&2; exit 1; }

# 1. Database (own stack, data lifecycle independent of the app). Parameters not passed keep their previous value.
VPC=${VPC_ID:-$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)}
[[ -n "$VPC" && "$VPC" != None ]] || { echo "No VPC found; set VPC_ID." >&2; exit 1; }
SUBNETS=${SUBNET_IDS:-$(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC" Name=default-for-az,Values=true \
  --query 'Subnets[].SubnetId' --output text | tr '\t' ',')}
[[ -n "$SUBNETS" && "$SUBNETS" != None ]] || { echo "No subnets found; set SUBNET_IDS." >&2; exit 1; }
DB_PARAMS=(VpcId="$VPC" SubnetIds="$SUBNETS")
[ -n "${DB_MIN_CAPACITY:-}" ] && DB_PARAMS+=(MinCapacity="$DB_MIN_CAPACITY")
aws cloudformation deploy --stack-name "$DB_STACK" --template-file infra/database.yaml \
  --no-fail-on-empty-changeset --parameter-overrides "${DB_PARAMS[@]}"
DB_CLUSTER_ARN=$(out "$DB_STACK" DbClusterArn)
DB_SECRET_ARN=$(out "$DB_STACK" DbSecretArn)
DB_NAME=$(out "$DB_STACK" DbName)

# 2. Static site and Lambda package.
(cd frontend && npm ci && npm run build)
scripts/build.sh

if ! aws s3api head-bucket --bucket "$ARTIFACTS" 2>/dev/null; then
  if [ "$REGION" = us-east-1 ]; then
    aws s3api create-bucket --bucket "$ARTIFACTS" >/dev/null
  else
    aws s3api create-bucket --bucket "$ARTIFACTS" --create-bucket-configuration LocationConstraint="$REGION" >/dev/null
  fi
  aws s3api put-public-access-block --bucket "$ARTIFACTS" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
fi
KEY=oci-$(sha256 build/oci.zip | cut -c1-16).zip
aws s3api head-object --bucket "$ARTIFACTS" --key "$KEY" >/dev/null 2>&1 \
  || aws s3 cp --only-show-errors build/oci.zip "s3://$ARTIFACTS/$KEY"

# Session secret: generated once, kept locally (git-ignored), never printed.
if [ ! -s infra/.secret ]; then
  (umask 077; python3 -c 'import secrets; print(secrets.token_hex(32))' > infra/.secret)
fi

# 3. App stack. A legacy StoreBucket is rejected before provisioning begins.

APP_PARAMS=(CodeBucket="$ARTIFACTS" CodeKey="$KEY" SecretKey="$(cat infra/.secret)"
  DbClusterArn="$DB_CLUSTER_ARN" DbSecretArn="$DB_SECRET_ARN" DbName="$DB_NAME")
[ -n "${RESERVED_CONCURRENCY:-}" ] && APP_PARAMS+=(ReservedConcurrency="$RESERVED_CONCURRENCY")
[ -n "${MONTHLY_BUDGET_USD:-}" ] && APP_PARAMS+=(MonthlyBudgetUsd="$MONTHLY_BUDGET_USD")
[ -n "${BUDGET_ALERT_EMAIL:-}" ] && APP_PARAMS+=(BudgetAlertEmail="$BUDGET_ALERT_EMAIL")
if [ -s infra/.phoenix.env ]; then
  # shellcheck source=/dev/null
  APP_PARAMS+=("PhoenixEndpoint=$(. infra/.phoenix.env; printf %s "${PHOENIX_URL:-}")"
    "PhoenixApiKey=$(. infra/.phoenix.env; printf %s "${PHOENIX_API_KEY:-}")")
fi
aws cloudformation deploy --stack-name "$STACK" --template-file infra/template.yaml \
  --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM --no-fail-on-empty-changeset \
  --parameter-overrides "${APP_PARAMS[@]}"

SITE=$(out "$STACK" SiteBucket)
DIST=$(out "$STACK" DistributionId)
DOCS=$(out "$STACK" DocsBucket)
KB=$(out "$STACK" KnowledgeBaseId)
DS=$(out "$STACK" DataSourceId)

# 4. Site upload: fingerprinted assets cached for a year, HTML always revalidated, the rest for an hour.
aws s3 sync --only-show-errors frontend/dist/_astro "s3://$SITE/_astro" --cache-control 'public,max-age=31536000,immutable'
aws s3 sync --only-show-errors frontend/dist "s3://$SITE" --exclude '_astro/*' --exclude '*.html' --cache-control 'public,max-age=3600'
aws s3 sync --only-show-errors frontend/dist "s3://$SITE" --exclude '*' --include '*.html' --cache-control 'no-cache'
aws s3 sync --only-show-errors --delete frontend/dist "s3://$SITE"
# The 404 page carries its status as metadata; the template's NotFoundStatusFunction turns it into HTTP 404.
aws s3 cp --only-show-errors frontend/dist/404.html "s3://$SITE/404.html" --cache-control 'no-cache' --metadata oci-status=404
aws cloudfront create-invalidation --distribution-id "$DIST" --paths '/*' --query Invalidation.Id --output text

# 5. Database schema. Seeding replaces demo organizations, so it must be explicitly requested.
export OCI_DB_CLUSTER_ARN=$DB_CLUSTER_ARN OCI_DB_SECRET_ARN=$DB_SECRET_ARN OCI_DB_NAME=$DB_NAME
python3 -m db migrate
if [ "${SEED_SYNTHETIC_DATA:-0}" = 1 ]; then
  python3 -m db seed
fi

# 6. Knowledge Base: sync the resource library and ingest.
if [ -d resources/library ]; then
  aws s3 sync --only-show-errors --delete resources/library "s3://$DOCS/library/" --exclude '*' --include '*.md'
fi
if [ -n "${EXTRA_DOCS:-}" ]; then
  aws s3 sync --only-show-errors --delete "$EXTRA_DOCS" "s3://$DOCS/extra/"
fi

JOB=$(aws bedrock-agent start-ingestion-job --knowledge-base-id "$KB" --data-source-id "$DS" --query ingestionJob.ingestionJobId --output text)
while :; do
  STATUS=$(aws bedrock-agent get-ingestion-job --knowledge-base-id "$KB" --data-source-id "$DS" --ingestion-job-id "$JOB" --query ingestionJob.status --output text)
  case $STATUS in COMPLETE|FAILED|STOPPED) break ;; esac
  sleep 10
done
aws bedrock-agent get-ingestion-job --knowledge-base-id "$KB" --data-source-id "$DS" --ingestion-job-id "$JOB" \
  --query 'ingestionJob.[status,statistics,failureReasons]' --output json
[ "$STATUS" = COMPLETE ]

APP_URL=$(out "$STACK" AppUrl)
echo "AppUrl: $APP_URL"

# 7. GitHub Deployments: record this deploy (commit, environment = stack name, live URL) when gh is signed in.
#   Needs HEAD pushed to GitHub; a failure here only warns, because the deploy itself already succeeded.
if [ "${RECORD_GITHUB_DEPLOYMENT:-0}" = 1 ] && command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  GH_DEP=$(gh api repos/{owner}/{repo}/deployments -f ref="$(git rev-parse HEAD)" -f environment="$STACK" \
    -f description="$(git describe --tags --always --dirty)" -F auto_merge=false -f 'required_contexts[]' --jq .id) &&
  gh api "repos/{owner}/{repo}/deployments/$GH_DEP/statuses" -f state=success -f environment_url="$APP_URL" >/dev/null &&
  echo "GitHub deployment: $GH_DEP" || echo "GitHub deployment not recorded (is HEAD pushed?)" >&2
fi
