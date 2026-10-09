#!/usr/bin/env bash
# End-to-end verification of the dev and prod environments.
# Starts from nothing (make clean), prints one PASS or FAIL line per check and
# exits with a non-zero status if any check fails.
# WARNING: it deletes the containers, volumes and images of this project.

set -u
cd "$(dirname "$0")/.." || exit 2

pass=0
fail=0
HC="hc-negative-$$"
PG="pg-coldstart-$$"
trap 'docker rm -fv "$HC" "$PG" >/dev/null 2>&1' EXIT

for tool in docker curl openssl make awk; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool"; exit 2; }
done

# ----------------------------------------------------------------- helpers

ok()      { printf 'PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad()     { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }
info()    { printf 'INFO  %s\n' "$1"; }
section() { printf '\n== %s ==\n' "$1"; }

# check "description" command...  passes when the command exits with 0.
check() {
  local desc=$1 out
  shift
  if out=$("$@" 2>&1); then
    ok "$desc"
  else
    bad "$desc"
    printf '%s\n' "$out" | tail -n 3 | sed 's/^/        /'
  fi
}

# expect "description" expected actual
expect() {
  if [ "$3" = "$2" ]; then ok "$1 [$3]"; else bad "$1 (expected '$2', got '$3')"; fi
}

mk()   { make --no-print-directory "$@"; }
dev()  { docker compose -f docker-compose.dev.yml  --env-file .env.dev  "$@"; }
prod() { docker compose -f docker-compose.prod.yml --env-file .env.prod "$@"; }

has()    { printf '%s' "$1" | grep -q -- "$2"; }
fails()  { ! "$@" >/dev/null 2>&1; }
code()   { curl -s -o /dev/null -m 10 -w '%{http_code}' "$@"; }
health() { docker inspect -f '{{.State.Health.Status}}' "$1"; }
mode()   { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
now_ms() { echo $(( $(date +%s%N) / 1000000 )); }

# Values read from the JSON of /status.
top()    { printf '%s' "$1" | grep -o '"status":"[a-z]*"' | head -n 1 | cut -d'"' -f4; }
env_of() { printf '%s' "$1" | grep -o '"environment":"[a-z]*"' | cut -d'"' -f4; }
svc()    { printf '%s' "$1" | grep -o "\"$2\":{[^}]*}" | grep -o '"status":"[a-z]*"' | cut -d'"' -f4; }

# wait_svc url service state: waits up to 60 s for /status to report the state.
wait_svc() {
  for _ in $(seq 1 60); do
    [ "$(svc "$(curl -s -m 5 "$1/status")" "$2")" = "$3" ] && return 0
    sleep 1
  done
  return 1
}

# q env "SQL": runs a query inside the db container of that environment.
q() { "$1" exec -T db sh -c "psql -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -tAc \"$2\""; }

post()     { code -X POST "$1/api/incidents" -H 'Content-Type: application/json' -d "$2"; }
incident() { printf '{"title":"%s","system_name":"test","priority":"LOW"}' "$1"; }

# Cache helpers: X-Cache and X-Response-Time are set by the server.
header()   { curl -s -D - -o /dev/null "$1/api/incidents" | tr -d '\r' | awk -F': ' -v h="$2" 'tolower($1)==h {print $2}'; }
xcache()   { header "$1" x-cache; }
rtime()    { header "$1" x-response-time | sed 's/ms//'; }
total()    { curl -s "$1/api/incidents" | grep -o '"total":[0-9]*' | cut -d: -f2; }
# The single quotes are intentional: the variable expands inside the container.
# shellcheck disable=SC2016
drop_key() { prod exec -T cache sh -c 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli del incidents' >/dev/null; }
redis_cfg(){ prod exec -T cache sh -c "REDISCLI_AUTH=\"\$REDIS_PASSWORD\" redis-cli config get $1" | tail -n 1; }
mean()     { awk '{s += $1} END {if (NR) printf "%.2f", s / NR}'; }
faster()   { awk -v a="$1" -v b="$2" 'BEGIN {exit !(a < b)}'; }

leftovers() {
  printf '%s %s %s %s' \
    "$(docker ps -aq --filter name=bugtracker | wc -l)" \
    "$(docker volume ls -q --filter name=bugtracker | wc -l)" \
    "$(docker network ls -q --filter name=bugtracker | wc -l)" \
    "$(docker images -q 'bugtracker-*' | wc -l)"
}

# A container whose application never answers must become unhealthy.
negative_healthcheck() {
  docker run -d --name "$HC" bugtracker-dev-web sleep 600 >/dev/null || return 1
  for _ in $(seq 1 120); do
    [ "$(health "$HC")" = unhealthy ] && return 0
    sleep 1
  done
  return 1
}

# Starts a throwaway PostgreSQL with init.sql and records when each variant of
# pg_isready first answers: over the unix socket and over TCP.
SOCK_MS=""; TCP_MS=""; PROBE_ROWS=""
cold_start_probe() {
  local image t0
  image=$(dev config --images | grep '^postgres')
  docker run -d --name "$PG" -e POSTGRES_USER=probe -e POSTGRES_DB=probe \
    -e POSTGRES_PASSWORD="$(openssl rand -hex 12)" \
    -v "$PWD/db/init.sql:/docker-entrypoint-initdb.d/init.sql:ro" "$image" >/dev/null || return 1
  t0=$(now_ms)
  while [ $(( $(now_ms) - t0 )) -lt 90000 ]; do
    [ -n "$SOCK_MS" ] || { docker exec "$PG" pg_isready -q -U probe -d probe && SOCK_MS=$(( $(now_ms) - t0 )); }
    [ -n "$TCP_MS" ]  || { docker exec "$PG" pg_isready -q -h 127.0.0.1 -U probe -d probe && TCP_MS=$(( $(now_ms) - t0 )); }
    [ -n "$SOCK_MS" ] && [ -n "$TCP_MS" ] && break
    sleep 0.1
  done
  PROBE_ROWS=$(docker exec "$PG" psql -U probe -d probe -tAc 'SELECT count(*) FROM incidents' 2>/dev/null)
}

printf 'Verification run: %s\n' "$(date -u +'%Y-%m-%d %H:%M:%S UTC')"
printf 'Docker %s, Compose %s\n' "$(docker version -f '{{.Server.Version}}')" "$(docker compose version --short)"

# ---------------------------------------------------------------- 1. setup

section "1. Setup from nothing"
check "make setup-env succeeds" mk setup-env
for e in dev prod; do expect ".env.$e permissions" 600 "$(mode ".env.$e")"; done
sum=$(cksum < .env.dev)
mk setup-env >/dev/null 2>&1
check "make setup-env keeps the existing secrets" test "$sum" = "$(cksum < .env.dev)"

check "make clean succeeds" mk clean
expect "make clean leaves nothing (containers volumes networks images)" "0 0 0 0" "$(leftovers)"
check "make up-dev succeeds" mk up-dev
check "make up-prod succeeds" mk up-prod

leaks=$(grep -rlF --exclude-dir=.git --exclude-dir=node_modules --exclude=.env.dev --exclude=.env.prod \
  -f <(awk -F= '/PASSWORD=/ && $2 != "" {print $2}' .env.dev .env.prod) . 2>/dev/null)
if [ -z "$leaks" ]; then ok "no generated secret appears in any other file"; else bad "secret found in: $leaks"; fi
if [ -d .git ]; then
  expect "real .env files are not tracked by git" 0 "$(git ls-files .env.dev .env.prod | wc -l)"
  check ".env.dev is ignored by git" git check-ignore -q .env.dev
  check ".env.prod is ignored by git" git check-ignore -q .env.prod
fi
expect "UI code never inserts data as HTML" 0 "$(grep -cE 'innerHTML|outerHTML|insertAdjacentHTML|eval\(' src/public/app.js)"

# ------------------------------------------------------------------ 2. dev

section "2. Dev environment (web + db)"
DEV="http://127.0.0.1:$(sed -n 's/^WEB_PORT=//p' .env.dev)"

for s in web db; do expect "dev $s is healthy" healthy "$(health "$(dev ps -q $s)")"; done
expect "dev defines no cache service" "db web" "$(dev config --services | sort | paste -sd' ')"

st=$(curl -s -m 10 "$DEV/status")
expect "dev /status HTTP code" 200 "$(code "$DEV/status")"
expect "dev environment reported" development "$(env_of "$st")"
expect "dev overall status" ok "$(top "$st")"
expect "dev database" up "$(svc "$st" database)"
expect "dev cache" disabled "$(svc "$st" cache)"

expect "dev web publishes only on localhost" "127.0.0.1:${DEV##*:}" "$(docker port "$(dev ps -q web)" | awk '{print $3}' | paste -sd,)"
expect "dev db publishes no port" 0 "$(docker port "$(dev ps -q db)" | wc -l)"
expect "dev backend network is internal" true "$(docker network inspect bugtracker-dev_backend -f '{{.Internal}}')"
check "dev db cannot reach the outside" fails dev exec -T db wget -q -T 3 -O /dev/null http://1.1.1.1
expect "dev web runs as non-root (uid)" 1000 "$(dev exec -T web id -u)"
check "dev web cannot modify its own code" fails dev exec -T web touch /app/src/probe

check "dev make test-db: PostgreSQL accepts connections" has "$(mk -s test-db 2>&1)" 'accepting connections'
expect "dev seed data loaded by init.sql (rows)" 50006 "$(q dev 'SELECT count(*) FROM incidents')"

page=$(curl -s -m 10 "$DEV/")
expect "dev serves the page" 200 "$(code "$DEV/")"
check "page contains the dashboard" has "$page" 'IT Incident Tracker'
expect "dev serves styles.css" 200 "$(code "$DEV/styles.css")"
expect "dev serves app.js" 200 "$(code "$DEV/app.js")"
check "responses carry a Content-Security-Policy header" has "$(curl -sI -m 10 "$DEV/")" 'Content-Security-Policy'

expect "POST a valid incident" 201 "$(post "$DEV" "$(incident 'Test incident')")"
expect "POST with an empty title" 400 "$(post "$DEV" "$(incident '')")"
expect "POST with malformed JSON" 400 "$(post "$DEV" '{bad')"
expect "POST with an oversized body" 413 "$(post "$DEV" "$(incident "$(head -c 20000 /dev/zero | tr '\0' a)")")"
expect "unknown route" 404 "$(code "$DEV/does-not-exist")"
expect "SQL injection text is stored as plain data" 201 "$(post "$DEV" "$(incident "x'); DROP TABLE incidents; --")")"
expect "table intact after the injection attempt (50006 + 2 rows)" 50008 "$(q dev 'SELECT count(*) FROM incidents')"

dev_log=$(dev logs web 2>&1)
check "dev (debug) logs the API requests" has "$dev_log" '"msg":"request"'
expect "dev debug log skips /status and /live" 0 "$(printf '%s\n' "$dev_log" | grep '"msg":"request"' | grep -cE '"path":"/(live|status)"')"

dev stop db >/dev/null 2>&1
check "dev: /status reports the database down" wait_svc "$DEV" database down
expect "dev: overall status while db is down" degraded "$(top "$(curl -s -m 10 "$DEV/status")")"
expect "dev: HTTP code while db is down" 503 "$(code "$DEV/status")"
expect "dev: web container stays healthy while db is down" healthy "$(health "$(dev ps -q web)")"
dev start db >/dev/null 2>&1
check "dev: /status recovers when db returns" wait_svc "$DEV" database up
expect "dev: HTTP code after recovery" 200 "$(code "$DEV/status")"

section "3. Persistence (dev)"
expect "insert an incident through the API" 201 "$(post "$DEV" "$(incident 'Persistence check')")"
old_db=$(dev ps -q db)
check "dev down removes the containers" dev down
expect "no container left after down" 0 "$(dev ps -aq | wc -l)"
expect "the data volume still exists" 1 "$(docker volume ls -q --filter name=bugtracker-dev_db-data | wc -l)"
check "dev up recreates the containers" dev up -d --wait
check "db is a new container" test "$old_db" != "$(dev ps -q db)"
expect "the incident survived" 1 "$(q dev "SELECT count(*) FROM incidents WHERE title = 'Persistence check'")"
expect "all rows survived (50006 + 3)" 50009 "$(q dev 'SELECT count(*) FROM incidents')"
check "contrast: dev down -v removes the volume too" dev down -v
check "contrast: dev up starts from an empty volume" dev up -d --wait
expect "contrast: init.sql ran again (rows)" 50006 "$(q dev 'SELECT count(*) FROM incidents')"
expect "contrast: the incident is gone" 0 "$(q dev "SELECT count(*) FROM incidents WHERE title = 'Persistence check'")"

# ----------------------------------------------------------------- 4. prod

section "4. Prod environment (web + db + cache)"
PROD="http://127.0.0.1:$(sed -n 's/^WEB_PORT=//p' .env.prod)"

for s in web db cache; do expect "prod $s is healthy" healthy "$(health "$(prod ps -q $s)")"; done
expect "prod defines the cache service" "cache db web" "$(prod config --services | sort | paste -sd' ')"

st=$(curl -s -m 10 "$PROD/status")
expect "prod /status HTTP code" 200 "$(code "$PROD/status")"
expect "prod environment reported" production "$(env_of "$st")"
expect "prod overall status" ok "$(top "$st")"
expect "prod database" up "$(svc "$st" database)"
expect "prod cache" up "$(svc "$st" cache)"

expect "prod web publishes only on localhost" "127.0.0.1:${PROD##*:}" "$(docker port "$(prod ps -q web)" | awk '{print $3}' | paste -sd,)"
expect "prod db publishes no port" 0 "$(docker port "$(prod ps -q db)" | wc -l)"
expect "prod cache publishes no port" 0 "$(docker port "$(prod ps -q cache)" | wc -l)"
expect "prod backend network is internal" true "$(docker network inspect bugtracker-prod_backend -f '{{.Internal}}')"
check "prod db cannot reach the outside" fails prod exec -T db wget -q -T 3 -O /dev/null http://1.1.1.1
check "prod cache cannot reach the outside" fails prod exec -T cache wget -q -T 3 -O /dev/null http://1.1.1.1
expect "prod web runs as non-root (uid)" 1000 "$(prod exec -T web id -u)"
expect "prod redis runs as non-root (uid)" 999 "$(prod exec -T cache id -u)"
expect "prod web memory limit (bytes)" 268435456 "$(docker inspect -f '{{.HostConfig.Memory}}' "$(prod ps -q web)")"
expect "prod db memory limit (bytes)" 536870912 "$(docker inspect -f '{{.HostConfig.Memory}}' "$(prod ps -q db)")"
expect "prod cache memory limit (bytes)" 134217728 "$(docker inspect -f '{{.HostConfig.Memory}}' "$(prod ps -q cache)")"

expect "redis snapshots disabled (save)" "" "$(redis_cfg save)"
expect "redis append-only file disabled" no "$(redis_cfg appendonly)"
expect "redis memory cap (bytes)" 67108864 "$(redis_cfg maxmemory)"
expect "redis eviction policy" allkeys-lru "$(redis_cfg maxmemory-policy)"
check "redis rejects clients without the password" has "$(prod exec -T cache redis-cli -h 127.0.0.1 ping 2>&1)" NOAUTH
check "prod make test-db: PostgreSQL accepts connections" has "$(mk -s test-db ENV=prod 2>&1)" 'accepting connections'
check "make test-cache: Redis answers PONG" has "$(mk -s test-cache 2>&1)" PONG

section "5. Cache behaviour (prod)"
expect "first read is a MISS" MISS "$(xcache "$PROD")"
expect "second read is a HIT" HIT "$(xcache "$PROD")"
expect "write through the API" 201 "$(post "$PROD" "$(incident 'Cache invalidation check')")"
expect "read after a write is a MISS" MISS "$(xcache "$PROD")"
expect "the new incident is counted (50006 + 1)" 50007 "$(total "$PROD")"
expect "next read is a HIT again" HIT "$(xcache "$PROD")"

prod stop cache >/dev/null 2>&1
check "prod: /status reports the cache down" wait_svc "$PROD" cache down
expect "prod: overall status while cache is down" degraded "$(top "$(curl -s -m 10 "$PROD/status")")"
expect "prod: HTTP code while cache is down" 200 "$(code "$PROD/status")"
expect "prod: web container stays healthy while cache is down" healthy "$(health "$(prod ps -q web)")"
expect "prod: reads keep working from PostgreSQL" MISS "$(xcache "$PROD")"
expect "prod: write while the cache is down" 201 "$(post "$PROD" "$(incident 'Written while cache was down')")"
prod start cache >/dev/null 2>&1
check "prod: /status recovers when the cache returns" wait_svc "$PROD" cache up
expect "after the restart the first read is a MISS (no stale data)" MISS "$(xcache "$PROD")"
expect "the write made during the outage is visible (50006 + 2)" 50008 "$(total "$PROD")"
expect "next read is a HIT" HIT "$(xcache "$PROD")"

N=30
miss=$(for _ in $(seq "$N"); do drop_key; rtime "$PROD"; done)
hit=$(for _ in $(seq "$N"); do rtime "$PROD"; done)
m=$(printf '%s\n' "$miss" | mean)
h=$(printf '%s\n' "$hit" | mean)
info "server-side read time over $N requests each: MISS mean ${m} ms, HIT mean ${h} ms"
check "a cache HIT is faster than a MISS on average" faster "$h" "$m"

expect "prod (info) logs no request lines" 0 "$(prod logs web 2>&1 | grep -c '"msg":"request"')"
prod stop web >/dev/null 2>&1
expect "prod web exits with code 0 on SIGTERM (graceful shutdown)" 0 "$(docker inspect -f '{{.State.ExitCode}}' "$(prod ps -aq web)")"
check "prod web starts again" prod up -d --wait

# --------------------------------------------------------- 6. healthchecks

section "6. Healthchecks"
check "web healthcheck turns unhealthy when the app does not answer" negative_healthcheck
cold_start_probe
info "pg_isready answered over the unix socket at ${SOCK_MS:-never} ms and over TCP at ${TCP_MS:-never} ms (cold start)"
check "the TCP check answers only after init.sql finished (later than the socket check)" test "${TCP_MS:-0}" -gt "${SOCK_MS:-999999}"
expect "all rows exist when the TCP check reports ready" 50006 "$PROBE_ROWS"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
