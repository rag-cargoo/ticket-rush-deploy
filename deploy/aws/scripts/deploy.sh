#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="${SCRIPT_DIR}/../docker-compose/ticket-rush"
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.ec2.yml"

HOST=""
KEY_PATH=""
INSTANCE_ID=""
SSH_USER="ec2-user"
AWS_REGION="ap-northeast-2"
ACCOUNT_ID=""
BACKEND_REPO=""
BACKEND_TAG=""
FRONTEND_REPO=""
FRONTEND_TAG=""
REMOTE_DIR="/opt/ticket-rush"
SEED_ENABLED="true"
SEED_MARKER_KEY="kpop20_seed_marker_v1"

usage() {
  cat <<USAGE
Usage:
  # SSH mode
  deploy.sh --host <EC2_PUBLIC_IP> --key <PEM_PATH> --account-id <AWS_ACCOUNT_ID> \\
    --backend-repo <ECR_REPO> --backend-tag <TAG> --frontend-repo <ECR_REPO> --frontend-tag <TAG> [options]

  # SSM mode (no key pair)
  deploy.sh --instance-id <EC2_INSTANCE_ID> --account-id <AWS_ACCOUNT_ID> \\
    --backend-repo <ECR_REPO> --backend-tag <TAG> --frontend-repo <ECR_REPO> --frontend-tag <TAG> [options]

Options:
  --instance-id <EC2_INSTANCE_ID>   (SSM mode)
  --user <SSH_USER>                (default: ec2-user)
  --aws-region <REGION>            (default: ap-northeast-2)
  --remote-dir <PATH>              (default: /opt/ticket-rush)
  --seed-enabled <true|false>      (default: true)
  --seed-marker-key <KEY>          (default: kpop20_seed_marker_v1)
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --key) KEY_PATH="$2"; shift 2 ;;
    --instance-id) INSTANCE_ID="$2"; shift 2 ;;
    --user) SSH_USER="$2"; shift 2 ;;
    --aws-region) AWS_REGION="$2"; shift 2 ;;
    --account-id) ACCOUNT_ID="$2"; shift 2 ;;
    --backend-repo) BACKEND_REPO="$2"; shift 2 ;;
    --backend-tag) BACKEND_TAG="$2"; shift 2 ;;
    --frontend-repo) FRONTEND_REPO="$2"; shift 2 ;;
    --frontend-tag) FRONTEND_TAG="$2"; shift 2 ;;
    --remote-dir) REMOTE_DIR="$2"; shift 2 ;;
    --seed-enabled) SEED_ENABLED="$2"; shift 2 ;;
    --seed-marker-key) SEED_MARKER_KEY="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

for required in ACCOUNT_ID BACKEND_REPO BACKEND_TAG FRONTEND_REPO FRONTEND_TAG; do
  if [[ -z "${!required}" ]]; then
    echo "[ERROR] missing required arg: ${required}" >&2
    usage
    exit 1
  fi
done

MODE=""
if [[ -n "${INSTANCE_ID}" ]]; then
  MODE="ssm"
elif [[ -n "${HOST}" && -n "${KEY_PATH}" ]]; then
  MODE="ssh"
else
  echo "[ERROR] choose either SSH mode (--host + --key) or SSM mode (--instance-id)" >&2
  usage
  exit 1
fi

if [[ "${MODE}" == "ssh" && ! -f "${KEY_PATH}" ]]; then
  echo "[ERROR] key not found: ${KEY_PATH}" >&2
  exit 1
fi

ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
TMP_ENV="$(mktemp)"
TMP_REMOTE_SCRIPT="$(mktemp)"
trap 'rm -f "${TMP_ENV}" "${TMP_REMOTE_SCRIPT}"' EXIT

cat > "${TMP_ENV}" <<ENV
AWS_REGION=${AWS_REGION}
ECR_REGISTRY=${ECR_REGISTRY}
BACKEND_IMAGE_REPO=${BACKEND_REPO}
BACKEND_IMAGE_TAG=${BACKEND_TAG}
FRONTEND_IMAGE_REPO=${FRONTEND_REPO}
FRONTEND_IMAGE_TAG=${FRONTEND_TAG}
APP_SEED_KPOP20_ENABLED=${SEED_ENABLED}
APP_SEED_KPOP20_MARKER_KEY=${SEED_MARKER_KEY}
ENV

