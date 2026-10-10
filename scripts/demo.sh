#!/usr/bin/env bash
# ==============================================================================
# GUIDED DEMONSTRATION - IT INCIDENT TRACKER (Practice 1)
# ==============================================================================
# Walks through every requirement of the practice, one step at a time, with the
# browser on one side of the screen and this terminal on the other.
#
# Usage
#   make demo                      interactive: one ENTER per step
#   bash scripts/demo.sh --auto    no pauses (also used when stdin is not a TTY)
#
# What every step prints
#   WHAT      what the step demonstrates
#   WEB       what changes in the page (open the dev and prod pages first)
#   TERMINAL  every command that is executed, followed by its output
#   RESULT    PASS/FAIL checks computed from real values, never hard-coded
#
# Sections
#   1 Environments   2 Persistence   3 Cache   4 Failures   5 Security
#
# Safety
#   The demo stops Redis and PostgreSQL on purpose. A trap restores whatever it
#   stopped if the script ends early (Ctrl+C, error, or "q" at a prompt).
# ==============================================================================

set -u
cd "$(dirname "$0")/.." || exit 2

# ================================================================ 0. SETTINGS

AUTO=0
case "${1:-}" in
  "")        ;;
  --auto)    AUTO=1 ;;
  -h|--help) printf 'usage: bash scripts/demo.sh [--auto]\n'; exit 0 ;;
  *)         printf 'usage: bash scripts/demo.sh [--auto]\n' >&2; exit 2 ;;
esac
[ -t 0 ] || AUTO=1

STATE_TIMEOUT_S=60   # how long to wait for /status to report a state change
WEB_SYNC_S=4         # the page polls /status every 3 s (app.js): wait one full
                     # cycle so the audience sees each change before we go on
SAMPLES=10           # reads per group in the MISS-vs-HIT timing

PASS=0; FAIL=0; SKIP=0
FAILED_LIST=''
LAST=''              # raw output of the last *_show helper
STARTED=0            # becomes 1 once both environments are up
DB_DEV_DOWN=0; DB_PROD_DOWN=0; CACHE_DOWN=0   # what the demo has stopped
START_TIME=$SECONDS
TMP=$(mktemp -d)

# Terminal width: the terminal usually shares the screen with the browser.
W=$(tput cols 2>/dev/null || echo 80)
[ "$W" -gt 100 ] && W=100
[ "$W" -lt 60 ] && W=60

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'
  YELLOW=$'\033[33m'; BLUE=$'\033[34m'; CYAN=$'\033[36m'; RESET=$'\033[0m'
else
  BOLD=''; DIM=''; RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; RESET=''
fi

# ============================================================ 1. DOCKER HELPERS

# compose <env> <args...>: docker compose for dev or prod, same flags as the Makefile.
compose() { local e=$1; shift; docker compose -f "docker-compose.${e}.yml" --env-file ".env.${e}" "$@"; }

