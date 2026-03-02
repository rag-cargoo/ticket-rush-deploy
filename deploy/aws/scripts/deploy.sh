#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="${SCRIPT_DIR}/../docker-compose/ticket-rush"
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.ec2.yml"
CADDY_FILE="${COMPOSE_DIR}/Caddyfile"

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
APP_DOMAIN="goopang.shop"
FRONTEND_ALLOWED_ORIGINS=""
U1_CALLBACK_URL=""

KAKAO_CLIENT_ID=""
KAKAO_CLIENT_SECRET=""
KAKAO_REDIRECT_URI=""

NAVER_CLIENT_ID=""
NAVER_CLIENT_SECRET=""
NAVER_REDIRECT_URI=""
NAVER_SERVICE_URL=""

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
  --app-domain <DOMAIN>            (default: goopang.shop)
  --frontend-allowed-origins <CSV> (default: https://<domain>,https://www.<domain>,http://localhost:8080,http://127.0.0.1:8080)
  --u1-callback-url <URL>          (default: https://<domain>/ux/u1/callback.html)

  --kakao-client-id <VALUE>
  --kakao-client-secret <VALUE>
  --kakao-redirect-uri <URL>       (default: https://<domain>/login/oauth2/code/kakao)

  --naver-client-id <VALUE>
  --naver-client-secret <VALUE>
  --naver-redirect-uri <URL>       (default: https://<domain>/login/oauth2/code/naver)
  --naver-service-url <URL>        (default: https://<domain>)
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
    --app-domain) APP_DOMAIN="$2"; shift 2 ;;
    --frontend-allowed-origins) FRONTEND_ALLOWED_ORIGINS="$2"; shift 2 ;;
    --u1-callback-url) U1_CALLBACK_URL="$2"; shift 2 ;;
    --kakao-client-id) KAKAO_CLIENT_ID="$2"; shift 2 ;;
    --kakao-client-secret) KAKAO_CLIENT_SECRET="$2"; shift 2 ;;
    --kakao-redirect-uri) KAKAO_REDIRECT_URI="$2"; shift 2 ;;
    --naver-client-id) NAVER_CLIENT_ID="$2"; shift 2 ;;
    --naver-client-secret) NAVER_CLIENT_SECRET="$2"; shift 2 ;;
    --naver-redirect-uri) NAVER_REDIRECT_URI="$2"; shift 2 ;;
    --naver-service-url) NAVER_SERVICE_URL="$2"; shift 2 ;;
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

if [[ -z "${FRONTEND_ALLOWED_ORIGINS}" ]]; then
  FRONTEND_ALLOWED_ORIGINS="https://${APP_DOMAIN},https://www.${APP_DOMAIN},http://localhost:8080,http://127.0.0.1:8080"
fi

if [[ -z "${U1_CALLBACK_URL}" ]]; then
  U1_CALLBACK_URL="https://${APP_DOMAIN}/ux/u1/callback.html"
fi

if [[ -z "${KAKAO_REDIRECT_URI}" ]]; then
  KAKAO_REDIRECT_URI="https://${APP_DOMAIN}/login/oauth2/code/kakao"
fi

if [[ -z "${NAVER_REDIRECT_URI}" ]]; then
  NAVER_REDIRECT_URI="https://${APP_DOMAIN}/login/oauth2/code/naver"
fi

if [[ -z "${NAVER_SERVICE_URL}" ]]; then
  NAVER_SERVICE_URL="https://${APP_DOMAIN}"
fi

if [[ -z "${KAKAO_CLIENT_ID}" || -z "${KAKAO_CLIENT_SECRET}" || -z "${NAVER_CLIENT_ID}" || -z "${NAVER_CLIENT_SECRET}" ]]; then
  echo "[WARN] OAuth client env is incomplete. deploy will try to preserve existing remote KAKAO_*/NAVER_* values." >&2
fi

