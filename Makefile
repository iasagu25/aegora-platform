SHELL := /usr/bin/env bash

TENANT ?= aegora
TENANT_DIR := customers/$(TENANT)
TENANT_CONFIG := $(TENANT_DIR)/tenant.env
TENANT_CONFIG_EXAMPLE := $(TENANT_DIR)/tenant.env.example

POSTGRES_DIR := compose/postgres
POSTGRES_COMPOSE := $(POSTGRES_DIR)/compose.yml
POSTGRES_ENV := $(POSTGRES_DIR)/.env
POSTGRES_SERVICE := postgres
POSTGRES_CONTAINER := aegora-postgres

DIRECTUS_DIR := compose/directus
DIRECTUS_COMPOSE := $(DIRECTUS_DIR)/compose.yml
DIRECTUS_ENV := $(DIRECTUS_DIR)/.env

CADDY_DIR := compose/caddy
CADDY_COMPOSE := $(CADDY_DIR)/compose.yml
CADDY_ENV := $(CADDY_DIR)/.env
CADDY_CONTAINER := aegora-caddy

N8N_DIR := compose/n8n
N8N_COMPOSE := $(N8N_DIR)/compose.yml
N8N_ENV := $(N8N_DIR)/.env
N8N_CONTAINER := aegora-n8n

.DEFAULT_GOAL := help

.PHONY: help \
	check \
	postgres-config \
	postgres-pull \
	postgres-up \
	postgres-down \
	postgres-restart \
	postgres-stop \
	postgres-start \
	postgres-logs \
	postgres-ps \
	postgres-status \
	postgres-shell \
	postgres-psql \
	postgres-health \
	postgres-databases \
	postgres-users \
	caddy-config \
	caddy-pull \
	caddy-up \
	caddy-down \
	caddy-restart \
	caddy-reload \
	caddy-logs \
	caddy-ps \
	caddy-status \
	caddy-health \
	caddy-validate

help:
	@printf "\nAegora Platform\n\n"
	@printf "General:\n"
	@printf "  make check                 Validate local prerequisites\n"
	@printf "\nPostgreSQL:\n"
	@printf "  make postgres-config       Validate and render Compose configuration\n"
	@printf "  make postgres-pull         Download PostgreSQL image\n"
	@printf "  make postgres-up           Start PostgreSQL\n"
	@printf "  make postgres-down         Stop and remove PostgreSQL container\n"
	@printf "  make postgres-restart      Restart PostgreSQL\n"
	@printf "  make postgres-stop         Stop PostgreSQL without removing it\n"
	@printf "  make postgres-start        Start an existing PostgreSQL container\n"
	@printf "  make postgres-logs         Follow PostgreSQL logs\n"
	@printf "  make postgres-ps           Show PostgreSQL Compose status\n"
	@printf "  make postgres-status       Show container status and health\n"
	@printf "  make postgres-shell        Open a shell inside the container\n"
	@printf "  make postgres-psql         Open psql as PostgreSQL superuser\n"
	@printf "  make postgres-health       Run pg_isready\n"
	@printf "  make postgres-databases    List databases\n"
	@printf "  make postgres-users        List PostgreSQL roles\n\n"
	@printf "\nn8n:\n"
	@printf "  make n8n-config             Validate n8n Compose\n"
	@printf "  make n8n-pull               Download n8n image\n"
	@printf "  make n8n-up                 Start n8n\n"
	@printf "  make n8n-down               Stop and remove n8n\n"
	@printf "  make n8n-restart            Restart n8n\n"
	@printf "  make n8n-logs               Follow n8n logs\n"
	@printf "  make n8n-status             Show n8n status\n"

check:
	@command -v docker >/dev/null || { echo "ERROR: docker is not installed"; exit 1; }
	@docker compose version >/dev/null || { echo "ERROR: Docker Compose plugin is unavailable"; exit 1; }
	@command -v openssl >/dev/null || { echo "ERROR: openssl is not installed"; exit 1; }
	@docker network inspect aegora_backend >/dev/null 2>&1 || { echo "ERROR: Docker network aegora_backend does not exist"; exit 1; }
	@test -f "$(POSTGRES_ENV)" || { echo "ERROR: $(POSTGRES_ENV) does not exist"; exit 1; }
	@echo "Prerequisites OK"

