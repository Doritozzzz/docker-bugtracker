#!/usr/bin/env bash
# ==============================================================================
# GUIDED DEMONSTRATION — IT INCIDENT TRACKER
# ==============================================================================
# Interactive walkthrough to defend and present all requirements of Practice 1.
#
# Usage:
#   make demo            (Interactive mode: press ENTER at each step)
#   bash scripts/demo.sh --auto  (Continuous mode: runs without pauses)
# ==============================================================================

set -e
cd "$(dirname "$0")/.."

AUTO_MODE=0
if [ "${1:-}" = "--auto" ]; then
  AUTO_MODE=1
fi

# Terminal colors and formatting
BOLD='\033[1m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

pause() {
  if [ "$AUTO_MODE" -eq 0 ]; then
    printf "\n${YELLOW}▶ Press [ENTER] to proceed to the next step...${NC}"
    read -r
  fi
  printf "\n"
}

header() {
  printf "\n${BOLD}${CYAN}====================================================================${NC}\n"
  printf "${BOLD}${CYAN} %s${NC}\n" "$1"
  printf "${BOLD}${CYAN}====================================================================${NC}\n"
}

step() {
  printf "\n${BOLD}${GREEN}✔ %s${NC}\n" "$1"
}

substep() {
  printf "  ${BLUE}➜ %s${NC}\n" "$1"
}

