.DEFAULT_GOAL := help
.DELETE_ON_ERROR:
.PHONY: help setup-env build up-dev up-prod down clean ps status logs \
	    test-db test-cache kill-db start-db kill-cache start-cache test demo

# Environment used by the commands that take ENV=dev|prod.
ENV ?= dev

dc = docker compose -f docker-compose.$(1).yml --env-file .env.$(1)

help: ## List the available targets
	@grep -hE '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

setup-env: .env.dev .env.prod ## Create .env.dev and .env.prod with random secrets (mode 600)
	@echo "environment files ready"

# Each .env file is created only when it does not exist. The template is an
# order-only prerequisite: PostgreSQL stores its password in the data volume on
# first start, so regenerating a secret would lock the web out.
.env.dev .env.prod: .env.%: | .env.%.example
	@( umask 077; \
	  while IFS= read -r line; do \
	    case "$$line" in *=CHANGE_ME) line="$${line%CHANGE_ME}$$(openssl rand -hex 24)";; esac; \
	    printf '%s\n' "$$line"; \
	  done < .env.$*.example > $@ )
	@echo "created $@"

build: .env.dev .env.prod ## Build the web image of both environments
	$(call dc,dev) build
	$(call dc,prod) build

up-dev: .env.dev ## Start the dev environment (web + db)
	$(call dc,dev) up -d --build --wait
	@echo "dev ready: http://127.0.0.1:$$(sed -n 's/^WEB_PORT=//p' .env.dev)"

up-prod: .env.prod ## Start the prod environment (web + db + cache)
	$(call dc,prod) up -d --build --wait
	@echo "prod ready: http://127.0.0.1:$$(sed -n 's/^WEB_PORT=//p' .env.prod)"

down: .env.dev .env.prod ## Stop both environments (containers and networks removed, data kept)
	$(call dc,dev) down
	$(call dc,prod) down

clean: .env.dev .env.prod ## Like down, and also delete the data volumes and built images
	$(call dc,dev) down -v --rmi local
	$(call dc,prod) down -v --rmi local

ps: .env.dev .env.prod ## Show the containers and their health
	@$(call dc,dev) ps
	@$(call dc,prod) ps

status: ## Show /status of every running environment
	@for env in dev prod; do \
	  port=$$(sed -n 's/^WEB_PORT=//p' .env.$$env 2>/dev/null); \
	  [ -n "$$port" ] || continue; \
	  printf '%s: ' "$$env"; \
	  curl -s -m 5 "http://127.0.0.1:$$port/status" || printf 'not running'; \
	  echo; \
	done

logs: .env.$(ENV) ## Follow the web logs (ENV=dev|prod)
	$(call dc,$(ENV)) logs -f web

test-db: .env.$(ENV) ## Check PostgreSQL and count the incidents (ENV=dev|prod)
	@$(call dc,$(ENV)) exec -T db sh -c 'pg_isready -h 127.0.0.1 -U "$$POSTGRES_USER" -d "$$POSTGRES_DB" && psql -U "$$POSTGRES_USER" -d "$$POSTGRES_DB" -tAc "SELECT count(*) FROM incidents"'

test-cache: .env.prod ## Check that Redis answers PONG (prod only)
	@$(call dc,prod) exec -T cache sh -c 'REDISCLI_AUTH="$$REDIS_PASSWORD" redis-cli -h 127.0.0.1 ping'

kill-db: .env.$(ENV) ## Stop PostgreSQL to watch the status change (ENV=dev|prod)
	$(call dc,$(ENV)) stop db

start-db: .env.$(ENV) ## Start PostgreSQL again (ENV=dev|prod)
	$(call dc,$(ENV)) start db

kill-cache: .env.prod ## Stop Redis to watch the status change (prod only)
	$(call dc,prod) stop cache

start-cache: .env.prod ## Start Redis again (prod only)
	$(call dc,prod) start cache

test: ## Run every verification from scratch (destroys this project data)
	@bash scripts/test.sh

demo: ## Run interactive guided demonstration for practice defense
	@bash scripts/demo.sh