deploy_via_ssh() {
  SSH_OPTS=(-i "${KEY_PATH}" -o StrictHostKeyChecking=accept-new)

  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${HOST}" "mkdir -p ${REMOTE_DIR}"
  scp "${SSH_OPTS[@]}" "${COMPOSE_FILE}" "${SSH_USER}@${HOST}:${REMOTE_DIR}/docker-compose.ec2.yml"
  scp "${SSH_OPTS[@]}" "${TMP_ENV}" "${SSH_USER}@${HOST}:${REMOTE_DIR}/.env"

  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${HOST}" bash -s <<REMOTE
set -euo pipefail
cd "${REMOTE_DIR}"
aws ecr get-login-password --region "${AWS_REGION}" | docker login --username AWS --password-stdin "${ECR_REGISTRY}"
docker compose --env-file .env -f docker-compose.ec2.yml pull
docker compose --env-file .env -f docker-compose.ec2.yml up -d
docker compose --env-file .env -f docker-compose.ec2.yml ps
REMOTE

  echo "[OK] deployed to ${HOST} (ssh)"
}

deploy_via_ssm() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "[ERROR] jq is required for ssm mode" >&2
    exit 1
  fi

  COMPOSE_B64="$(base64 -w0 "${COMPOSE_FILE}")"
  ENV_B64="$(base64 -w0 "${TMP_ENV}")"

  cat > "${TMP_REMOTE_SCRIPT}" <<REMOTE_SCRIPT
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "${REMOTE_DIR}"
cat <<'EOF' | base64 -d > "${REMOTE_DIR}/docker-compose.ec2.yml"
${COMPOSE_B64}
EOF
cat <<'EOF' | base64 -d > "${REMOTE_DIR}/.env"
${ENV_B64}
EOF
cd "${REMOTE_DIR}"
aws ecr get-login-password --region "${AWS_REGION}" | docker login --username AWS --password-stdin "${ECR_REGISTRY}"
docker compose --env-file .env -f docker-compose.ec2.yml pull
docker compose --env-file .env -f docker-compose.ec2.yml up -d
docker compose --env-file .env -f docker-compose.ec2.yml ps
REMOTE_SCRIPT

  REMOTE_SCRIPT_B64="$(base64 -w0 "${TMP_REMOTE_SCRIPT}")"
  SSM_COMMAND="set -euo pipefail; echo '${REMOTE_SCRIPT_B64}' | base64 -d > /tmp/ticket-rush-deploy.sh; bash /tmp/ticket-rush-deploy.sh"
  SSM_PARAMS="$(jq -nc --arg cmd "${SSM_COMMAND}" '{commands:[$cmd]}')"

  for _ in $(seq 1 30); do
    status="$(aws ssm describe-instance-information \
      --region "${AWS_REGION}" \
      --filters "Key=InstanceIds,Values=${INSTANCE_ID}" \
      --query 'InstanceInformationList[0].PingStatus' \
      --output text 2>/dev/null || true)"
    if [[ "${status}" == "Online" ]]; then
      break
    fi
    sleep 10
  done

  COMMAND_ID="$(aws ssm send-command \
    --region "${AWS_REGION}" \
    --instance-ids "${INSTANCE_ID}" \
    --document-name "AWS-RunShellScript" \
    --comment "ticket-rush deploy via ssm" \
    --parameters "${SSM_PARAMS}" \
    --query 'Command.CommandId' \
    --output text)"

  FINAL_STATUS=""
  for _ in $(seq 1 60); do
    FINAL_STATUS="$(aws ssm get-command-invocation \
      --region "${AWS_REGION}" \
      --command-id "${COMMAND_ID}" \
      --instance-id "${INSTANCE_ID}" \
      --query 'Status' \
      --output text 2>/dev/null || true)"
    case "${FINAL_STATUS}" in
      Success|Failed|TimedOut|Cancelled|Undeliverable|Terminated)
        break
        ;;
      *)
        sleep 5
        ;;
    esac
  done

  aws ssm get-command-invocation \
    --region "${AWS_REGION}" \
    --command-id "${COMMAND_ID}" \
    --instance-id "${INSTANCE_ID}" \
    --query '{Status:Status,StdOut:StandardOutputContent,StdErr:StandardErrorContent}' \
    --output json

  if [[ "${FINAL_STATUS}" != "Success" ]]; then
    echo "[ERROR] ssm deploy failed: ${FINAL_STATUS}" >&2
    exit 1
  fi

  echo "[OK] deployed to ${INSTANCE_ID} (ssm)"
}

if [[ "${MODE}" == "ssm" ]]; then
  deploy_via_ssm
else
  deploy_via_ssh
fi
