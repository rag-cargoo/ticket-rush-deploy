SHELL := /bin/bash

TF_DIR := deploy/aws/terraform
DEPLOY_SCRIPT := deploy/aws/scripts/deploy.sh
ECR_SCRIPT := deploy/aws/scripts/create_ecr_repos.sh

AWS_REGION ?= ap-northeast-2
PROJECT_NAME ?= ticket-rush
ENVIRONMENT ?= dev
ACCOUNT_ID ?= $(shell aws sts get-caller-identity --query Account --output text 2>/dev/null)

BACKEND_IMAGE_REPO ?= ticketrush/backend
BACKEND_IMAGE_TAG ?= latest
FRONTEND_IMAGE_REPO ?= ticketrush/frontend
FRONTEND_IMAGE_TAG ?= latest

APP_DOMAIN ?= goopang.shop
SEED_ENABLED ?= true
SEED_MARKER_KEY ?= kpop20_seed_marker_v1

INSTANCE_ID ?= $(shell terraform -chdir=$(TF_DIR) output -raw instance_id 2>/dev/null || true)

.PHONY: help tf-init infra-plan infra-apply infra-output infra-destroy destroy create-ecr deploy deploy-no-seed

help:
	@echo "Usage:"
	@echo "  make infra-apply      # terraform init+apply"
	@echo "  make deploy           # SSM deploy (compose pull/up)"
	@echo "  make destroy          # terraform destroy"
	@echo ""
	@echo "Variables (override):"
	@echo "  AWS_REGION=$(AWS_REGION)"
	@echo "  ACCOUNT_ID=<aws-account-id>"
	@echo "  INSTANCE_ID=<ec2-instance-id> (default: terraform output)"
	@echo "  BACKEND_IMAGE_REPO=$(BACKEND_IMAGE_REPO)"
	@echo "  BACKEND_IMAGE_TAG=$(BACKEND_IMAGE_TAG)"
	@echo "  FRONTEND_IMAGE_REPO=$(FRONTEND_IMAGE_REPO)"
	@echo "  FRONTEND_IMAGE_TAG=$(FRONTEND_IMAGE_TAG)"
	@echo "  APP_DOMAIN=$(APP_DOMAIN)"
	@echo "  SEED_ENABLED=$(SEED_ENABLED)"

tf-init:
	terraform -chdir=$(TF_DIR) init

infra-plan:
	terraform -chdir=$(TF_DIR) plan

infra-apply: tf-init
	terraform -chdir=$(TF_DIR) apply -auto-approve

infra-output:
	terraform -chdir=$(TF_DIR) output

infra-destroy:
	terraform -chdir=$(TF_DIR) destroy -auto-approve

destroy: infra-destroy

create-ecr:
	@if [ -z "$(ACCOUNT_ID)" ]; then echo "[ERROR] ACCOUNT_ID is empty. Set ACCOUNT_ID or configure aws credentials."; exit 1; fi
	bash $(ECR_SCRIPT) --aws-region $(AWS_REGION) --repos $(BACKEND_IMAGE_REPO),$(FRONTEND_IMAGE_REPO)

deploy:
	@if [ -z "$(ACCOUNT_ID)" ]; then echo "[ERROR] ACCOUNT_ID is empty. Set ACCOUNT_ID or configure aws credentials."; exit 1; fi
	@if [ -z "$(INSTANCE_ID)" ]; then echo "[ERROR] INSTANCE_ID is empty. Run make infra-apply first or set INSTANCE_ID."; exit 1; fi
	bash $(DEPLOY_SCRIPT) \
		--instance-id $(INSTANCE_ID) \
		--account-id $(ACCOUNT_ID) \
		--aws-region $(AWS_REGION) \
		--backend-repo $(BACKEND_IMAGE_REPO) \
		--backend-tag $(BACKEND_IMAGE_TAG) \
		--frontend-repo $(FRONTEND_IMAGE_REPO) \
		--frontend-tag $(FRONTEND_IMAGE_TAG) \
		--seed-enabled $(SEED_ENABLED) \
		--seed-marker-key $(SEED_MARKER_KEY) \
		--app-domain $(APP_DOMAIN)

deploy-no-seed:
	$(MAKE) deploy SEED_ENABLED=false
