# Homelab task runner. `make help` lists targets.
# lint/validate run anywhere (CI included); up-pi/down-pi/backup run on n8npi;
# health runs on any tailnet device.

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c

ENV_FILE ?= .env
# Validation uses the committed placeholders unless told otherwise.
VALIDATE_ENV ?= .env.example
COMPOSE_PI := docker compose --env-file $(ENV_FILE) -f pi/docker-compose.yml
SH_FILES := $(shell git ls-files --cached --others --exclude-standard '*.sh' 2>/dev/null || find . -name '*.sh' -not -path './.git/*')

.DEFAULT_GOAL := help
.PHONY: help lint validate check-env up-pi down-pi backup health

help: ## Show this help
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-10s %s\n", $$1, $$2}'

lint: ## yamllint + shellcheck
	yamllint .
	shellcheck -x $(SH_FILES)

validate: ## compose config, workflow JSON, plist, secret scan
	docker compose --env-file $(VALIDATE_ENV) -f pi/docker-compose.yml config --quiet
	docker compose --env-file $(VALIDATE_ENV) -f openclaw/docker-compose.yml config --quiet
	./scripts/validate-workflows.sh n8n-workflows/*.json
	python3 -c "import plistlib,sys; plistlib.load(open(sys.argv[1],'rb'))" mac/com.homelab.ollama.plist
	./scripts/check-no-secrets.sh
	@echo "validate: OK"

check-env:
	@test -f $(ENV_FILE) || { echo "missing $(ENV_FILE): cp .env.example .env and fill it in"; exit 1; }

up-pi: check-env ## Start n8n on the Pi
	$(COMPOSE_PI) up -d
	$(COMPOSE_PI) ps

down-pi: check-env ## Stop n8n on the Pi (data volume is kept)
	$(COMPOSE_PI) down

backup: check-env ## Back up the n8n volume now
	ENV_FILE=$(ENV_FILE) ./scripts/backup-n8n.sh

health: ## Print the OK/FAIL health table
	./scripts/healthcheck.sh --env-file $(ENV_FILE)
