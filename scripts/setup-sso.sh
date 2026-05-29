#!/usr/bin/env bash
# setup-sso.sh — Provision Authentik OAuth2 apps for Grafana SSO and PIB OIDC
# Run from the XIB root directory: make setup-sso
set -euo pipefail

XIB_DIR="$(cd "$(dirname "$0")/.." && pwd)"
IIB_ENV="$XIB_DIR/iib/.env"
XIB_ENV="$XIB_DIR/.env"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[xib]${NC} $*"; }
warn()  { echo -e "${YELLOW}[xib]${NC} $*"; }
die()   { echo -e "${RED}[xib]${NC} ERROR: $*" >&2; exit 1; }

# ── Load config ──────────────────────────────────────────────────────────────

get_env() { grep "^${1}=" "$2" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'"; }
set_env() {
  local key="$1" val="$2" file="$3"
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$file"
  else
    echo "${key}=${val}" >> "$file"
  fi
}

[ -f "$IIB_ENV" ] || die "iib/.env not found — run 'make setup' first"
[ -f "$XIB_ENV" ] || die ".env not found — run 'make setup' first"

BOOTSTRAP_TOKEN="$(get_env AUTHENTIK_BOOTSTRAP_TOKEN "$IIB_ENV")"
[ -n "$BOOTSTRAP_TOKEN" ] || die "AUTHENTIK_BOOTSTRAP_TOKEN is empty in iib/.env — run 'make setup' first"

AUTHENTIK_EXTERNAL_URL="${AUTHENTIK_EXTERNAL_URL:-$(get_env AUTHENTIK_EXTERNAL_URL "$XIB_ENV")}"
AUTHENTIK_EXTERNAL_URL="${AUTHENTIK_EXTERNAL_URL:-http://localhost:9080}"
AUTHENTIK_API="${AUTHENTIK_EXTERNAL_URL}/api/v3"

XIB_HOST="${XIB_HOST:-$(get_env XIB_HOST "$XIB_ENV")}"
XIB_HOST="${XIB_HOST:-localhost}"

GRAFANA_PORTS="${GRAFANA_PORTS:-3000 3001 3002 3003 3004 3005}"

AUTH_HDR="Authorization: Bearer ${BOOTSTRAP_TOKEN}"

# ── Wait for Authentik ───────────────────────────────────────────────────────

info "Waiting for Authentik at ${AUTHENTIK_EXTERNAL_URL}..."
for i in $(seq 1 60); do
  if curl -sf "${AUTHENTIK_API}/core/applications/" -H "$AUTH_HDR" -o /dev/null 2>/dev/null; then
    info "Authentik is ready."
    break
  fi
  if [ "$i" -eq 60 ]; then
    die "Authentik did not become ready after 5 minutes. Is 'make up' running?"
  fi
  echo -n "."
  sleep 5
done

# ── Helpers ──────────────────────────────────────────────────────────────────

api_get()  { curl -sf "${AUTHENTIK_API}/${1}" -H "$AUTH_HDR"; }
api_post() { curl -sf -X POST "${AUTHENTIK_API}/${1}" -H "$AUTH_HDR" -H "Content-Type: application/json" -d "$2"; }

json_get() { python3 -c "import json,sys; d=json.load(sys.stdin); print(${1})" <<< "$2"; }

# ── Fetch prerequisites ───────────────────────────────────────────────────────

info "Fetching Authentik flows and keys..."

AUTH_FLOWS="$(api_get "flows/instances/?designation=authorization&ordering=name")"
AUTH_FLOW_PK="$(json_get "d['results'][0]['pk']" "$AUTH_FLOWS")" \
  || die "No authorization flows found in Authentik"

INVAL_FLOWS="$(api_get "flows/instances/?designation=invalidation&ordering=name")"
INVAL_FLOW_PK="$(python3 -c "
import json,sys
d=json.loads('''${INVAL_FLOWS}''')
results = d.get('results', [])
print(results[0]['pk'] if results else '')
" 2>/dev/null || echo "")"

SIGN_KEYS="$(api_get "crypto/certificatekeypairs/?has_key=true&ordering=name")"
SIGN_KEY_PK="$(python3 -c "
import json,sys
d=json.loads('''${SIGN_KEYS}''')
results = d.get('results', [])
print(results[0]['pk'] if results else 'null')
" 2>/dev/null || echo "null")"

info "  Authorization flow: ${AUTH_FLOW_PK}"
info "  Signing key: ${SIGN_KEY_PK}"

# ── Build Grafana redirect URI list ──────────────────────────────────────────

REDIRECT_URIS_JSON="$(python3 -c "
import json
ports = '${GRAFANA_PORTS}'.split()
host = '${XIB_HOST}'
uris = [{'url': f'http://{host}:{p}/login/generic_oauth', 'matching_mode': 'strict'} for p in ports]
# Also allow HTTPS variant
uris += [{'url': f'https://{host}:{p}/login/generic_oauth', 'matching_mode': 'strict'} for p in ports]
print(json.dumps(uris))
")"

# ── Create or update Grafana OAuth2 provider ─────────────────────────────────

info "Provisioning Grafana OAuth2 provider in Authentik..."

GRAFANA_PROVIDER_BODY="$(python3 -c "
import json
body = {
    'name': 'XIB Grafana SSO',
    'authorization_flow': '${AUTH_FLOW_PK}',
    'client_type': 'confidential',
    'redirect_uris': json.loads('${REDIRECT_URIS_JSON}'),
    'sub_mode': 'hashed_user_id',
    'include_claims_in_id_token': True,
    'issuer_mode': 'global',
    'access_token_validity': 'hours=1',
}
if '${INVAL_FLOW_PK}':
    body['invalidation_flow'] = '${INVAL_FLOW_PK}'
if '${SIGN_KEY_PK}' != 'null':
    body['signing_key'] = '${SIGN_KEY_PK}'
print(json.dumps(body))
")"

# Check if provider already exists
EXISTING_PROVIDER="$(api_get "providers/oauth2/?name=XIB+Grafana+SSO" || echo "{}")"
EXISTING_PK="$(python3 -c "
import json,sys
d=json.loads('''${EXISTING_PROVIDER}''')
results = d.get('results', [])
print(results[0]['pk'] if results else '')
" 2>/dev/null || echo "")"

if [ -n "$EXISTING_PK" ]; then
  warn "  Grafana provider already exists (pk=${EXISTING_PK}), skipping creation."
  GRAFANA_PROVIDER="$(api_get "providers/oauth2/${EXISTING_PK}/")"
else
  GRAFANA_PROVIDER="$(api_post "providers/oauth2/" "$GRAFANA_PROVIDER_BODY")"
  EXISTING_PK="$(json_get "d['pk']" "$GRAFANA_PROVIDER")"
  info "  Created provider pk=${EXISTING_PK}"
fi

GRAFANA_CLIENT_ID="$(json_get "d['client_id']" "$GRAFANA_PROVIDER")"
GRAFANA_CLIENT_SECRET="$(json_get "d['client_secret']" "$GRAFANA_PROVIDER")"

# Create Grafana application
EXISTING_APP="$(api_get "core/applications/?slug=grafana" || echo "{}")"
APP_EXISTS="$(python3 -c "
import json,sys
d=json.loads('''${EXISTING_APP}''')
print('yes' if d.get('results') else '')
" 2>/dev/null || echo "")"

if [ -z "$APP_EXISTS" ]; then
  info "  Creating Grafana application..."
  api_post "core/applications/" "$(python3 -c "
import json
print(json.dumps({
    'name': 'Grafana',
    'slug': 'grafana',
    'provider': ${EXISTING_PK},
    'meta_launch_url': 'http://${XIB_HOST}:3000',
    'policy_engine_mode': 'any',
    'group': '',
    'open_in_new_tab': False,
}))
")" > /dev/null
  info "  Application 'grafana' created."
else
  warn "  Application 'grafana' already exists, skipping."
fi

# ── Create step-ca OIDC provider ─────────────────────────────────────────────

info "Provisioning step-ca OIDC provider in Authentik..."

PIB_CA_PORT="${PIB_CA_PORT:-9000}"

STEPCA_PROVIDER_BODY="$(python3 -c "
import json
body = {
    'name': 'PIB step-ca OIDC',
    'authorization_flow': '${AUTH_FLOW_PK}',
    'client_type': 'confidential',
    'redirect_uris': [
        {'url': 'http://${XIB_HOST}:${PIB_CA_PORT}/callback', 'matching_mode': 'strict'},
        {'url': 'http://pib-ca:9000/callback', 'matching_mode': 'strict'},
        {'url': 'urn:ietf:wg:oauth:2.0:oob', 'matching_mode': 'strict'},
    ],
    'sub_mode': 'user_email',
    'include_claims_in_id_token': True,
    'issuer_mode': 'global',
}
if '${INVAL_FLOW_PK}':
    body['invalidation_flow'] = '${INVAL_FLOW_PK}'
if '${SIGN_KEY_PK}' != 'null':
    body['signing_key'] = '${SIGN_KEY_PK}'
print(json.dumps(body))
")"

EXISTING_STEPCA_PROVIDER="$(api_get "providers/oauth2/?name=PIB+step-ca+OIDC" || echo "{}")"
EXISTING_STEPCA_PK="$(python3 -c "
import json,sys
d=json.loads('''${EXISTING_STEPCA_PROVIDER}''')
results = d.get('results', [])
print(results[0]['pk'] if results else '')
" 2>/dev/null || echo "")"

if [ -n "$EXISTING_STEPCA_PK" ]; then
  warn "  step-ca provider already exists (pk=${EXISTING_STEPCA_PK}), skipping creation."
  STEPCA_PROVIDER="$(api_get "providers/oauth2/${EXISTING_STEPCA_PK}/")"
else
  STEPCA_PROVIDER="$(api_post "providers/oauth2/" "$STEPCA_PROVIDER_BODY")"
  EXISTING_STEPCA_PK="$(json_get "d['pk']" "$STEPCA_PROVIDER")"
  info "  Created provider pk=${EXISTING_STEPCA_PK}"
fi

STEPCA_CLIENT_ID="$(json_get "d['client_id']" "$STEPCA_PROVIDER")"
STEPCA_CLIENT_SECRET="$(json_get "d['client_secret']" "$STEPCA_PROVIDER")"

# Create step-ca application
EXISTING_STEPCA_APP="$(api_get "core/applications/?slug=step-ca" || echo "{}")"
STEPCA_APP_EXISTS="$(python3 -c "
import json,sys
d=json.loads('''${EXISTING_STEPCA_APP}''')
print('yes' if d.get('results') else '')
" 2>/dev/null || echo "")"

if [ -z "$STEPCA_APP_EXISTS" ]; then
  info "  Creating step-ca application..."
  api_post "core/applications/" "$(python3 -c "
import json
print(json.dumps({
    'name': 'PIB step-ca',
    'slug': 'step-ca',
    'provider': ${EXISTING_STEPCA_PK},
    'policy_engine_mode': 'any',
    'group': '',
    'open_in_new_tab': False,
}))
")" > /dev/null
  info "  Application 'step-ca' created."
else
  warn "  Application 'step-ca' already exists, skipping."
fi

# ── Write credentials to XIB .env ────────────────────────────────────────────

info "Writing credentials to .env..."

set_env "AUTHENTIK_GRAFANA_CLIENT_ID"     "$GRAFANA_CLIENT_ID"     "$XIB_ENV"
set_env "AUTHENTIK_GRAFANA_CLIENT_SECRET" "$GRAFANA_CLIENT_SECRET" "$XIB_ENV"
set_env "AUTHENTIK_STEPCA_CLIENT_ID"      "$STEPCA_CLIENT_ID"      "$XIB_ENV"
set_env "AUTHENTIK_STEPCA_CLIENT_SECRET"  "$STEPCA_CLIENT_SECRET"  "$XIB_ENV"
set_env "GRAFANA_SSO_ENABLED"             "true"                   "$XIB_ENV"

# ── Configure step-ca OIDC provisioner ───────────────────────────────────────

info "Configuring step-ca OIDC provisioner (offline mode)..."

OIDC_DISCOVERY="http://iib-server:9000/application/o/step-ca/.well-known/openid-configuration"

if docker exec pib-ca step ca provisioner list 2>/dev/null | grep -q "authentik"; then
  warn "  OIDC provisioner 'authentik' already exists in step-ca, skipping."
else
  docker exec pib-ca step ca provisioner add authentik \
    --type=OIDC \
    --client-id="$STEPCA_CLIENT_ID" \
    --client-secret="$STEPCA_CLIENT_SECRET" \
    --configuration-endpoint="$OIDC_DISCOVERY" \
    --offline \
    --ca-config /home/step/config/ca.json \
    && info "  OIDC provisioner added to step-ca." \
    || warn "  Could not add OIDC provisioner automatically. See manual steps below."
fi

# ── Restart services to pick up new config ───────────────────────────────────

info "Restarting Grafana instances and step-ca..."
docker restart vib-grafana tib-grafana cib-grafana iib-grafana pib-grafana xib-grafana pib-ca 2>/dev/null || true

# ── Done ─────────────────────────────────────────────────────────────────────

echo ""
info "SSO setup complete."
echo ""
echo "  Grafana client ID:  $GRAFANA_CLIENT_ID"
echo "  step-ca client ID:  $STEPCA_CLIENT_ID"
echo ""
echo "All Grafana instances now use Authentik for login."
echo "Log in to any Grafana at its port — click 'Sign in with Authentik'."
echo ""
echo "To issue a certificate via Authentik OIDC:"
echo "  step ca certificate <subject> cert.pem key.pem \\"
echo "    --provisioner=authentik \\"
echo "    --ca-url=http://localhost:${PIB_CA_PORT}"
echo ""
echo "NOTE: Update the 'grafana' application's redirect URIs in Authentik"
echo "      if your Grafana instances are on a custom hostname/port."
echo "      Authentik admin: ${AUTHENTIK_EXTERNAL_URL}"