# Names are read from the files, never typed here.
project_of() { sed -n 's/^name: *//p' "docker-compose.$1.yml" | head -n 1; }
env_value()  { sed -n "s/^$2=//p" ".env.$1" | head -n 1; }
url_of()     { printf 'http://127.0.0.1:%s' "$(env_value "$1" WEB_PORT)"; }
cid()        { compose "$1" ps -q "$2"; }
health_of()  { docker inspect -f '{{.State.Health.Status}}' "$(cid "$1" "$2")" 2>/dev/null || echo missing; }
mode_of()    { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
published_ports() { docker port "$(cid "$1" "$2")" 2>/dev/null | awk '{print $3}' | sort -u | paste -sd, -; }

# Runs a query inside the db container, using the container's own credentials.
sql() { compose "$1" exec -T db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "$1"' sh "$2"; }
# Runs redis-cli inside the prod cache container, authenticated.
redis() { compose prod exec -T cache sh -c 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli "$@"' sh "$@"; }
redis_stat() { redis info stats 2>/dev/null | tr -d '\r' | awk -F: -v k="$1" '$1==k {print $2}'; }

# ================================================================== 2. HTTP / JSON

# Values read from the JSON of /status.
top()         { printf '%s' "$1" | grep -o '"status":"[a-z]*"' | head -n 1 | cut -d'"' -f4; }
env_of()      { printf '%s' "$1" | grep -o '"environment":"[a-z]*"' | cut -d'"' -f4; }
svc()         { printf '%s' "$1" | grep -o "\"$2\":{[^}]*}" | grep -o '"status":"[a-z]*"' | cut -d'"' -f4; }
svc_latency() { printf '%s' "$1" | grep -o "\"$2\":{[^}]*}" | grep -o '"latencyMs":[0-9.]*' | cut -d: -f2; }

# fetch_status <env>: sets ST_CODE and ST_BODY (a 503 still carries the JSON).
fetch_status() {
  local out
  out=$(curl -s -m 10 -w '\n%{http_code}' "$(url_of "$1")/status" 2>/dev/null) || true
  ST_CODE=${out##*$'\n'}
  ST_BODY=${out%$'\n'*}
}

# read_incidents <env>: sets RD_CODE RD_CACHE RD_MS RD_TOTAL from /api/incidents.
read_incidents() {
  : >"$TMP/h"; : >"$TMP/b"
  RD_CODE=$(curl -s -m 10 -D "$TMP/h" -o "$TMP/b" -w '%{http_code}' "$(url_of "$1")/api/incidents" 2>/dev/null)
  RD_CACHE=$(tr -d '\r' <"$TMP/h" | awk -F': ' 'tolower($1)=="x-cache" {print $2}')
  RD_MS=$(tr -d '\r' <"$TMP/h" | awk -F': ' 'tolower($1)=="x-response-time" {print $2}' | sed 's/ms//')
  RD_TOTAL=$(grep -o '"total":[0-9]*' "$TMP/b" | head -n 1 | cut -d: -f2)
}

# post_incident <env> <title> <priority>: sets PO_CODE and PO_ID.
post_incident() {
  : >"$TMP/p"
  PO_CODE=$(curl -s -m 10 -o "$TMP/p" -w '%{http_code}' -X POST "$(url_of "$1")/api/incidents" \
    -H 'Content-Type: application/json' \
    -d "$(printf '{"title":"%s","system_name":"demo-host","priority":"%s"}' "$2" "$3")" 2>/dev/null)
  PO_ID=$(grep -o '"id":[0-9]*' "$TMP/p" | head -n 1 | cut -d: -f2)
}

faster()   { awk -v a="$1" -v b="$2" 'BEGIN {exit !(a < b)}'; }
in_range() { case $1 in ''|*[!0-9]*) return 1;; esac; [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]; }
stats()    { awk 'NF {s += $1; if (min == "" || $1 < min) min = $1; if ($1 > max) max = $1; n++}
                  END {if (n) printf "%.2f %.2f %.2f", s / n, min, max}'; }

# ==================================================================== 3. UI TOOLKIT

hr() { local ch=$1 i; for ((i = 0; i < W; i++)); do printf '%s' "$ch"; done; printf '\n'; }

section() { # number title
  printf '\n%s%s' "$BOLD" "$CYAN"; hr '━'
  printf ' %s - %s\n' "$1" "$2"
  hr '━'; printf '%s' "$RESET"
}

step() { # id title
  printf '\n%s%s STEP %s%s  %s%s\n' "$BOLD" "$YELLOW" "$1" "$RESET$BOLD" "$2" "$RESET"
  printf '%s' "$DIM"; hr '─'; printf '%s' "$RESET"
}

# field <WHAT|WEB> <text...>: labelled, word-wrapped paragraph.
field() {
  local label=$1 color=$BOLD line first=1
  shift
  [ "$label" = WEB ] && color=$BLUE
  while IFS= read -r line; do
    if [ "$first" -eq 1 ]; then
      printf ' %s%-9s%s %s\n' "$color" "$label" "$RESET" "$line"; first=0
    else
      printf ' %-9s %s\n' '' "$line"
    fi
  done < <(printf '%s\n' "$*" | fold -s -w $((W - 11)))
}

terminal() { printf '\n %s%sTERMINAL%s\n' "$BOLD" "$BLUE" "$RESET"; }
result()   { printf '\n %s%sRESULT%s\n' "$BOLD" "$GREEN" "$RESET"; }
note()     { printf '   %s%s%s\n' "$DIM" "$*" "$RESET"; }
indent()   { sed 's/^/     /'; }
emit()     { [ -n "$1" ] || return 0; printf '%s\n' "$1" | indent; }
die()      { printf '%s%s%s\n' "$RED" "$*" "$RESET" >&2; exit 2; }

# trace <text>: shows the command about to run. It writes to stderr so it is
# also safe inside $(...), and it wraps long commands for a narrow terminal.
trace() {
  local line
  while IFS= read -r line; do
    printf '   %s%s%s\n' "$DIM" "$line" "$RESET" >&2
  done < <(printf '$ %s\n' "$*" | fold -s -w $((W - 6)) | sed '2,$s/^/  /')
}

# gate [message]: waits for ENTER (q quits). Does nothing in --auto mode.
gate() {
  [ "$AUTO" -eq 1 ] && return 0
  local ans
  printf '\n %s> %s  (q = quit)%s ' "$YELLOW" "${1:-ENTER to run this step}" "$RESET"
  read -r ans
  if [ "$ans" = q ]; then printf '\n'; exit 130; fi
  return 0
}

# run_quiet <cmd...>: shows the command, hides its (long) output, reports time.
run_quiet() {
  local t0=$SECONDS
  trace "$*"
  if "$@" >"$TMP/quiet.log" 2>&1; then
    printf '   %sdone in %ss%s\n' "$DIM" $((SECONDS - t0)) "$RESET"
    return 0
  fi
  printf '   %sfailed - last lines of the output:%s\n' "$RED" "$RESET"
  tail -n 8 "$TMP/quiet.log" | indent
  return 1
}

# run_dc <env> <args...>: shows and runs a docker compose command.
run_dc() {
  local e=$1
  shift
  trace "docker compose -f docker-compose.$e.yml --env-file .env.$e $*"
  compose "$e" "$@" 2>&1 | indent
}

# Showing helpers: print the command, run it, print the output, keep it in $LAST.
sql_show() { # env sql
  trace "docker compose -f docker-compose.$1.yml --env-file .env.$1 exec -T db psql -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -tAc \"$2\""
  LAST=$(sql "$1" "$2" 2>&1); emit "$LAST"
}
redis_show() { # redis-cli args
  trace "docker compose -f docker-compose.prod.yml --env-file .env.prod exec -T cache redis-cli $*"
  LAST=$(redis "$@" 2>&1); emit "$LAST"
}
read_show() { # env
  trace "curl -s -D - -o /dev/null $(url_of "$1")/api/incidents"
  read_incidents "$1"
  printf '     HTTP %s   X-Cache: %s   X-Response-Time: %s ms   total: %s\n' \
    "$RD_CODE" "${RD_CACHE:--}" "${RD_MS:--}" "${RD_TOTAL:--}"
}
post_show() { # env title priority
  trace "curl -s -X POST $(url_of "$1")/api/incidents -H 'Content-Type: application/json' -d '{\"title\":\"$2\",\"system_name\":\"demo-host\",\"priority\":\"$3\"}'"
  post_incident "$1" "$2" "$3"
  if [ "$PO_CODE" = 201 ]; then
    printf '     HTTP 201   created incident id %s\n' "$PO_ID"
  else
    printf '     HTTP %s   %s\n' "$PO_CODE" "$(head -c 100 "$TMP/p")"
  fi
}
dot() {
  case $1 in
    up)       printf '%s●%s' "$GREEN" "$RESET" ;;
    down)     printf '%s●%s' "$RED" "$RESET" ;;
    disabled) printf '%s○%s' "$DIM" "$RESET" ;;
    *)        printf '%s●%s' "$YELLOW" "$RESET" ;;
  esac
}
status_show() { # env
  trace "curl -s -m 10 $(url_of "$1")/status"
  fetch_status "$1"
  printf '     HTTP %s   overall: %s   environment: %s\n' "$ST_CODE" "$(top "$ST_BODY")" "$(env_of "$ST_BODY")"
  local name state ms
  for name in database cache; do
    state=$(svc "$ST_BODY" "$name")
    ms=$(svc_latency "$ST_BODY" "$name")
    printf '     %-9s %s %-9s %s\n' "$name" "$(dot "${state:-?}")" "${state:-no answer}" "${ms:+$ms ms}"
  done
}
ps_table() { # env
  trace "docker compose -f docker-compose.$1.yml --env-file .env.$1 ps --format 'table {{.Service}}\t{{.Status}}\t{{.Ports}}'"
  compose "$1" ps --format 'table {{.Service}}\t{{.Status}}\t{{.Ports}}' 2>&1 | indent
}
log_line() { # env pattern
  trace "docker compose -f docker-compose.$1.yml --env-file .env.$1 logs --no-log-prefix web | grep $2 | tail -n 1"
  LAST=$(compose "$1" logs --no-log-prefix web 2>&1 | grep "$2" | tail -n 1)
  emit "$LAST"
}

