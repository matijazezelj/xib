#!/usr/bin/env bash
# init-env.sh — Create XIB and sub-project .env files, generating admin passwords.
# Run from the XIB root directory: make setup
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[xib]${NC} $*"; }
warn() { echo -e "${YELLOW}[xib]${NC} $*"; }

# Hex keeps the value free of characters that are special to sed's replacement.
gen_secret() { openssl rand -hex 24; }

# Replace a placeholder password in place. BSD and GNU sed disagree on `sed -i`,
# so write to a temp file and move it over instead.
fill_placeholder() {
  local file=$1 key=$2 tmp
  grep -qE "^${key}=(CHANGE_ME|GENERATE_ME)$" "$file" || return 0
  tmp=$(mktemp)
  sed -E "s#^${key}=(CHANGE_ME|GENERATE_ME)\$#${key}=$(gen_secret)#" "$file" >"$tmp"
  mv "$tmp" "$file"
  generated=1
}

generated=0

if [ ! -f .env ]; then
  info "Creating .env from .env.example..."
  cp .env.example .env
  fill_placeholder .env XIB_GRAFANA_PASSWORD
fi

info "Initialising sub-project environments..."
for dir in vib tib cib iib pib; do
  if [ ! -f "$dir/.env" ] && [ -f "$dir/.env.example" ]; then
    info "  $dir: creating .env from .env.example"
    cp "$dir/.env.example" "$dir/.env"
    fill_placeholder "$dir/.env" GRAFANA_ADMIN_PASSWORD
  fi
done

if [ "$generated" -eq 1 ]; then
  warn "Generated random Grafana admin passwords. Read them with:"
  warn "  grep -H 'GRAFANA.*PASSWORD=' .env vib/.env tib/.env cib/.env iib/.env pib/.env"
fi