postgres-config: check
	@docker compose \
		--env-file "$(POSTGRES_ENV)" \
		-f "$(POSTGRES_COMPOSE)" \
		config --quiet
	@echo "PostgreSQL Compose configuration is valid"

postgres-pull: postgres-config
	@docker compose \
		--env-file "$(POSTGRES_ENV)" \
		-f "$(POSTGRES_COMPOSE)" \
		pull

postgres-up: postgres-config
	@docker compose \
		--env-file "$(POSTGRES_ENV)" \
		-f "$(POSTGRES_COMPOSE)" \
		up -d
	@echo "Waiting for PostgreSQL..."
	@for attempt in $$(seq 1 30); do \
		status=$$(docker inspect --format='{{.State.Health.Status}}' "$(POSTGRES_CONTAINER)" 2>/dev/null || true); \
		if [ "$$status" = "healthy" ]; then \
			echo "PostgreSQL is healthy"; \
			exit 0; \
		fi; \
		if [ "$$status" = "unhealthy" ]; then \
			echo "ERROR: PostgreSQL is unhealthy"; \
			docker logs --tail 100 "$(POSTGRES_CONTAINER)"; \
			exit 1; \
		fi; \
		sleep 2; \
	done; \
	echo "ERROR: PostgreSQL health check timed out"; \
	docker logs --tail 100 "$(POSTGRES_CONTAINER)"; \
	exit 1

postgres-down:
	@docker compose \
		--env-file "$(POSTGRES_ENV)" \
		-f "$(POSTGRES_COMPOSE)" \
		down

postgres-restart:
	@docker compose \
		--env-file "$(POSTGRES_ENV)" \
		-f "$(POSTGRES_COMPOSE)" \
		restart

postgres-stop:
	@docker compose \
		--env-file "$(POSTGRES_ENV)" \
		-f "$(POSTGRES_COMPOSE)" \
		stop

postgres-start:
	@docker compose \
		--env-file "$(POSTGRES_ENV)" \
		-f "$(POSTGRES_COMPOSE)" \
		start

postgres-logs:
	@docker compose \
		--env-file "$(POSTGRES_ENV)" \
		-f "$(POSTGRES_COMPOSE)" \
		logs --follow --tail 200

postgres-ps:
	@docker compose \
		--env-file "$(POSTGRES_ENV)" \
		-f "$(POSTGRES_COMPOSE)" \
		ps

postgres-status:
	@docker inspect \
		--format='Container: {{.Name}}{{printf "\n"}}Status: {{.State.Status}}{{printf "\n"}}Health: {{if .State.Health}}{{.State.Health.Status}}{{else}}not configured{{end}}{{printf "\n"}}Started: {{.State.StartedAt}}' \
		"$(POSTGRES_CONTAINER)"

postgres-shell:
	@docker exec -it "$(POSTGRES_CONTAINER)" bash

postgres-psql:
	@docker exec -it "$(POSTGRES_CONTAINER)" \
		psql --username postgres --dbname postgres

postgres-health:
	@docker exec "$(POSTGRES_CONTAINER)" \
		pg_isready --username postgres --dbname postgres

postgres-databases:
	@docker exec "$(POSTGRES_CONTAINER)" \
		psql \
		--username postgres \
		--dbname postgres \
		--command='\l'

postgres-users:
	@docker exec "$(POSTGRES_CONTAINER)" \
		psql \
		--username postgres \
		--dbname postgres \
		--command='\du'


## ===== DIRECTUS =====

directus-config:
	@test -f $(DIRECTUS_ENV) || (echo "❌ Falta $(DIRECTUS_ENV)" && exit 1)
	@docker compose \
		--env-file $(DIRECTUS_ENV) \
		-f $(DIRECTUS_COMPOSE) \
		config >/dev/null
	@echo "✅ Directus compose OK"

directus-up:
	@docker compose \
		--env-file $(DIRECTUS_ENV) \
		-f $(DIRECTUS_COMPOSE) \
		up -d

directus-down:
	@docker compose \
		--env-file $(DIRECTUS_ENV) \
		-f $(DIRECTUS_COMPOSE) \
		down

directus-logs:
	@docker compose \
		--env-file $(DIRECTUS_ENV) \
		-f $(DIRECTUS_COMPOSE) \
		logs -f

directus-ps:
	@docker compose \
		--env-file $(DIRECTUS_ENV) \
		-f $(DIRECTUS_COMPOSE) \
		ps

