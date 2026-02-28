#!/usr/bin/env bash
set -euo pipefail

AWS_REGION="${AWS_REGION:-ap-northeast-2}"
BACKEND_REPO="${BACKEND_REPO:-ticketrush/backend}"
FRONTEND_REPO="${FRONTEND_REPO:-ticketrush/frontend}"

ensure_repo() {
  local repo="$1"
  if aws ecr describe-repositories --region "${AWS_REGION}" --repository-names "${repo}" >/dev/null 2>&1; then
    echo "[SKIP] ECR repo exists: ${repo}"
    return 0
  fi

  aws ecr create-repository \
    --region "${AWS_REGION}" \
    --repository-name "${repo}" \
    --image-scanning-configuration scanOnPush=true \
    >/dev/null
  echo "[OK] ECR repo created: ${repo}"
}

ensure_repo "${BACKEND_REPO}"
ensure_repo "${FRONTEND_REPO}"
