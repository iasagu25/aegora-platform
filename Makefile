SHELL := /usr/bin/env bash

POSTGRES_DIR := compose/postgres
POSTGRES_COMPOSE := $(POSTGRES_DIR)/compose.yml
POSTGRES_ENV := $(POSTGRES_DIR)/.env
POSTGRES_SERVICE := postgres
POSTGRES_CONTAINER := aegora-postgres

DIRECTUS_DIR := compose/directus
DIRECTUS_COMPOSE := $(DIRECTUS_DIR)/compose.yml
DIRECTUS_ENV := $(DIRECTUS_DIR)/.env

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
	postgres-users

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