directus-health:
	@docker inspect \
		--format='{{.State.Health.Status}}' \
		aegora-directus

directus-shell:
	@docker exec -it aegora-directus sh

## ===== CADDY =====

caddy-config:
	@test -f "$(CADDY_ENV)" || { echo "ERROR: falta $(CADDY_ENV)"; exit 1; }
	@docker compose \
		--env-file "$(CADDY_ENV)" \
		-f "$(CADDY_COMPOSE)" \
		config --quiet
	@echo "Caddy Compose configuration is valid"

caddy-pull: caddy-config
	@docker compose \
		--env-file "$(CADDY_ENV)" \
		-f "$(CADDY_COMPOSE)" \
		pull

caddy-validate:
	@docker run --rm \
		--env-file "$(CADDY_ENV)" \
		-v "$(CURDIR)/$(CADDY_DIR)/Caddyfile:/etc/caddy/Caddyfile:ro" \
		caddy:2.11.4-alpine \
		caddy validate --config /etc/caddy/Caddyfile

caddy-up: caddy-config caddy-validate
	@docker compose \
		--env-file "$(CADDY_ENV)" \
		-f "$(CADDY_COMPOSE)" \
		up -d
	@echo "Waiting for Caddy..."
	@for attempt in $$(seq 1 20); do \
		status=$$(docker inspect --format='{{.State.Health.Status}}' "$(CADDY_CONTAINER)" 2>/dev/null || true); \
		if [ "$$status" = "healthy" ]; then \
			echo "Caddy is healthy"; \
			exit 0; \
		fi; \
		if [ "$$status" = "unhealthy" ]; then \
			echo "ERROR: Caddy is unhealthy"; \
			docker logs --tail 100 "$(CADDY_CONTAINER)"; \
			exit 1; \
		fi; \
		sleep 2; \
	done; \
	echo "ERROR: Caddy health check timed out"; \
	docker logs --tail 100 "$(CADDY_CONTAINER)"; \
	exit 1

caddy-down:
	@docker compose \
		--env-file "$(CADDY_ENV)" \
		-f "$(CADDY_COMPOSE)" \
		down

caddy-restart:
	@docker compose \
		--env-file "$(CADDY_ENV)" \
		-f "$(CADDY_COMPOSE)" \
		restart

caddy-reload: caddy-validate
	@docker exec "$(CADDY_CONTAINER)" \
		caddy reload \
		--config /etc/caddy/Caddyfile
	@echo "Caddy configuration reloaded"

caddy-logs:
	@docker compose \
		--env-file "$(CADDY_ENV)" \
		-f "$(CADDY_COMPOSE)" \
		logs --follow --tail 200

caddy-ps:
	@docker compose \
		--env-file "$(CADDY_ENV)" \
		-f "$(CADDY_COMPOSE)" \
		ps

caddy-status:
	@docker inspect \
		--format='Container: {{.Name}}{{printf "\n"}}Status: {{.State.Status}}{{printf "\n"}}Health: {{if .State.Health}}{{.State.Health.Status}}{{else}}not configured{{end}}{{printf "\n"}}Started: {{.State.StartedAt}}' \
		"$(CADDY_CONTAINER)"

caddy-health:
	@docker inspect \
		--format='{{if .State.Health}}{{.State.Health.Status}}{{else}}not configured{{end}}' \
		"$(CADDY_CONTAINER)"

## ===== N8N =====

n8n-config:
	@test -f "$(N8N_ENV)" || { echo "ERROR: falta $(N8N_ENV)"; exit 1; }
	@docker compose \
		--env-file "$(N8N_ENV)" \
		-f "$(N8N_COMPOSE)" \
		config --quiet
	@echo "n8n Compose configuration is valid"

n8n-pull: n8n-config
	@docker compose \
		--env-file "$(N8N_ENV)" \
		-f "$(N8N_COMPOSE)" \
		pull

n8n-up: n8n-config
	@docker compose \
		--env-file "$(N8N_ENV)" \
		-f "$(N8N_COMPOSE)" \
		up -d
	@echo "Waiting for n8n..."
	@for attempt in $$(seq 1 45); do \
		status=$$(docker inspect --format='{{.State.Health.Status}}' "$(N8N_CONTAINER)" 2>/dev/null || true); \
		if [ "$$status" = "healthy" ]; then \
			echo "n8n is healthy"; \
			exit 0; \
		fi; \
		if [ "$$status" = "unhealthy" ]; then \
			echo "ERROR: n8n is unhealthy"; \
			docker logs --tail 150 "$(N8N_CONTAINER)"; \
			exit 1; \
		fi; \
		sleep 2; \
	done; \
	echo "ERROR: n8n health check timed out"; \
	docker logs --tail 150 "$(N8N_CONTAINER)"; \
	exit 1

