REPO_ROOT := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ENV_FILE  := $(REPO_ROOT).env

define compose
docker compose --project-name $(1) --env-file $(ENV_FILE) -f $(REPO_ROOT)$(1)/docker-compose.yml
endef

STACKS := infra homepage media devops ai compute monitoring

.PHONY: up down restart update network ps logs check reload-caddy

network:
	docker network inspect cloud-net >/dev/null 2>&1 || docker network create cloud-net

# devops must precede ai: open-webui's DATABASE_URL points at postgres (devops stack)
up: network
	$(call compose,infra)      up -d
	$(call compose,homepage)   up -d
	$(call compose,media)      up -d
	$(call compose,devops)     up -d
	$(call compose,ai)         up -d
	$(call compose,compute)    up -d
	$(call compose,monitoring) up -d

down:
	$(call compose,monitoring) down
	$(call compose,compute)    down
	$(call compose,ai)         down
	$(call compose,devops)     down
	$(call compose,media)      down
	$(call compose,homepage)   down
	$(call compose,infra)      down

restart: down up

# Records a pre-update image manifest (rollback reference) and prunes old layers
update:
	@mkdir -p $(REPO_ROOT).image-manifests
	docker images --digests --format "{{.Repository}}:{{.Tag}} {{.Digest}}" | sort > $(REPO_ROOT).image-manifests/pre-update-$$(date +%Y%m%d-%H%M%S).txt
	$(call compose,infra)      pull && $(call compose,infra)      up -d
	$(call compose,homepage)   pull && $(call compose,homepage)   up -d
	$(call compose,media)      pull && $(call compose,media)      up -d
	$(call compose,devops)     pull && $(call compose,devops)     up -d
	$(call compose,ai)         pull && $(call compose,ai)         up -d
	$(call compose,compute)    pull && $(call compose,compute)    up -d
	$(call compose,monitoring) pull && $(call compose,monitoring) up -d
	docker image prune -f

ps:
	docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"

# Follow logs for one stack: make logs s=ai
logs:
	@test -n "$(s)" || { echo "usage: make logs s=<stack>  (stacks: $(STACKS))"; exit 1; }
	$(call compose,$(s)) logs -f --tail=50

# Validate all compose files and the Caddyfile without touching running services
check:
	@for s in $(STACKS); do \
	  docker compose --project-name $$s --env-file $(ENV_FILE) \
	    -f $(REPO_ROOT)$$s/docker-compose.yml config -q \
	    && echo "$$s: OK" || exit 1; \
	done
	@docker exec caddy caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 \
	  && echo "Caddyfile: OK" || { echo "Caddyfile: INVALID"; exit 1; }

# Apply Caddyfile edits to the running container (it's mounted read-only)
reload-caddy:
	docker exec -w /etc/caddy caddy caddy reload --config /etc/caddy/Caddyfile
