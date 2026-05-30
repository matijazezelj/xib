.PHONY: up down restart logs build clean setup setup-sso smoke update pull-submodules

up: setup
	docker compose up -d

down:
	docker compose down

restart:
	docker compose restart

build:
	docker compose build --no-cache

logs:
	docker compose logs -f

setup:
	@if [ ! -f .env ]; then \
		echo "Creating .env from .env.example..."; \
		cp .env.example .env; \
	fi
	@echo "Initialising sub-project environments..."
	@for dir in vib tib cib iib pib; do \
		if [ ! -f $$dir/.env ] && [ -f $$dir/.env.example ]; then \
			echo "  $$dir: creating .env from .env.example"; \
			cp $$dir/.env.example $$dir/.env; \
		fi; \
	done
	@if [ -f iib/Makefile ]; then $(MAKE) -C iib generate-secrets; fi
	@if [ -f pib/Makefile ]; then $(MAKE) -C pib ca-password; fi

# Wire up Grafana SSO and PIB OIDC provisioner via Authentik.
# Run this once after 'make up' and Authentik has fully initialised.
setup-sso:
	@bash scripts/setup-sso.sh

smoke: ## Run local runtime smoke checks against the XIB stack
	@bash scripts/smoke-test.sh

# Pull latest commits on all submodules
update:
	git submodule update --remote --merge
	@echo "Submodules updated. Run 'make up' to redeploy."

# Clone submodules if this repo was checked out without --recurse-submodules
pull-submodules:
	git submodule update --init --recursive

clean:
	docker compose down -v
	docker rmi xib-grafana 2>/dev/null || true