cat > "${TMP_ENV}" <<ENV
AWS_REGION=${AWS_REGION}
ECR_REGISTRY=${ECR_REGISTRY}
BACKEND_IMAGE_REPO=${BACKEND_REPO}
BACKEND_IMAGE_TAG=${BACKEND_TAG}
FRONTEND_IMAGE_REPO=${FRONTEND_REPO}
FRONTEND_IMAGE_TAG=${FRONTEND_TAG}
APP_SEED_KPOP20_ENABLED=${SEED_ENABLED}
APP_SEED_KPOP20_MARKER_KEY=${SEED_MARKER_KEY}
APP_DOMAIN=${APP_DOMAIN}
FRONTEND_ALLOWED_ORIGINS=${FRONTEND_ALLOWED_ORIGINS}
U1_CALLBACK_URL=${U1_CALLBACK_URL}
KAKAO_CLIENT_ID=${KAKAO_CLIENT_ID}
KAKAO_CLIENT_SECRET=${KAKAO_CLIENT_SECRET}
KAKAO_REDIRECT_URI=${KAKAO_REDIRECT_URI}
NAVER_CLIENT_ID=${NAVER_CLIENT_ID}
NAVER_CLIENT_SECRET=${NAVER_CLIENT_SECRET}
NAVER_REDIRECT_URI=${NAVER_REDIRECT_URI}
NAVER_SERVICE_URL=${NAVER_SERVICE_URL}
ENV