n8n-down:
	@docker compose \
		--env-file "$(N8N_ENV)" \
		-f "$(N8N_COMPOSE)" \
		down

n8n-restart:
	@docker compose \
		--env-file "$(N8N_ENV)" \
		-f "$(N8N_COMPOSE)" \
		restart

n8n-logs:
	@docker compose \
		--env-file "$(N8N_ENV)" \
		-f "$(N8N_COMPOSE)" \
		logs --follow --tail 200

n8n-ps:
	@docker compose \
		--env-file "$(N8N_ENV)" \
		-f "$(N8N_COMPOSE)" \
		ps

n8n-status:
	@docker inspect \
		--format='Container: {{.Name}}{{printf "\n"}}Status: {{.State.Status}}{{printf "\n"}}Health: {{if .State.Health}}{{.State.Health.Status}}{{else}}not configured{{end}}{{printf "\n"}}Started: {{.State.StartedAt}}' \
		"$(N8N_CONTAINER)"

n8n-health:
	@docker inspect \
		--format='{{if .State.Health}}{{.State.Health.Status}}{{else}}not configured{{end}}' \
		"$(N8N_CONTAINER)"

n8n-shell:
	@docker exec -it "$(N8N_CONTAINER)" sh

## ===== TENANTS =====

tenant-validate:
	@test -d "$(TENANT_DIR)" || { \
		echo "ERROR: tenant no encontrado: $(TENANT)"; \
		exit 1; \
	}
	@test -f "$(TENANT_CONFIG)" || { \
		echo "ERROR: falta $(TENANT_CONFIG)"; \
		echo "Crea el fichero desde $(TENANT_CONFIG_EXAMPLE)"; \
		exit 1; \
	}
	@set -a; \
	. "$(TENANT_CONFIG)"; \
	set +a; \
	test -n "$$TENANT_ID" || { echo "ERROR: falta TENANT_ID"; exit 1; }; \
	test -n "$$ENVIRONMENT" || { echo "ERROR: falta ENVIRONMENT"; exit 1; }; \
	test -n "$$DIRECTUS_HOST" || { echo "ERROR: falta DIRECTUS_HOST"; exit 1; }; \
	test -n "$$N8N_HOST" || { echo "ERROR: falta N8N_HOST"; exit 1; }; \
	test -n "$$BACKUP_BUCKET" || { echo "ERROR: falta BACKUP_BUCKET"; exit 1; }; \
	echo "Tenant $(TENANT) válido"

tenant-show: tenant-validate
	@set -a; \
	. "$(TENANT_CONFIG)"; \
	set +a; \
	printf "Tenant:      %s\n" "$$TENANT_ID"; \
	printf "Nombre:      %s\n" "$$TENANT_NAME"; \
	printf "Entorno:     %s\n" "$$ENVIRONMENT"; \
	printf "Directus:    https://%s\n" "$$DIRECTUS_HOST"; \
	printf "n8n:         https://%s\n" "$$N8N_HOST"; \
	printf "Booking:     https://%s\n" "$$BOOKING_HOST"; \
	printf "Backup:      %s\n" "$$BACKUP_BUCKET"

## ===== BACKUPS =====

backup:
	@sudo TENANT="$(TENANT)" \
		/opt/aegora/platform/scripts/backup/backup-tenant.sh

backup-check:
	@sudo TENANT="$(TENANT)" \
		/opt/aegora/platform/scripts/backup/check-tenant.sh

backup-prune:
	@sudo TENANT="$(TENANT)" \
		/opt/aegora/platform/scripts/backup/prune-tenant.sh

backup-snapshots:
	@sudo bash -c '\
		set -a; \
		. /opt/aegora/platform/customers/$(TENANT)/tenant.env; \
		. /opt/aegora/secrets/restic.env; \
		set +a; \
		restic snapshots \
			--host "$$BACKUP_HOST" \
			--tag "$$BACKUP_TAG_TENANT" \
	'
