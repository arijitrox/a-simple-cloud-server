REPO_ROOT := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ENV_FILE  := $(REPO_ROOT).env

define compose
docker compose --project-name $(1) --env-file $(ENV_FILE) -f $(REPO_ROOT)$(1)/docker-compose.yml
endef

.PHONY: up down restart update network ps

network:
	docker network inspect cloud-net >/dev/null 2>&1 || docker network create cloud-net

up: network
	$(call compose,infra)      up -d
	$(call compose,media)      up -d
	$(call compose,ai)         up -d
	$(call compose,devops)     up -d
	$(call compose,compute)    up -d
	$(call compose,monitoring) up -d

down:
	$(call compose,monitoring) down
	$(call compose,compute)    down
	$(call compose,devops)     down
	$(call compose,ai)         down
	$(call compose,media)      down
	$(call compose,infra)      down

restart: down up

update:
	$(call compose,infra)      pull && $(call compose,infra)      up -d
	$(call compose,media)      pull && $(call compose,media)      up -d
	$(call compose,ai)         pull && $(call compose,ai)         up -d
	$(call compose,devops)     pull && $(call compose,devops)     up -d
	$(call compose,compute)    pull && $(call compose,compute)    up -d
	$(call compose,monitoring) pull && $(call compose,monitoring) up -d

ps:
	docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"

logs:
	docker compose logs -f --tail=50
