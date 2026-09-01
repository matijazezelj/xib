.PHONY: up down restart logs build clean setup setup-sso smoke update pull-submodules

# --build so a `make update` that moves a submodule actually redeploys its
# code. Without it Compose reuses the existing image and the stack silently
# keeps running the previous commit. Costs ~2s when nothing changed.
up: setup
	docker compose up -d --build

down:
	docker compose down

restart:
	docker compose restart

build:
	docker compose build --no-cache

logs:
	docker compose logs -f

setup:
	@bash scripts/init-env.sh
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
