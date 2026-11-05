# Homelab task runner. `make help` lists targets.
# Real deployment on n8npi:  make install && make up-pi && make provision
# lint/validate/test run anywhere (CI included); install/preflight/up-pi/
# provision/update/backup run on n8npi; health and dashboard-dev anywhere.

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c

ENV_FILE ?= .env
# Validation uses the committed placeholders unless told otherwise.
VALIDATE_ENV ?= .env.example
COMPOSE_PI := docker compose --env-file $(ENV_FILE) -f pi/docker-compose.yml
SH_FILES := $(shell git ls-files --cached --others --exclude-standard '*.sh' 2>/dev/null || find . -name '*.sh' -not -path './.git/*')

.DEFAULT_GOAL := help
.PHONY: help install preflight lint validate test build-dashboard dashboard-dev check-env up-pi down-pi provision update backup health logs

help: ## Show this help
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-16s %s\n", $$1, $$2}'

install: ## Bootstrap n8npi: fill .env, adopt/generate secrets, dirs, systemd
	./scripts/install-pi.sh --env-file $(ENV_FILE)

preflight: ## Check this device is ready to deploy (Pi or Mac)
	./scripts/preflight.sh --env-file $(ENV_FILE)

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

test: ## Dashboard unit tests, JS syntax, installer/preflight regression test
	python3 -m unittest discover -s dashboard/tests -v
	node --check dashboard/static/app.js
	./scripts/tests/test-install-pi.sh
	@echo "test: OK"

build-dashboard: ## Build the dashboard image (up-pi does this too)
	docker build -t homelab-dashboard:local dashboard

dashboard-dev: check-env ## Run the dashboard on 127.0.0.1:8080 using .env
	./scripts/dashboard-dev.sh --env-file $(ENV_FILE)

check-env:
	@test -f $(ENV_FILE) || { echo "missing $(ENV_FILE): cp .env.example .env and fill it in"; exit 1; }

up-pi: check-env ## Preflight, then start n8n + LiteLLM + dashboard on the Pi
	@if [ "$(SKIP_PREFLIGHT)" != 1 ]; then ./scripts/preflight.sh --env-file $(ENV_FILE) --quiet; fi
	$(COMPOSE_PI) up -d --build
	$(COMPOSE_PI) ps

provision: check-env ## Create n8n credentials, import + activate workflows from .env
	./scripts/provision-n8n.sh --env-file $(ENV_FILE)

update: check-env ## Update n8n and LiteLLM images with rollback
	./scripts/update.sh --service all --env-file $(ENV_FILE)

logs: check-env ## Follow logs of the Pi stack
	$(COMPOSE_PI) logs -f --tail=100

down-pi: check-env ## Stop the Pi stack (data volume is kept)
	$(COMPOSE_PI) down

backup: check-env ## Back up the n8n volume now
	ENV_FILE=$(ENV_FILE) ./scripts/backup-n8n.sh

health: ## Print the OK/FAIL health table
	./scripts/healthcheck.sh --env-file $(ENV_FILE)