deploy_via_ssh() {
  SSH_OPTS=(-i "${KEY_PATH}" -o StrictHostKeyChecking=accept-new)

  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${HOST}" "mkdir -p ${REMOTE_DIR}"
  scp "${SSH_OPTS[@]}" "${COMPOSE_FILE}" "${SSH_USER}@${HOST}:${REMOTE_DIR}/docker-compose.ec2.yml"
  scp "${SSH_OPTS[@]}" "${CADDY_FILE}" "${SSH_USER}@${HOST}:${REMOTE_DIR}/Caddyfile"
  scp "${SSH_OPTS[@]}" "${TMP_ENV}" "${SSH_USER}@${HOST}:${REMOTE_DIR}/.env.new"

  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${HOST}" bash -s <<REMOTE
set -euo pipefail

read_env_value() {
  local file="\$1"
  local key="\$2"
  if [[ ! -f "\${file}" ]]; then
    return 0
  fi
  awk -F= -v key="\${key}" '
    \$1 == key {
      print substr(\$0, index(\$0, "=") + 1)
      exit
    }
  ' "\${file}"
}

upsert_env_value() {
  local file="\$1"
  local key="\$2"
  local value="\$3"
  awk -v key="\${key}" -v value="\${value}" '
    BEGIN { found = 0 }
    \$0 ~ ("^" key "=") {
      print key "=" value
      found = 1
      next
    }
    { print }
    END {
      if (!found) {
        print key "=" value
      }
    }
  ' "\${file}" > "\${file}.tmp"
  mv "\${file}.tmp" "\${file}"
}

merge_oauth_env() {
  local incoming_file="${REMOTE_DIR}/.env.new"
  local existing_file="${REMOTE_DIR}/.env"
  local existing_snapshot_file="${REMOTE_DIR}/.env.existing"
  local merged_file="${REMOTE_DIR}/.env"
  local keys=(KAKAO_CLIENT_ID KAKAO_CLIENT_SECRET NAVER_CLIENT_ID NAVER_CLIENT_SECRET)
  local fallback_count=0
  local missing_keys=()

  if [[ -f "\${existing_file}" ]]; then
    cp "\${existing_file}" "\${existing_snapshot_file}"
  else
    : > "\${existing_snapshot_file}"
  fi
  cp "\${incoming_file}" "\${merged_file}"
  for key in "\${keys[@]}"; do
    local incoming_value existing_value merged_value
    incoming_value="\$(read_env_value "\${incoming_file}" "\${key}")"
    existing_value="\$(read_env_value "\${existing_snapshot_file}" "\${key}")"
    merged_value="\${incoming_value}"
    if [[ -z "\${merged_value}" && -n "\${existing_value}" ]]; then
      merged_value="\${existing_value}"
      fallback_count=\$((fallback_count + 1))
    fi
    upsert_env_value "\${merged_file}" "\${key}" "\${merged_value}"
    if [[ -z "\${merged_value}" ]]; then
      missing_keys+=("\${key}")
    fi
  done

  rm -f "\${incoming_file}"
  rm -f "\${existing_snapshot_file}"
  if (( fallback_count > 0 )); then
    echo "[INFO] preserved remote OAuth values from existing .env (fallback_count=\${fallback_count})"
  fi
  if (( \${#missing_keys[@]} > 0 )); then
    echo "[WARN] missing OAuth values after merge: \${missing_keys[*]}" >&2
  fi
}

wait_for_backend_healthy() {
  local max_attempts=90
  local sleep_secs=2
  local status=""

  for _ in \$(seq 1 "\${max_attempts}"); do
    status="\$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' ticket-rush-backend 2>/dev/null || true)"
    case "\${status}" in
      healthy)
        echo "[OK] backend healthcheck passed"
        return 0
        ;;
      unhealthy)
        echo "[ERROR] backend healthcheck is unhealthy" >&2
        docker logs --tail 120 ticket-rush-backend || true
        return 1
        ;;
      *)
        ;;
    esac
    sleep "\${sleep_secs}"
  done

  echo "[ERROR] backend healthcheck timeout after \$((max_attempts * sleep_secs))s (last_status=\${status:-unknown})" >&2
  docker logs --tail 120 ticket-rush-backend || true
  return 1
}

wait_for_frontend_api_proxy() {
  local max_attempts=60
  local sleep_secs=2

  for _ in \$(seq 1 "\${max_attempts}"); do
    if docker exec ticket-rush-frontend wget -qO- "http://127.0.0.1/api/concerts/search?page=0&size=1" >/dev/null 2>&1; then
      echo "[OK] frontend /api proxy probe passed"
      return 0
    fi
    sleep "\${sleep_secs}"
  done

  echo "[ERROR] frontend /api proxy probe timeout after \$((max_attempts * sleep_secs))s" >&2
  docker logs --tail 120 ticket-rush-frontend || true
  docker logs --tail 120 ticket-rush-backend || true
  return 1
}

cd "${REMOTE_DIR}"
merge_oauth_env
aws ecr get-login-password --region "${AWS_REGION}" | docker login --username AWS --password-stdin "${ECR_REGISTRY}"
docker compose --env-file .env -f docker-compose.ec2.yml pull
docker compose --env-file .env -f docker-compose.ec2.yml up -d
wait_for_backend_healthy
wait_for_frontend_api_proxy
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
  CADDY_B64="$(base64 -w0 "${CADDY_FILE}")"
  ENV_B64="$(base64 -w0 "${TMP_ENV}")"

  cat > "${TMP_REMOTE_SCRIPT}" <<REMOTE_SCRIPT
#!/usr/bin/env bash
set -euo pipefail

wait_for_backend_healthy() {
  local max_attempts=90
  local sleep_secs=2
  local status=""

  for _ in \$(seq 1 "\${max_attempts}"); do
    status="\$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' ticket-rush-backend 2>/dev/null || true)"
    case "\${status}" in
      healthy)
        echo "[OK] backend healthcheck passed"
        return 0
        ;;
      unhealthy)
        echo "[ERROR] backend healthcheck is unhealthy" >&2
        docker logs --tail 120 ticket-rush-backend || true
        return 1
        ;;
      *)
        ;;
    esac
    sleep "\${sleep_secs}"
  done

  echo "[ERROR] backend healthcheck timeout after \$((max_attempts * sleep_secs))s (last_status=\${status:-unknown})" >&2
  docker logs --tail 120 ticket-rush-backend || true
  return 1
}

