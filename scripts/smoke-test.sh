#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

body="$(mktemp)"
trap 'rm -f "$body"' EXIT

curl_json() {
  local url=$1
  curl -fsS --max-time 10 "$url"
}

check_http() {
  local name=$1 url=$2
  local code
  # curl leaves the file untouched when it cannot connect, which would print the
  # previous check's response body under this failure.
  : >"$body"
  code=$(curl -k -sS --max-time 10 -o "$body" -w '%{http_code}' "$url" || true)
  if [[ "$code" != "200" ]]; then
    echo "FAIL $name: $url returned $code"
    sed -n '1,3p' "$body" 2>/dev/null || true
    return 1
  fi
  echo "OK   $name: $url"
}

read_env_var() {
  local file=$1 key=$2 default=${3:-} val=""
  if [[ -f "$file" ]]; then
    val=$(grep -E "^${key}=" "$file" | head -1 | cut -d= -f2- || true)
    val=${val%$'\r'}
    # Compose strips matching surrounding quotes, so the smoke test must too.
    if [[ ${#val} -ge 2 && ( $val == \"*\" || $val == \'*\' ) ]]; then
      val=${val:1:${#val}-2}
    fi
  fi
  printf '%s' "${val:-$default}"
}

# BIND_ADDR may pin the stack to one interface. 0.0.0.0 is still reachable on
# loopback; a specific address is not, so probe whatever was configured.
bind_addr=$(read_env_var .env BIND_ADDR 127.0.0.1)
if [[ -z "$bind_addr" || "$bind_addr" == "0.0.0.0" ]]; then
  host=127.0.0.1
else
  host=$bind_addr
fi

check_grafana() {
  local name=$1 port=$2 envfile=$3 passvar=$4 expected_ds=$5 expected_dash=$6
  local pass
  pass=$(read_env_var "$envfile" "$passvar" admin)

  check_http "$name health" "http://${host}:${port}/api/health"

  local ds_count dash_count
  ds_count=$(curl -fsS --max-time 10 -u "admin:${pass}" "http://${host}:${port}/api/datasources" \
    | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
  dash_count=$(curl -fsS --max-time 10 -u "admin:${pass}" "http://${host}:${port}/api/search?type=dash-db" \
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
  check_http "$name VictoriaMetrics" "http://${host}:${port}/health"
  if ! curl_json "http://${host}:${port}/api/v1/label/__name__/values" | grep -q "\"${expected}\""; then
    echo "FAIL $name metrics: missing ${expected}"
    return 1
  fi
  echo "OK   $name metrics include ${expected}"
}

# Every service in the stack is restart: unless-stopped, so anything not in the
# running state is a failure. `docker ps` lists only running containers, which
# would silently skip a service that crashed or never started.
check_container_health() {
  local failed=0 name state health
  while IFS='|' read -r name state health; do
    [[ -z "$name" ]] && continue
    health=${health:-none}
    if [[ "$state" == "running" && ( "$health" == "healthy" || "$health" == "none" ) ]]; then
      echo "OK   container $name state=$state health=$health"
    else
      echo "FAIL container $name state=$state health=$health"
      failed=1
    fi
  done < <(docker compose ps -a --format '{{.Name}}|{{.State}}|{{.Health}}' | sort)
  return "$failed"
}

check_container_health

check_grafana xib "$(read_env_var .env XIB_GRAFANA_PORT 3000)"     .env     XIB_GRAFANA_PASSWORD   5 1
check_grafana vib "$(read_env_var vib/.env GRAFANA_PORT 3001)"     vib/.env GRAFANA_ADMIN_PASSWORD 1 1
check_grafana tib "$(read_env_var tib/.env GRAFANA_PORT 3002)"     tib/.env GRAFANA_ADMIN_PASSWORD 1 1
check_grafana cib "$(read_env_var cib/.env GRAFANA_PORT 3003)"     cib/.env GRAFANA_ADMIN_PASSWORD 1 1
check_grafana iib "$(read_env_var iib/.env GRAFANA_PORT 3004)"     iib/.env GRAFANA_ADMIN_PASSWORD 1 1
check_grafana pib "$(read_env_var pib/.env GRAFANA_PORT 3005)"     pib/.env GRAFANA_ADMIN_PASSWORD 1 1

check_vm_metrics vib "$(read_env_var vib/.env VICTORIAMETRICS_PORT 8429)" vib_last_scan_timestamp
check_vm_metrics tib "$(read_env_var tib/.env VICTORIAMETRICS_PORT 8430)" tib_last_sync_timestamp
check_vm_metrics cib "$(read_env_var cib/.env VICTORIAMETRICS_PORT 8431)" cib_last_scan_timestamp
check_vm_metrics iib "$(read_env_var iib/.env VICTORIAMETRICS_PORT 8432)" iib_last_sync_timestamp
check_vm_metrics pib "$(read_env_var pib/.env VICTORIAMETRICS_PORT 8433)" pib_last_scan_timestamp

echo "XIB smoke test passed"