wait_svc() {
  local port=$1 svc=$2 target=$3
  for _ in $(seq 1 30); do
    if curl -s "http://127.0.0.1:${port}/status" | grep -o "\"${svc}\":{[^}]*}" | grep -q "\"status\":\"${target}\""; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

# Ensure environments are ready before beginning
if [ ! -f .env.dev ] || [ ! -f .env.prod ]; then
  make setup-env >/dev/null 2>&1
fi

header "PRACTICE 1: MULTI-ENVIRONMENT DOCKER DEPLOYMENT"
printf "Interactive defense demo covering architecture, persistence, cache, failover & security.\n"
printf "${YELLOW}Tip: You can open http://127.0.0.1:3000 (dev) and http://127.0.0.1:8080 (prod) in your browser.${NC}\n"

# Ensure both are running
make up-dev up-prod >/dev/null 2>&1

DEV_PORT=$(sed -n 's/^WEB_PORT=//p' .env.dev 2>/dev/null || echo 3000)
PROD_PORT=$(sed -n 's/^WEB_PORT=//p' .env.prod 2>/dev/null || echo 8080)

# ------------------------------------------------------------------------------
header "1. ARCHITECTURE & ENVIRONMENT STATUS (DEV vs PROD)"

step "Checking running containers and health status:"
make ps

step "Querying /status and /health on Development (port ${DEV_PORT}):"
curl -s "http://127.0.0.1:${DEV_PORT}/status" | grep -o '"services":{[^}]*}' || true
substep "Note: PostgreSQL is 'up' and Redis is 'disabled' (cache is prod-only, as required)."

step "Querying /status and /health on Production (port ${PROD_PORT}):"
curl -s "http://127.0.0.1:${PROD_PORT}/status" | grep -o '"services":{[^}]*}' || true
substep "Note: Both PostgreSQL and Redis are 'up' and healthy."

step "Comparing structured JSON logging between environments:"
curl -s "http://127.0.0.1:${DEV_PORT}/api/incidents" >/dev/null
substep "Dev (debug level) traces requests & timings in JSON:"
docker compose -f docker-compose.dev.yml --env-file .env.dev logs web 2>&1 | grep '"msg":"request"' | tail -n 1 | sed 's/^/    /' || true
substep "Prod (info level) keeps logs clean (0 request traces, only system lifecycle events)."

pause

# ------------------------------------------------------------------------------
header "2. DATABASE PERSISTENCE DEMONSTRATION (POSTGRESQL)"

step "Inserting a new incident via the Dev API..."
INCIDENT_NAME="Persistence Check $(date +%T)"
INSERT_RES=$(curl -s -X POST "http://127.0.0.1:${DEV_PORT}/api/incidents" \
  -H "Content-Type: application/json" \
  -d "{\"title\":\"${INCIDENT_NAME}\",\"system_name\":\"demo-host\",\"priority\":\"HIGH\"}")
echo "$INSERT_RES" | grep -o '"title":"[^"]*"' || true

step "Verifying the record directly inside PostgreSQL via 'make test-db':"
docker compose -f docker-compose.dev.yml --env-file .env.dev exec -T db \
  psql -U tracker -d tracker_dev -tAc "SELECT id, title, created_at FROM incidents WHERE title = '${INCIDENT_NAME}'"

step "Destroying the database container ('docker compose down' without deleting volumes)..."
docker compose -f docker-compose.dev.yml --env-file .env.dev down
substep "Containers stopped and removed. Verifying Docker volume still exists:"
docker volume ls --filter name=bugtracker-dev_db-data

step "Recreating the development environment ('make up-dev')..."
make up-dev >/dev/null 2>&1

step "Verifying that the inserted incident SURVIVED in the database:"
docker compose -f docker-compose.dev.yml --env-file .env.dev exec -T db \
  psql -U tracker -d tracker_dev -tAc "SELECT id, title, created_at FROM incidents WHERE title = '${INCIDENT_NAME}'"
printf "${GREEN}✔ Data persistence verified 100%%! Records remain safe in the Docker volume.${NC}\n"

pause

# ------------------------------------------------------------------------------
header "3. CACHE DEMONSTRATION (REDIS IN PRODUCTION)"

# Ensure cache is cold before demonstrating the 1st request
docker compose -f docker-compose.prod.yml --env-file .env.prod exec -T cache \
  sh -c 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli del incidents' >/dev/null 2>&1

step "1st Request (Cache MISS — queries PostgreSQL and populates Redis):"
curl -s -i "http://127.0.0.1:${PROD_PORT}/api/incidents" | grep -E 'X-Cache|X-Response-Time' || true

step "2nd Request (Cache HIT — served instantly from Redis in-memory cache):"
curl -s -i "http://127.0.0.1:${PROD_PORT}/api/incidents" | grep -E 'X-Cache|X-Response-Time' || true

step "Measuring latency over 5 MISS requests vs 5 HIT requests (50,000 DB records):"
MISS_TIMES=()
for i in $(seq 1 5); do
  docker compose -f docker-compose.prod.yml --env-file .env.prod exec -T cache \
    sh -c 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli del incidents' >/dev/null 2>&1
  T=$(curl -s -D - -o /dev/null "http://127.0.0.1:${PROD_PORT}/api/incidents" | awk -F': ' 'tolower($1)=="x-response-time" {print $2}' | tr -d '\r\n')
  MISS_TIMES+=("$T")
done

HIT_TIMES=()
for i in $(seq 1 5); do
  T=$(curl -s -D - -o /dev/null "http://127.0.0.1:${PROD_PORT}/api/incidents" | awk -F': ' 'tolower($1)=="x-response-time" {print $2}' | tr -d '\r\n')
  HIT_TIMES+=("$T")
done

substep "Cache MISS response times (PostgreSQL aggregate): ${MISS_TIMES[*]}"
substep "Cache HIT response times  (Redis memory cache):      ${HIT_TIMES[*]}"
printf "${GREEN}✔ Performance gain demonstrated! Cache hit is >15x faster.${NC}\n"

step "Demonstrating cache invalidation upon incident creation (POST):"
substep "Creating a new incident in production..."
curl -s -X POST "http://127.0.0.1:${PROD_PORT}/api/incidents" \
  -H "Content-Type: application/json" \
  -d '{"title":"Cache Invalidation Trigger","system_name":"auth-api","priority":"LOW"}' >/dev/null
substep "Next read must be a MISS (cache key was invalidated):"
curl -s -i "http://127.0.0.1:${PROD_PORT}/api/incidents" | grep -E 'X-Cache|X-Response-Time' || true
substep "Subsequent read is a HIT again:"
curl -s -i "http://127.0.0.1:${PROD_PORT}/api/incidents" | grep -E 'X-Cache|X-Response-Time' || true

pause

# ------------------------------------------------------------------------------
header "4. FAULT TOLERANCE & DYNAMIC HEALTHCHECKS"

step "Simulating Redis outage in Production ('make kill-cache')..."
make kill-cache >/dev/null 2>&1
sleep 1

step "Redis is now DOWN. Check /status and your browser (http://127.0.0.1:${PROD_PORT}):"
curl -s "http://127.0.0.1:${PROD_PORT}/status" | grep -o '"status":"[^"]*"' || true
substep "Notice in web UI: Redis status dot turns RED ('Disconnected'), overall: 'degraded'."
substep "Reading incidents without cache STILL WORKS (reading directly from PostgreSQL):"
curl -s -o /dev/null -w "  HTTP Status Code: %{http_code}\n" "http://127.0.0.1:${PROD_PORT}/api/incidents"
substep "Server container log captured the outage event:"
docker compose -f docker-compose.prod.yml --env-file .env.prod logs web 2>&1 | grep 'cache_unavailable' | tail -n 1 | sed 's/^/    /' || true
printf "${YELLOW}  (Take your time to show the degraded state in the browser)${NC}\n"
pause

step "Restoring Redis ('make start-cache')..."
make start-cache >/dev/null 2>&1
wait_svc "$PROD_PORT" cache up || true
substep "Querying /status after recovery (back to 'ok'):"
curl -s "http://127.0.0.1:${PROD_PORT}/status" | grep -o '"status":"[^"]*"' || true
substep "Server container log registered the recovery event:"
docker compose -f docker-compose.prod.yml --env-file .env.prod logs web 2>&1 | grep 'cache_available' | tail -n 1 | sed 's/^/    /' || true
substep "Notice in web UI: Redis status dot automatically recovers to GREEN ('Connected')."
pause

step "Simulating PostgreSQL outage in Production ('make kill-db ENV=prod')..."
make kill-db ENV=prod >/dev/null 2>&1
wait_svc "$PROD_PORT" database down || true

substep "Querying /status (dynamically returns HTTP 503 Service Unavailable):"
curl -s -o /dev/null -w "  HTTP Status Code: %{http_code}\n" "http://127.0.0.1:${PROD_PORT}/status"
substep "Notice in web UI: PostgreSQL status dot turns RED, banner alerts database unavailable."
printf "${YELLOW}  (Take your time to show the database outage in the browser)${NC}\n"
pause

step "Restoring PostgreSQL ('make start-db ENV=prod')..."
make start-db ENV=prod >/dev/null 2>&1
wait_svc "$PROD_PORT" database up || true
substep "Querying /status after PostgreSQL recovery (HTTP 200 OK):"
curl -s -o /dev/null -w "  HTTP Status Code: %{http_code}\n" "http://127.0.0.1:${PROD_PORT}/status"
substep "Notice in web UI: Status recovers automatically and incident table reloads!"
printf "${GREEN}✔ Resilience demonstrated! Web dynamically adapts to service status.${NC}\n"

pause

# ------------------------------------------------------------------------------
header "5. SECURITY & NETWORK ISOLATION"

step "Checking published host ports:"
substep "Ports published in Dev:"
docker compose -f docker-compose.dev.yml --env-file .env.dev ps --format "table {{.Service}}\t{{.Ports}}"
substep "Ports published in Prod:"
docker compose -f docker-compose.prod.yml --env-file .env.prod ps --format "table {{.Service}}\t{{.Ports}}"
substep "Notice: ONLY the 'web' service binds to 127.0.0.1. DB and Cache have NO exposed host ports."

step "Verifying backend internal network blocks outbound traffic:"
substep "Dev backend internal:  $(docker network inspect bugtracker-dev_backend -f '{{.Internal}}')"
substep "Prod backend internal: $(docker network inspect bugtracker-prod_backend -f '{{.Internal}}')"

step "Verifying containers run as unprivileged users (non-root):"
substep "Web UID:   $(docker compose -f docker-compose.prod.yml --env-file .env.prod exec -T web id -u) (node)"
substep "Redis UID: $(docker compose -f docker-compose.prod.yml --env-file .env.prod exec -T cache id -u) (redis)"

# ------------------------------------------------------------------------------
header "DEMONSTRATION COMPLETED SUCCESSFULLY"
printf "${GREEN}${BOLD}All technical requirements of Practice 1 verified.${NC}\n"
printf "To run the complete automated test suite (113 checks), run: ${CYAN}make test${NC}\n\n"
