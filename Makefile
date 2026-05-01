REPO_ROOT := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
COMPOSE   := docker compose --project-directory $(REPO_ROOT)

STACKS := infra media ai devops compute monitoring

.PHONY: up down restart update network logs ps

network:
	docker network inspect cloud-net >/dev/null 2>&1 || docker network create cloud-net

up: network
	$(COMPOSE) -f infra/docker-compose.yml      up -d --remove-orphans
	$(COMPOSE) -f media/docker-compose.yml      up -d --remove-orphans
	$(COMPOSE) -f ai/docker-compose.yml         up -d --remove-orphans
	$(COMPOSE) -f devops/docker-compose.yml     up -d --remove-orphans
	$(COMPOSE) -f compute/docker-compose.yml    up -d --remove-orphans
	$(COMPOSE) -f monitoring/docker-compose.yml up -d --remove-orphans

down:
	$(COMPOSE) -f monitoring/docker-compose.yml down
	$(COMPOSE) -f compute/docker-compose.yml    down
	$(COMPOSE) -f devops/docker-compose.yml     down
	$(COMPOSE) -f ai/docker-compose.yml         down
	$(COMPOSE) -f media/docker-compose.yml      down
	$(COMPOSE) -f infra/docker-compose.yml      down

restart: down up

update:
	$(COMPOSE) -f infra/docker-compose.yml      pull && $(COMPOSE) -f infra/docker-compose.yml      up -d
	$(COMPOSE) -f media/docker-compose.yml      pull && $(COMPOSE) -f media/docker-compose.yml      up -d
	$(COMPOSE) -f ai/docker-compose.yml         pull && $(COMPOSE) -f ai/docker-compose.yml         up -d
	$(COMPOSE) -f devops/docker-compose.yml     pull && $(COMPOSE) -f devops/docker-compose.yml     up -d
	$(COMPOSE) -f compute/docker-compose.yml    pull && $(COMPOSE) -f compute/docker-compose.yml    up -d
	$(COMPOSE) -f monitoring/docker-compose.yml pull && $(COMPOSE) -f monitoring/docker-compose.yml up -d

ps:
	docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"

logs:
	docker compose logs -f --tail=50
