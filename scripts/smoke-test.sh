#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

curl_json() {
  local url=$1
  curl -fsS --max-time 10 "$url"
}

check_http() {
  local name=$1 url=$2
  local code
  code=$(curl -k -sS --max-time 10 -o /tmp/xib-smoke-body -w '%{http_code}' "$url" || true)
  if [[ "$code" != "200" ]]; then
    echo "FAIL $name: $url returned $code"
    sed -n '1,3p' /tmp/xib-smoke-body 2>/dev/null || true
    return 1
  fi
  echo "OK   $name: $url"
}

read_env_var() {
  local file=$1 key=$2 default=${3:-}
  if [[ -f "$file" ]] && grep -qE "^${key}=" "$file"; then
    grep -E "^${key}=" "$file" | head -1 | cut -d= -f2-
  else
    printf '%s' "$default"
  fi
}

check_grafana() {
  local name=$1 port=$2 envfile=$3 passvar=$4 expected_ds=$5 expected_dash=$6
  local pass
  pass=$(read_env_var "$envfile" "$passvar" admin)

  check_http "$name health" "http://127.0.0.1:${port}/api/health"

  local ds_count dash_count
  ds_count=$(curl -fsS --max-time 10 -u "admin:${pass}" "http://127.0.0.1:${port}/api/datasources" \
    | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
  dash_count=$(curl -fsS --max-time 10 -u "admin:${pass}" "http://127.0.0.1:${port}/api/search?type=dash-db" \
    | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')

  if (( ds_count < expected_ds )); then
    echo "FAIL $name datasources: got $ds_count, expected >= $expected_ds"
    return 1
  fi
  if (( dash_count < expected_dash )); then
    echo "FAIL $name dashboards: got $dash_count, expected >= $expected_dash"
    return 1
  fi
  echo "OK   $name provisioning: datasources=$ds_count dashboards=$dash_count"
}

check_vm_metrics() {
  local name=$1 port=$2 expected=$3
  check_http "$name VictoriaMetrics" "http://127.0.0.1:${port}/health"
  if ! curl_json "http://127.0.0.1:${port}/api/v1/label/__name__/values" | grep -q "${expected}"; then
    echo "FAIL $name metrics: missing ${expected}"
    return 1
  fi
  echo "OK   $name metrics include ${expected}"
}

check_container_health() {
  local failed=0
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    local health
    health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$name")
    case "$health" in
      healthy|none) echo "OK   container $name health=$health" ;;
      *) echo "FAIL container $name health=$health"; failed=1 ;;
    esac
  done < <(docker ps --filter 'name=^(xib|vib|tib|cib|iib|pib)-' --format '{{.Names}}' | sort)
  return "$failed"
}

check_container_health

check_grafana xib 3000 .env XIB_GRAFANA_PASSWORD 5 1
check_grafana vib 3001 vib/.env GRAFANA_ADMIN_PASSWORD 1 1
check_grafana tib 3002 tib/.env GRAFANA_ADMIN_PASSWORD 1 1
check_grafana cib 3003 cib/.env GRAFANA_ADMIN_PASSWORD 1 1
check_grafana iib 3004 iib/.env GRAFANA_ADMIN_PASSWORD 1 1
check_grafana pib 3005 pib/.env GRAFANA_ADMIN_PASSWORD 1 1

check_vm_metrics vib 8429 vib_last_scan_timestamp
check_vm_metrics tib 8430 tib_last_sync_timestamp
check_vm_metrics cib 8431 cib_last_scan_timestamp
check_vm_metrics iib 8432 iib_last_sync_timestamp
check_vm_metrics pib 8433 pib_last_scan_timestamp

echo "XIB smoke test passed"