wait_for_frontend_api_proxy() {
  local max_attempts=60
  local sleep_secs=2

  for _ in \$(seq 1 "\${max_attempts}"); do
    if docker exec ticket-rush-frontend wget -qO- "http://127.0.0.1/api/concerts/search?page=0&size=1" >/dev/null 2>&1; then
      echo "[OK] frontend /api proxy probe passed"
      return 0
    fi
    sleep "\${sleep_secs}"
  done

  echo "[ERROR] frontend /api proxy probe timeout after \$((max_attempts * sleep_secs))s" >&2
  docker logs --tail 120 ticket-rush-frontend || true
  docker logs --tail 120 ticket-rush-backend || true
  return 1
}

mkdir -p "${REMOTE_DIR}"
cat <<'EOF' | base64 -d > "${REMOTE_DIR}/docker-compose.ec2.yml"
${COMPOSE_B64}
EOF
cat <<'EOF' | base64 -d > "${REMOTE_DIR}/Caddyfile"
${CADDY_B64}
EOF
cat <<'EOF' | base64 -d > "${REMOTE_DIR}/.env.new"
${ENV_B64}
EOF
read_env_value() {
  local file="\$1"
  local key="\$2"
  if [[ ! -f "\${file}" ]]; then
    return 0
  fi
  awk -F= -v key="\${key}" '
    \$1 == key {
      print substr(\$0, index(\$0, "=") + 1)
      exit
    }
  ' "\${file}"
}
upsert_env_value() {
  local file="\$1"
  local key="\$2"
  local value="\$3"
  awk -v key="\${key}" -v value="\${value}" '
    BEGIN { found = 0 }
    \$0 ~ ("^" key "=") {
      print key "=" value
      found = 1
      next
    }
    { print }
    END {
      if (!found) {
        print key "=" value
      }
    }
  ' "\${file}" > "\${file}.tmp"
  mv "\${file}.tmp" "\${file}"
}
merge_oauth_env() {
  local incoming_file="${REMOTE_DIR}/.env.new"
  local existing_file="${REMOTE_DIR}/.env"
  local existing_snapshot_file="${REMOTE_DIR}/.env.existing"
  local merged_file="${REMOTE_DIR}/.env"
  local keys=(KAKAO_CLIENT_ID KAKAO_CLIENT_SECRET NAVER_CLIENT_ID NAVER_CLIENT_SECRET)
  local fallback_count=0
  local missing_keys=()

  if [[ -f "\${existing_file}" ]]; then
    cp "\${existing_file}" "\${existing_snapshot_file}"
  else
    : > "\${existing_snapshot_file}"
  fi
  cp "\${incoming_file}" "\${merged_file}"
  for key in "\${keys[@]}"; do
    local incoming_value existing_value merged_value
    incoming_value="\$(read_env_value "\${incoming_file}" "\${key}")"
    existing_value="\$(read_env_value "\${existing_snapshot_file}" "\${key}")"
    merged_value="\${incoming_value}"
    if [[ -z "\${merged_value}" && -n "\${existing_value}" ]]; then
      merged_value="\${existing_value}"
      fallback_count=\$((fallback_count + 1))
    fi
    upsert_env_value "\${merged_file}" "\${key}" "\${merged_value}"
    if [[ -z "\${merged_value}" ]]; then
      missing_keys+=("\${key}")
    fi
  done

  rm -f "\${incoming_file}"
  rm -f "\${existing_snapshot_file}"
  if (( fallback_count > 0 )); then
    echo "[INFO] preserved remote OAuth values from existing .env (fallback_count=\${fallback_count})"
  fi
  if (( \${#missing_keys[@]} > 0 )); then
    echo "[WARN] missing OAuth values after merge: \${missing_keys[*]}" >&2
  fi
}
cd "${REMOTE_DIR}"
merge_oauth_env
aws ecr get-login-password --region "${AWS_REGION}" | docker login --username AWS --password-stdin "${ECR_REGISTRY}"
docker compose --env-file .env -f docker-compose.ec2.yml pull
docker compose --env-file .env -f docker-compose.ec2.yml up -d
wait_for_backend_healthy
wait_for_frontend_api_proxy
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