# await_state <env> <service> <state>: polls /status until it reports the state.
await_state() {
  local e=$1 service=$2 want=$3 t0=$SECONDS
  printf '   %swaiting for /status to report %s=%s%s' "$DIM" "$service" "$want" "$RESET"
  while [ $((SECONDS - t0)) -lt "$STATE_TIMEOUT_S" ]; do
    fetch_status "$e"
    if [ "$(svc "$ST_BODY" "$service")" = "$want" ]; then
      printf '  %s(%ss)%s\n' "$DIM" $((SECONDS - t0)) "$RESET"
      return 0
    fi
    sleep 1
  done
  printf '  %stimed out%s\n' "$RED" "$RESET"
  return 1
}

# sync_web: lets the page poll /status at least once after a change.
sync_web() {
  printf '   %sletting the page catch up (it polls /status every 3 s)%s' "$DIM" "$RESET"
  sleep "$WEB_SYNC_S"
  printf '  %sdone%s\n' "$DIM" "$RESET"
}

# ------------------------------------------------------------------- checks

pass() { printf '   %s✔ PASS%s  %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS + 1)); }
fail() {
  printf '   %s✖ FAIL%s  %s\n' "$RED" "$RESET" "$1"
  FAIL=$((FAIL + 1)); FAILED_LIST="${FAILED_LIST}  - $1"$'\n'
}
check()     { if [ "$3" = "$2" ]; then pass "$1 [$3]"; else fail "$1 (expected '$2', got '$3')"; fi; }
check_has() { if printf '%s' "$2" | grep -q -- "$3"; then pass "$1"; else fail "$1 (missing '$3')"; fi; }
check_ok()  { local desc=$1; shift; if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi; }

# ============================================================ 4. SAFETY NET

# Puts back whatever the demo stopped, so the environments are never left broken.
restore_services() {
  local did=0
  if [ "$DB_DEV_DOWN" -eq 1 ];  then compose dev up -d --wait db >/dev/null 2>&1; did=1; fi
  if [ "$DB_PROD_DOWN" -eq 1 ]; then compose prod start db       >/dev/null 2>&1; did=1; fi
  if [ "$CACHE_DOWN" -eq 1 ];   then compose prod start cache    >/dev/null 2>&1; did=1; fi
  if [ "$did" -eq 1 ]; then
    printf '\n%sThe demo restored the services it had stopped.%s\n' "$YELLOW" "$RESET"
  fi
  return 0
}

cleanup() {
  local code=$?
  trap - EXIT INT TERM
  [ "$STARTED" -eq 1 ] && restore_services
  rm -rf "$TMP"
  exit "$code"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# =================================================================== 5. SECTIONS

part_intro() {
  printf '\n%s' "$BOLD"; hr '━'
  printf ' IT INCIDENT TRACKER - GUIDED DEMONSTRATION\n'
  printf ' Practice 1: multi-environment Docker deployment\n'
  hr '━'; printf '%s' "$RESET"

  local tool
  for tool in docker curl make awk sed grep fold; do
    command -v "$tool" >/dev/null || die "missing tool: $tool"
  done
  docker info >/dev/null 2>&1 || die "the Docker daemon is not reachable"

  if [ ! -f .env.dev ] || [ ! -f .env.prod ]; then
    terminal
    run_quiet make setup-env || die "could not create the environment files"
  fi

  printf '\n'
  field LAYOUT "Page on one side of the screen, this terminal on the other."
  field PAGES "dev  $(url_of dev)    prod  $(url_of prod)"
  field READ "WEB = what changes in the page. TERMINAL = every command that runs. RESULT = checks computed from real values."
  field MODE "$([ "$AUTO" -eq 1 ] && echo 'automatic (no pauses)' || echo 'interactive: one ENTER per step')"

  step 0 "Start both environments"
  field WHAT "make up-dev and make up-prod build the image if needed and wait until every container is healthy. Running them again is harmless."
  gate
  terminal
  run_quiet make up-dev  || die "make up-dev failed"
  run_quiet make up-prod || die "make up-prod failed"
  STARTED=1
  printf '\n'
  field WEB "Open both pages now: $(url_of dev) (dev) and $(url_of prod) (prod). The pill at the top right should read 'All systems operational' on both."
  gate "ENTER when both pages are open"
}

part_environments() {
  section 1 "ENVIRONMENTS: DEV vs PROD"

  step 1.1 "Containers and their health"
  field WHAT "Dev runs web + db. Prod adds Redis. Every container has a healthcheck, and compose waits for it before starting what depends on it."
  field WEB "Nothing changes yet: the page is only healthy if the containers below are."
  gate
  terminal
  ps_table dev
  ps_table prod
  result
  local pair e s
  for pair in "dev web" "dev db" "prod web" "prod db" "prod cache"; do
    read -r e s <<<"$pair"
    check "$e $s container is healthy" healthy "$(health_of "$e" "$s")"
  done

  step 1.2 "/status in both environments"
  field WHAT "The same endpoint reports the dependencies. Redis is 'disabled' in dev because the cache exists only in production."
  field WEB "System tab. Dev: Redis card reads 'Disabled'. Prod: 'Operational'. The badge in the header reads Development or Production."
  gate
  terminal
  status_show dev
  local dev_body=$ST_BODY dev_code=$ST_CODE
  status_show prod
  result
  check "dev /status HTTP code" 200 "$dev_code"
  check "dev database" up "$(svc "$dev_body" database)"
  check "dev cache" disabled "$(svc "$dev_body" cache)"
  check "prod /status HTTP code" 200 "$ST_CODE"
  check "prod database" up "$(svc "$ST_BODY" database)"
  check "prod cache" up "$(svc "$ST_BODY" cache)"

  step 1.3 "Logging per environment"
  field WHAT "Dev logs every API request (debug level). Prod logs only lifecycle events (info level), so its log stays clean."
  field WEB "Nothing changes: this is operational visibility, not user interface."
  gate
  terminal
  read_show dev
  log_line dev '"msg":"request"'
  local dev_line=$LAST
  trace "docker compose -f docker-compose.prod.yml --env-file .env.prod logs --no-log-prefix web | grep -c '\"msg\":\"request\"'"
  local prod_count
  prod_count=$(compose prod logs --no-log-prefix web 2>&1 | grep -c '"msg":"request"')
  printf '     %s request lines in the prod log\n' "$prod_count"
  result
  check_has "dev log contains request lines" "$dev_line" '"msg":"request"'
  check "prod log contains no request lines" 0 "$prod_count"
}

part_persistence() {
  section 2 "DATA PERSISTENCE (DEV)"
  local vol rows_before id old_id new_id title
  vol="$(project_of dev)_db-data"
  title="Persistence demo $(date +%H:%M:%S)"

  step 2.1 "Connection test and starting point"
  field WHAT "make test-db is the connection test: pg_isready plus a row count. The data lives in a named Docker volume, not in the container."
  field WEB "Dev page, Overview: the Total card shows the same count."
  gate
  terminal
  trace "make test-db"
  LAST=$(make --no-print-directory test-db 2>&1); emit "$LAST"
  local test_db=$LAST
  rows_before=$(printf '%s\n' "$LAST" | tail -n 1)
  trace "docker volume ls --filter name=$vol"
  emit "$(docker volume ls --filter "name=$vol" 2>&1)"
  result
  check_has "PostgreSQL accepts connections" "$test_db" 'accepting connections'
  check_ok "row count is numeric ($rows_before rows)" in_range "$rows_before" 1 999999999
  check_ok "the data volume exists" docker volume inspect "$vol"

  step 2.2 "Insert an incident"
  field WHAT "A new incident is created through the API and then read back straight from PostgreSQL."
  field WEB "Incidents tab, press Refresh: '$title' is the first row."
  gate
  terminal
  post_show dev "$title" HIGH
  id=$PO_ID
  check "the API accepted the incident" 201 "$PO_CODE"
  sql_show dev "SELECT id, title, priority FROM incidents WHERE id = $id"
  result
  check_has "the row exists in PostgreSQL" "$LAST" "$title"

  step 2.3 "Remove the database container"
  field WHAT "docker compose rm deletes the db container but never its volume. The web container keeps running."
  field WEB "The pill turns red: 'Database unavailable'. System tab: PostgreSQL reads 'Unavailable' and a 'Down' event is logged. A toast says 'PostgreSQL became unavailable'."
  gate
  terminal
  old_id=$(cid dev db)
  DB_DEV_DOWN=1
  run_dc dev rm -sf db
  trace "docker compose -f docker-compose.dev.yml --env-file .env.dev ps -aq db | wc -l"
  local left
  left=$(compose dev ps -aq db | wc -l | tr -d ' ')
  printf '     %s db containers left\n' "$left"
  trace "docker volume ls -q --filter name=$vol"
  local vols
  vols=$(docker volume ls -q --filter "name=$vol" | grep -cx "$vol")
  printf '     %s data volume still present\n' "$vols"
  await_state dev database down
  sync_web
  status_show dev
  result
  check "the db container is gone" 0 "$left"
  check "the data volume survived" 1 "$vols"
  check "/status HTTP code while the database is down" 503 "$ST_CODE"
  check "database reported as" down "$(svc "$ST_BODY" database)"
  check "web container stays healthy (liveness does not depend on the db)" healthy "$(health_of dev web)"

  step 2.4 "Create the container again"
  field WHAT "up -d creates a brand new db container and mounts the same volume. init.sql does not run again, so nothing is re-seeded."
  field WEB "The pill turns green again, a toast says 'PostgreSQL is back online', and the page reloads the table by itself: '$title' is still the first row. The Total card grew by one."
  gate
  terminal
  run_dc dev up -d --wait db
  DB_DEV_DOWN=0
  new_id=$(cid dev db)
  printf '     old container: %s\n     new container: %s\n' "${old_id:0:12}" "${new_id:0:12}"
  await_state dev database up
  sync_web
  status_show dev
  sql_show dev "SELECT id, title, priority FROM incidents WHERE id = $id"
  local row=$LAST
  sql_show dev "SELECT count(*) FROM incidents"
  result
  check_ok "it is a different container" test "$old_id" != "$new_id"
  check "/status HTTP code after recovery" 200 "$ST_CODE"
  check_has "the incident survived the container" "$row" "$title"
  check "row count is exactly the old count + 1 (no re-seed)" $((rows_before + 1)) "$LAST"
}

part_cache() {
  section 3 "CACHE (PROD)"
  local ttl
  ttl=$(env_value prod CACHE_TTL_SECONDS); ttl=${ttl:-60}

  step 3.1 "Connection test and cache settings"
  field WHAT "make test-cache is the connection test for Redis. The cache keeps nothing on disk and has a memory cap with LRU eviction."
  field WEB "Prod page, System tab: the Redis card reads 'Operational' with its latency."
  gate
  terminal
  trace "make test-cache"
  LAST=$(make --no-print-directory test-cache 2>&1); emit "$LAST"
  local pong=$LAST
  redis_show config get maxmemory
  local maxmem; maxmem=$(printf '%s\n' "$LAST" | tail -n 1)
  redis_show config get maxmemory-policy
  local policy; policy=$(printf '%s\n' "$LAST" | tail -n 1)
  result
  check_has "Redis answers PONG" "$pong" PONG
  check "memory cap in bytes" 67108864 "$maxmem"
  check "eviction policy" allkeys-lru "$policy"

  step 3.2 "First read: cache MISS"
  field WHAT "Cache-aside: the app asks Redis first. With an empty cache it queries PostgreSQL (a full scan of the table), then stores the answer with a ${ttl} s expiry."
  field WEB "Not visible yet: the page has not read anything. Step 3.6 shows the page doing it."
  gate
  terminal
  redis_show del incidents
  redis_show exists incidents
  local before=$LAST
  read_show prod
  local first_cache=$RD_CACHE
  redis_show exists incidents
  local after=$LAST
  redis_show ttl incidents
  result
  check "key absent before the read" 0 "$before"
  check "first read is a MISS (served by PostgreSQL)" MISS "$first_cache"
  check "key stored in Redis after the read" 1 "$after"
  check_ok "key expires by itself (TTL between 1 and $ttl s)" in_range "$LAST" 1 "$ttl"

  step 3.3 "Second read: cache HIT"
  field WHAT "The same request is now answered from Redis memory. PostgreSQL is not touched."
  field WEB "Not visible yet: see step 3.6."
  gate
  terminal
  read_show prod
  local second_cache=$RD_CACHE
  redis_show ttl incidents
  result
  check "second read is a HIT (served by Redis)" HIT "$second_cache"
  check_ok "the expiry keeps counting down (TTL below $ttl s)" in_range "$LAST" 1 "$ttl"

  step 3.4 "Measured speed-up"
  field WHAT "$SAMPLES cold reads (key deleted before each) against $SAMPLES warm reads. The time is measured by the server and sent in the X-Response-Time header."
  field WEB "Not visible: this measures the server."
  gate
  terminal
  trace "repeat $SAMPLES times: redis-cli del incidents; curl -s -D - -o /dev/null $(url_of prod)/api/incidents   (cold)"
  local miss_list='' hit_list='' miss_ok=0 hit_ok=0 i
  printf '     cold '
  for i in $(seq "$SAMPLES"); do
    redis del incidents >/dev/null 2>&1
    read_incidents prod
    miss_list="$miss_list$RD_MS"$'\n'
    [ "$RD_CACHE" = MISS ] && miss_ok=$((miss_ok + 1))
    printf '.'
  done
  printf '\n'
  trace "repeat $SAMPLES times: curl -s -D - -o /dev/null $(url_of prod)/api/incidents   (warm)"
  read_incidents prod
  printf '     warm '
  for i in $(seq "$SAMPLES"); do
    read_incidents prod
    hit_list="$hit_list$RD_MS"$'\n'
    [ "$RD_CACHE" = HIT ] && hit_ok=$((hit_ok + 1))
    printf '.'
  done
  printf '\n'
  local m_mean m_min m_max h_mean h_min h_max ratio
  read -r m_mean m_min m_max <<<"$(printf '%s' "$miss_list" | stats)"
  read -r h_mean h_min h_max <<<"$(printf '%s' "$hit_list" | stats)"
  ratio=$(awk -v a="${m_mean:-0}" -v b="${h_mean:-0}" 'BEGIN {if (b > 0) printf "%.1f", a / b; else print "n/a"}')
  printf '     MISS  PostgreSQL  mean %s ms   (min %s, max %s)\n' "$m_mean" "$m_min" "$m_max"
  printf '     HIT   Redis       mean %s ms   (min %s, max %s)\n' "$h_mean" "$h_min" "$h_max"
  printf '     a HIT is %sx faster than a MISS\n' "$ratio"
  result
  check "every cold read was a MISS" "$SAMPLES" "$miss_ok"
  check "every warm read was a HIT" "$SAMPLES" "$hit_ok"
  check_ok "a HIT is faster than a MISS on average (${ratio}x)" faster "${h_mean:-1}" "${m_mean:-0}"

  step 3.5 "A write invalidates the cache"
  field WHAT "POST inserts into PostgreSQL and then deletes the Redis key, so the next read cannot return stale data."
  field WEB "Incidents tab, press Refresh: the new incident is listed and the Total card went up by one."
  gate
  terminal
  read_show prod
  local total_before=$RD_TOTAL
  post_show prod "Cache invalidation demo $(date +%H:%M:%S)" LOW
  local code=$PO_CODE
  redis_show exists incidents
  local gone=$LAST
  read_show prod
  local miss_cache=$RD_CACHE miss_total=$RD_TOTAL
  read_show prod
  local hit_cache=$RD_CACHE
  result
  check "the write was accepted" 201 "$code"
  check "the key was deleted by the write" 0 "$gone"
  check "next read is a MISS" MISS "$miss_cache"
  check "it already contains the new incident (total + 1)" $((total_before + 1)) "$miss_total"
  check "the read after that is a HIT again" HIT "$hit_cache"

  step 3.6 "The same cache, seen from the page"
  field WHAT "The page reads through the same Redis key. Redis counts hits and misses itself (INFO stats), so the terminal can confirm what the page did."
  field WEB "Open $(url_of prod)/#/system and press 'Read now' twice. The Read log shows 'PostgreSQL' first, then 'Redis cache', each with its time. Overview > Data source shows the last read."
  if [ "$AUTO" -eq 1 ]; then
    note "Skipped in --auto mode: this step needs someone clicking in the page."
    SKIP=$((SKIP + 1))
    return 0
  fi
  gate "ENTER to empty the cache and start counting"
  terminal
  redis_show del incidents
  local h0 m0 h1 m1
  h0=$(redis_stat keyspace_hits); m0=$(redis_stat keyspace_misses)
  trace "docker compose -f docker-compose.prod.yml --env-file .env.prod exec -T cache redis-cli info stats   (keyspace_hits, keyspace_misses)"
  printf '     keyspace_hits=%s   keyspace_misses=%s\n' "${h0:-0}" "${m0:-0}"
  gate "Press 'Read now' twice in the page, then ENTER"
  h1=$(redis_stat keyspace_hits); m1=$(redis_stat keyspace_misses)
  printf '     keyspace_hits=%s   keyspace_misses=%s\n' "${h1:-0}" "${m1:-0}"
  result
  local dh=$(( ${h1:-0} - ${h0:-0} )) dm=$(( ${m1:-0} - ${m0:-0} ))
  if [ "$dh" -ge 1 ] && [ "$dm" -ge 1 ]; then
    pass "Redis saw the page's reads: +$dm miss, +$dh hit"
  else
    note "No reads from the page were detected (hits +$dh, misses +$dm): step not counted."
    SKIP=$((SKIP + 1))
  fi
}

part_failures() {
  section 4 "FAILURES AND RECOVERY (PROD)"

  step 4.1 "Redis goes down"
  field WHAT "The cache is an optimisation, not a requirement: with Redis down the app keeps working from PostgreSQL and reports itself as 'degraded' (HTTP 200)."
  field WEB "The pill turns yellow: 'Cache unavailable (degraded)'. System tab: the Redis card reads 'Unavailable' and a 'Down' event appears. A toast says 'Redis became unavailable'. Overview keeps working."
  gate
  terminal
  CACHE_DOWN=1
  run_quiet make kill-cache
  await_state prod cache down
  sync_web
  status_show prod
  local code=$ST_CODE body=$ST_BODY
  read_show prod
  log_line prod cache_unavailable
  result
  check "/status HTTP code (the app is still usable)" 200 "$code"
  check "overall status" degraded "$(top "$body")"
  check "cache reported as" down "$(svc "$body" cache)"
  check "web container stays healthy" healthy "$(health_of prod web)"
  check "reads keep working (HTTP code)" 200 "$RD_CODE"
  check "reads are served by PostgreSQL" MISS "$RD_CACHE"
  check_has "the outage is in the server log" "$LAST" cache_unavailable

  step 4.2 "Redis comes back"
  field WHAT "ioredis reconnects by itself. Redis restarts empty, so the first read is a MISS and no stale data can appear."
  field WEB "The pill turns green and a toast says 'Redis is back online'. The 'Recovered' event is added to the log."
  gate
  terminal
  run_quiet make start-cache
  CACHE_DOWN=0
  await_state prod cache up
  sync_web
  status_show prod
  code=$ST_CODE; body=$ST_BODY
  read_show prod
  local first=$RD_CACHE
  read_show prod
  local second=$RD_CACHE
  log_line prod cache_available
  result
  check "/status HTTP code" 200 "$code"
  check "overall status" ok "$(top "$body")"
  check "cache reported as" up "$(svc "$body" cache)"
  check "first read after the restart is a MISS (empty cache)" MISS "$first"
  check "second read is a HIT" HIT "$second"
  check_has "the recovery is in the server log" "$LAST" cache_available

  step 4.3 "PostgreSQL goes down"
  field WHAT "Without the database the app cannot work: /status answers 503. Reads may still be served by Redis until the key expires, but writes fail cleanly."
  field WEB "The pill turns red: 'Database unavailable' and a toast says 'PostgreSQL became unavailable'. Press N and try to create an incident: the dialog says the database is unavailable."
  gate
  terminal
  note "First, one read to make sure the cache holds the list."
  read_show prod
  DB_PROD_DOWN=1
  run_quiet make kill-db ENV=prod
  await_state prod database down
  sync_web
  status_show prod
  code=$ST_CODE; body=$ST_BODY
  read_show prod
  local rd_code=$RD_CODE rd_cache=$RD_CACHE
  post_show prod "Must fail while the database is down" LOW
  result
  check "/status HTTP code" 503 "$code"
  check "database reported as" down "$(svc "$body" database)"
  check "web container stays healthy" healthy "$(health_of prod web)"
  if [ "$rd_code" = 200 ] && [ "$rd_cache" = HIT ]; then
    pass "Redis still serves the last list while PostgreSQL is down"
  else
    note "The cached list had already expired, so the read could not be served (HTTP $rd_code)."
  fi
  check "a write is rejected with 503" 503 "$PO_CODE"

  step 4.4 "PostgreSQL comes back"
  field WHAT "The connection pool reconnects by itself. No restart of the web container is needed."
  field WEB "The pill turns green, a toast says 'PostgreSQL is back online', and the page reloads its data automatically."
  gate
  terminal
  run_quiet make start-db ENV=prod
  DB_PROD_DOWN=0
  await_state prod database up
  sync_web
  status_show prod
  code=$ST_CODE; body=$ST_BODY
  read_show prod
  result
  check "/status HTTP code" 200 "$code"
  check "overall status" ok "$(top "$body")"
  check "reads work again (HTTP code)" 200 "$RD_CODE"
}

part_security() {
  section 5 "SECURITY AND ISOLATION"
  local pair e s ports ip

  step 5.1 "Only the web service is published"
  field WHAT "Compose publishes the web port on 127.0.0.1 only. PostgreSQL and Redis have no host port: they are reachable only inside the internal network."
  field WEB "The page itself is served on 127.0.0.1. Nothing else can be reached from outside."
  gate
  terminal
  trace "docker port <container>   (for each service of each environment)"
  local web_dev web_prod db_dev db_prod cache_prod
  web_dev=$(published_ports dev web);   db_dev=$(published_ports dev db)
  web_prod=$(published_ports prod web); db_prod=$(published_ports prod db)
  cache_prod=$(published_ports prod cache)
  printf '     %-5s %-6s %s\n' dev web "${web_dev:-none}" dev db "${db_dev:-none (internal only)}" \
    prod web "${web_prod:-none}" prod db "${db_prod:-none (internal only)}" prod cache "${cache_prod:-none (internal only)}"
  result
  check "dev web is published on localhost only" "127.0.0.1:$(env_value dev WEB_PORT)" "$web_dev"
  check "dev db publishes no port" "" "$db_dev"
  check "prod web is published on localhost only" "127.0.0.1:$(env_value prod WEB_PORT)" "$web_prod"
  check "prod db publishes no port" "" "$db_prod"
  check "prod cache publishes no port" "" "$cache_prod"

  step 5.2 "The backend network has no way out"
  field WHAT "db and cache sit on a network declared 'internal': Docker gives it no route to the internet, so even a compromised container could not call out."
  field WEB "Nothing changes in the page: the web service is on both networks, so it still reaches the database."
  gate
  terminal
  for e in dev prod; do
    trace "docker network inspect $(project_of "$e")_backend -f '{{.Internal}}'"
    LAST=$(docker network inspect "$(project_of "$e")_backend" -f '{{.Internal}}' 2>&1); emit "$LAST"
    check "$e backend network is internal" true "$LAST"
  done
  for pair in "dev db" "prod db" "prod cache"; do
    read -r e s <<<"$pair"
    trace "docker compose -f docker-compose.$e.yml --env-file .env.$e exec -T $s wget -q -T 3 -O /dev/null http://1.1.1.1"
    if compose "$e" exec -T "$s" wget -q -T 3 -O /dev/null http://1.1.1.1 >/dev/null 2>&1; then
      printf '     %sreached the internet%s\n' "$RED" "$RESET"; ip=1
    else
      printf '     blocked (no route to the internet)\n'; ip=0
    fi
    check "$e $s cannot reach the internet" 0 "$ip"
  done

  step 5.3 "Unprivileged and hardened containers"
  field WHAT "No container runs as root. Each one has a read-only filesystem, drops every Linux capability and cannot gain privileges. Prod also caps the memory."
  field WEB "Nothing changes in the page: this is hardening of the runtime."
  gate
  terminal
  trace "docker compose ... exec -T <service> id -u   and   docker inspect -f '{{.HostConfig.ReadonlyRootfs}} {{.HostConfig.CapDrop}} {{.HostConfig.SecurityOpt}} {{.HostConfig.Memory}}'"
  local root=0 rw=0 caps=0 nnp=0 uid info ro cd so mem total=0 limits=0
  for pair in "dev web" "dev db" "prod web" "prod db" "prod cache"; do
    read -r e s <<<"$pair"
    uid=$(compose "$e" exec -T "$s" id -u 2>/dev/null)
    info=$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}}|{{.HostConfig.CapDrop}}|{{.HostConfig.SecurityOpt}}|{{.HostConfig.Memory}}' "$(cid "$e" "$s")" 2>/dev/null)
    IFS='|' read -r ro cd so mem <<<"$info"
    total=$((total + 1))
    [ "$uid" = 0 ] && root=$((root + 1))
    [ "$ro" = true ] || rw=$((rw + 1))
    case $cd in *ALL*) ;; *) caps=$((caps + 1)) ;; esac
    case $so in *no-new-privileges*) ;; *) nnp=$((nnp + 1)) ;; esac
    if [ "$e" = prod ]; then
      [ "${mem:-0}" -gt 0 ] 2>/dev/null && limits=$((limits + 1))
      printf '     %-5s %-6s uid %-5s read-only %-5s cap_drop %s  mem %s MiB\n' "$e" "$s" "$uid" "$ro" "$cd" "$(( ${mem:-0} / 1048576 ))"
    else
      printf '     %-5s %-6s uid %-5s read-only %-5s cap_drop %s\n' "$e" "$s" "$uid" "$ro" "$cd"
    fi
  done
  result
  check "containers running as root (of $total)" 0 "$root"
  check "containers with a writable root filesystem" 0 "$rw"
  check "containers that keep some capability" 0 "$caps"
  check "containers without no-new-privileges" 0 "$nnp"
  check "prod containers with a memory limit (of 3)" 3 "$limits"

  step 5.4 "Secrets stay out of the code"
  field WHAT "Passwords live only in the .env files: mode 600, ignored by Git, and absent from the compose files, which only reference variables."
  field WEB "Nothing changes in the page."
  gate
  terminal
  for e in dev prod; do
    trace "stat -c %a .env.$e"
    LAST=$(mode_of ".env.$e"); emit "$LAST"
    check ".env.$e permissions" 600 "$LAST"
  done
  if [ -d .git ]; then
    trace "git ls-files .env.dev .env.prod | wc -l"
    LAST=$(git ls-files .env.dev .env.prod | wc -l | tr -d ' '); emit "$LAST"
    check "real .env files tracked by Git" 0 "$LAST"
  fi
  trace "grep -cE 'PASSWORD: *[^\$[:space:]]' docker-compose.dev.yml docker-compose.prod.yml"
  LAST=$(cat docker-compose.dev.yml docker-compose.prod.yml | grep -cE 'PASSWORD: *[^$[:space:]]')
  emit "$LAST"
  result
  check "literal passwords in the compose files" 0 "$LAST"
}

part_summary() {
  section 6 "SUMMARY"
  local elapsed=$((SECONDS - START_TIME))
  printf '\n'
  printf '   %s%s passed%s   ' "$GREEN" "$PASS" "$RESET"
  if [ "$FAIL" -gt 0 ]; then printf '%s%s failed%s   ' "$RED" "$FAIL" "$RESET"; else printf '%s failed   ' "$FAIL"; fi
  printf '%s not counted   time %sm %ss\n' "$SKIP" $((elapsed / 60)) $((elapsed % 60))
  if [ "$FAIL" -gt 0 ]; then
    printf '\n   %sChecks that failed:%s\n%s' "$RED" "$RESET" "$FAILED_LIST"
  fi
  printf '\n'
  field STATE "Both environments are running again: dev $(url_of dev), prod $(url_of prod)."
  if [ -f docs/evidence/test-results.txt ]; then
    field FULL "The complete suite is make test. Last recorded run: $(tail -n 1 docs/evidence/test-results.txt) (docs/evidence/test-results.txt)."
  else
    field FULL "The complete suite is make test."
  fi
  printf '\n'
}

# ======================================================================== MAIN

part_intro
part_environments
part_persistence
part_cache
part_failures
part_security
part_summary
exit $((FAIL > 0))
