#!/usr/bin/env bash
# Guided demonstration of the practice. One ENTER per step. Every command is
# printed exactly as it runs, and every check is computed from real values.
#
#   make demo                               core path (sized for the 10 minute talk)
#   bash scripts/demo.sh --full             every step
#   bash scripts/demo.sh --list             list the steps and exit
#   bash scripts/demo.sh --map              requirement -> file:line (no Docker needed)
#   bash scripts/demo.sh --from N --to M    run steps N to M of the selection
#   bash scripts/demo.sh --auto             no pauses
#
# The demo stops PostgreSQL and Redis on purpose. A trap starts again whatever
# it stopped if the script ends early (Ctrl+C, error, or q at a prompt).

set -u
[ -n "${DEMO_LIB:-}" ] || cd "$(dirname "$0")/.." || exit 2

AUTO=0
FULL=0
LIST=0
MAP=0
FROM=1
TO=9999

STATE_TIMEOUT_S=60   # how long to wait for /status to report a state change
WEB_SYNC_S=4         # the page polls /status every 3 s: wait one full cycle
SAMPLES=10           # requests per group in the speed measurement

PASS=0
FAIL=0
SKIP=0
FAILED=''
LAST=''              # output of the last command run by show
RC=0                 # exit code of the last command run by show
DB_DEV_DOWN=0
DB_PROD_DOWN=0
CACHE_DOWN=0
TMP=''
START_TIME=$SECONDS

# id|set|title|action|look   (set: core or full; @DEV@ and @PROD@ are replaced by the page URLs)
STEPS=(
  "makefile|core|Automation: the Makefile|List the Makefile targets and show, without running them, what make down and make clean would execute.|"
  "up|core|Build and start both environments|Build the images and start dev and prod (make build, make up-dev, make up-prod). Safe to repeat: the data lives in volumes.|Open @DEV@ (dev) and @PROD@ (prod) in the browser."
  "envs|core|Two environments, two compose files|Show the services of each environment, their health, and the lines that differ between the two compose files.|"
  "secrets|core|Secrets and configuration files|Show where the passwords live and prove they are not in the repository.|"
  "network|core|Network isolation and published ports|Show the published ports and the networks, then try to reach the internet from the database and the cache.|"
  "healthchecks|core|Healthchecks in every container|Show the healthcheck of every container and its current state.|"
  "hardening|core|Unprivileged, read-only containers|Show user, filesystem, capabilities and memory limit of every container.|"
  "status|core|The /status endpoint and the page|Request /status in dev and prod.|System tab: the Redis card reads 'Disabled' in dev and 'Operational' in prod. The header badge reads Development or Production. The top-right pill reads 'All systems operational'."
  "api|core|API queries: limits and filters|Query the prod API with different limits and filters, then list the Redis keys.|Incidents tab (prod): choose '10 incidents', then Priority 'Critical'. 'Last query source' reads PostgreSQL the first time and Redis cache when the same query is repeated."
  "cache_config|full|Redis connection test and settings|Run the Redis connection test and show the cache settings.|"
  "cache|core|Redis cache: MISS, HIT and invalidation|Empty the cache and read twice, then create an incident and read again.|Incidents tab (prod): press Refresh after the incident is created. It is the first row."
  "cache_ui|core|The cache seen from the page|Count Redis hits and misses while you press Read now in the page.|System tab (prod): press 'Read now' twice. The Read log lists PostgreSQL first, then Redis cache."
  "cache_speed|full|Measured speed-up|Measure 10 cold reads (key deleted before each) and 10 warm reads.|"
  "persistence|full|Data persistence in dev|Test the database connection, insert an incident, remove the database container and create it again.|Incidents tab (dev): press Refresh after the insert; the incident is the first row. While the container is removed the pill reads 'Database unavailable'."
  "init|full|Automatic initialization on an empty volume|Delete the dev data volume and start dev again: init.sql runs by itself on the empty volume.|Overview (dev): Total incidents goes back to 50,006."
  "prod_persistence|core|Data persistence in production|Insert an incident in prod, remove the prod database container, create it again and read the incident back from PostgreSQL.|Incidents tab (prod): the pill turns red while the container is removed and green again after it returns."
  "redis_outage|core|Redis outage and recovery|Stop Redis, check that the app keeps working, then start it again.|Prod page: the pill reads 'Cache unavailable (degraded)' and a toast says 'Redis became unavailable'. After the restart: 'All systems operational' and 'Redis is back online'."
  "db_outage|core|Database outage and recovery|Stop PostgreSQL in prod, check what still works, then start it again.|Prod page: the pill reads 'Database unavailable' and a toast says 'PostgreSQL became unavailable'. Press N and try to create an incident: the dialog says the database is unavailable. After the restart: 'PostgreSQL is back online'."
  "make_down|full|Stop and start again: data kept|Run make down (containers and networks removed, volumes kept), then make up-prod and make up-dev, and count the incidents again.|"
)

# section|requirement|file|pattern|mode|why   (mode: F fixed string, R regular expression)
MAP_ROWS=(
  "Web application|Framework (Express)|package.json|\"express\"|F|"
  "Web application|Connects to the database|src/db.js|new Pool(|F|"
  "Web application|Connects to Redis (prod only)|src/cache.js|new Redis(|F|"
  "Web application|Page shows the state of both services|src/public/index.html|id=\"health-pill\"|F|"
  "Web application|Page refreshes the state by itself|src/public/app.js|const STATUS_INTERVAL_MS|F|"
  "Web application|/status endpoint|src/routes.js|router.get('/status'|F|"
  "Web application|Health of the dependencies in /status|src/routes.js|async function statusHandler|F|"
  "Web application|Degraded vs down|src/routes.js|const degraded|F|503 only when the database is down; Redis down still answers 200 'degraded'."
  "Database|PostgreSQL|docker-compose.prod.yml|image: postgres:18-alpine|F|"
  "Database|Persistence with a named volume|docker-compose.prod.yml|db-data:/var/lib/postgresql|F|The volume outlives the container; removing the container does not remove the data."
  "Database|Connection test command|Makefile|^test-db:|R|"
  "Database|Automatic initialization|docker-compose.prod.yml|target: /docker-entrypoint-initdb.d/init.sql|F|init.sql runs only while the volume is empty."
  "Database|Schema and seed data|db/init.sql|CREATE TABLE incidents|F|"
  "Cache|Redis, production only|docker-compose.prod.yml|image: redis:8-alpine|F|The dev compose file has no cache service."
  "Cache|Cache-aside read|src/routes.js|async function readThrough|F|"
  "Cache|Use made visible (X-Cache header)|src/routes.js|res.set('X-Cache'|F|"
  "Cache|Redis keeps nothing on disk|docker-compose.prod.yml|--save \"\" --appendonly no|F|It is only a cache; a restart leaves it empty, so it cannot serve stale data."
  "Deployment|Dev compose file|docker-compose.dev.yml|^name:|R|"
  "Deployment|Prod compose file|docker-compose.prod.yml|^name:|R|"
  "Deployment|One .env file per environment|Makefile|^\\.env\\.dev \\.env\\.prod:|R|"
  "Deployment|Internal network|docker-compose.prod.yml|internal: true|F|db and cache have no route to the internet."
  "Deployment|Only the web service publishes a port|docker-compose.prod.yml|127.0.0.1:\${WEB_PORT}:3000|F|Bound to 127.0.0.1: other machines cannot reach it."
  "Deployment|Healthcheck: web|Dockerfile|^HEALTHCHECK|R|It calls /live only, so a database outage does not mark the web container unhealthy."
  "Deployment|Healthcheck: database|docker-compose.prod.yml|pg_isready|F|-h 127.0.0.1 forces a TCP check, which fails until init.sql has loaded."
  "Deployment|Healthcheck: cache|docker-compose.prod.yml|redis-cli -h 127.0.0.1 ping|F|"
  "Security|No credentials in the YAML|docker-compose.prod.yml|POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}|F|The compose files only reference variables."
  "Security|Secrets read from the environment|src/config.js|password: text('POSTGRES_PASSWORD')|F|"
  "Security|.env files ignored by Git|.gitignore|.env.*|F|The real secrets never reach the repository."
  "Security|Restrictive file permissions|Makefile|umask 077|F|The generated .env files are created with mode 600."
  "Security|init.sql mounted read-only|docker-compose.prod.yml|create_host_path: false|F|"
  "Security|No capabilities, no privilege escalation|docker-compose.prod.yml|cap_drop:|F|"
  "Security|Web runs as an unprivileged user|Dockerfile|^USER node|R|"
  "Security|Restart policy in prod|docker-compose.prod.yml|restart: unless-stopped|F|Restarts after a crash or a reboot, not after a manual stop."
  "Automation|make build|Makefile|^build:|R|"
  "Automation|make up-dev|Makefile|^up-dev:|R|"
  "Automation|make up-prod|Makefile|^up-prod:|R|"
  "Automation|make down|Makefile|^down:|R|"
  "Automation|make clean|Makefile|^clean:|R|"
  "API|Limits and filters|src/routes.js|function sanitizeFilters|F|"
  "API|Maximum limit|src/routes.js|const MAX_LIMIT|F|"
  "API|One cache key per query|src/routes.js|function getCacheKey|F|"
  "API|A write invalidates the cache|src/routes.js|cache.delPattern|F|No read can return stale data after a write."
)

# ======================================================================= terminal

setup_terminal() {
  W=$(tput cols 2>/dev/null || echo 80)
  [ "$W" -gt 100 ] && W=100
  [ "$W" -lt 60 ] && W=60
  if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'
    YELLOW=$'\033[33m'; RESET=$'\033[0m'
  else
    BOLD=''; DIM=''; RED=''; GREEN=''; YELLOW=''; RESET=''
  fi
}

die() { printf '%s\n' "$*" >&2; exit 2; }

# make without the "Entering/Leaving directory" lines, which would corrupt parsed output.
make() { command make --no-print-directory "$@"; }

hr() { printf '%*s\n' "$W" '' | sed 's/ /-/g'; }

# label <name> <text>: text wrapped under a fixed-width label.
label() {
  printf '%s\n' "$2" | fold -s -w $((W - 10)) |
    awk -v l="$1" 'NR == 1 {printf "  %-6s %s\n", l, $0; next} {printf "         %s\n", $0}'
}

note() { printf '  %s%s%s\n' "$DIM" "$*" "$RESET"; }

# gate [message]: waits for ENTER (q quits). Does nothing in --auto mode.
gate() {
  [ "$AUTO" -eq 1 ] && return 0
  local answer
  printf '\n  %s> ENTER %s  (q to quit)%s ' "$YELLOW" "${1:-to run}" "$RESET"
  read -r answer
  if [ "$answer" = q ]; then printf '\n'; exit 130; fi
  return 0
}

phase() { gate "$1"; }

pass() { printf '  %s✔%s %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS + 1)); }
fail() {
  printf '  %s✖%s %s\n' "$RED" "$RESET" "$1"
  FAIL=$((FAIL + 1))
  FAILED="${FAILED}  - $1"$'\n'
}
check()     { if [ "$3" = "$2" ]; then pass "$1 [$3]"; else fail "$1 (expected '$2', got '$3')"; fi; }
check_has() { if printf '%s' "$2" | grep -qF -- "$3"; then pass "$1"; else fail "$1 (missing '$3')"; fi; }
check_ok()  { local desc=$1; shift; if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi; }

# show <command> [hint]: prints the command, runs it and indents its output.
# The text printed is the text executed, so it can be pasted into a terminal.
show() {
  printf '  %s$ %s%s\n' "$DIM" "$1" "$RESET"
  [ -n "${2:-}" ] && note "(takes $2)"
  LAST=$(eval "$1" 2>&1)
  RC=$?
  if [ -n "$LAST" ]; then printf '%s\n' "$LAST" | sed 's/^/    /'; fi
  return 0
}

# quiet <command> [hint]: runs a long command, shows its last lines only on failure.
quiet() {
  printf '  %s$ %s%s\n' "$DIM" "$1" "$RESET"
  [ -n "${2:-}" ] && note "(takes $2)"
  if eval "$1" >"$TMP/quiet.log" 2>&1; then
    printf '    ok\n'
  else
    printf '    %sFAILED, last lines of the output:%s\n' "$RED" "$RESET"
    tail -n 12 "$TMP/quiet.log" | sed 's/^/    /'
    FAIL=$((FAIL + 1))
    FAILED="${FAILED}  - command failed: $1"$'\n'
  fi
}

# where <file> <pattern> [F]: file:line of the first match, read from the file at run time.
# A pattern that is not found counts as a failure, so a pointer can never go stale.
where() {
  local file=$1 pattern=$2 mode=${3:-R} hit flag=-n
  [ "$mode" = F ] && flag=-nF
  hit=$(grep "$flag" -m 1 -- "$pattern" "$file" 2>/dev/null)
  if [ -n "$hit" ]; then
    printf '  %swhere:%s  %s:%s\n' "$DIM" "$RESET" "$file" \
      "$(printf '%s' "$hit" | sed 's/^\([0-9]*\):[[:space:]]*/\1   /')"
  else
    printf '  where:  %s  (pattern not found: %s)\n' "$file" "$pattern"
    fail "pointer not found in $file: $pattern"
  fi
}

# ===================================================================== environments

compose()    { local e=$1; shift; docker compose -f "docker-compose.$e.yml" --env-file ".env.$e" "$@"; }
dc()         { printf 'docker compose -f docker-compose.%s.yml --env-file .env.%s' "$1" "$1"; }
project_of() { sed -n 's/^name: *//p' "docker-compose.$1.yml" | head -n 1; }
cname()      { printf '%s-%s-1' "$(project_of "$1")" "$2"; }
env_value()  { sed -n "s/^$2=//p" ".env.$1" | head -n 1; }
url_of()     { printf 'http://127.0.0.1:%s' "$(env_value "$1" WEB_PORT)"; }
cid()        { compose "$1" ps -q "$2"; }
mode_of()    { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
health_of() {
  local id
  id=$(cid "$1" "$2")
  [ -n "$id" ] || { echo missing; return; }
  docker inspect -f '{{.State.Health.Status}}' "$id" 2>/dev/null || echo missing
}

# Command builders. The container-side variables stay unexpanded inside single
# quotes, so the text works when it is pasted into a terminal.
psql_cmd()  { printf "%s exec -T db sh -c 'psql -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -tAc \"%s\"'" "$(dc "$1")" "$2"; }
redis_cmd() { printf "%s exec -T cache sh -c 'REDISCLI_AUTH=\"\$REDIS_PASSWORD\" redis-cli %s'" "$(dc prod)" "$*"; }

in_range() { case $1 in ''|*[!0-9]*) return 1 ;; esac; [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]; }
faster()   { awk -v a="$1" -v b="$2" 'BEGIN {exit !(a < b)}'; }
stats()    { awk 'NF {s += $1; if (min == "" || $1 < min) min = $1; if ($1 > max) max = $1; n++}
                  END {if (n) printf "%.2f %.2f %.2f", s / n, min, max}'; }

# ========================================================================= HTTP

# Values read from the JSON of /status.
top() { printf '%s' "$1" | grep -o '"status":"[a-z]*"' | head -n 1 | cut -d'"' -f4; }
svc() { printf '%s' "$1" | grep -o "\"$2\":{[^}]*}" | grep -o '"status":"[a-z]*"' | cut -d'"' -f4; }

# fetch_status <env>: sets ST_CODE and ST_BODY quietly (a 503 still carries the JSON).
fetch_status() {
  local out
  out=$(curl -s -m 10 -w '\n%{http_code}' "$(url_of "$1")/status" 2>/dev/null) || true
  ST_CODE=${out##*$'\n'}
  ST_BODY=${out%$'\n'*}
}

# status_show <env>: shows GET /status and sets ST_CODE and ST_BODY from it.
status_show() {
  show "curl -s -m 10 -w '\nHTTP %{http_code}\n' $(url_of "$1")/status"
  ST_CODE=$(printf '%s\n' "$LAST" | tail -n 1 | sed 's/^HTTP //')
  ST_BODY=$(printf '%s\n' "$LAST" | sed '$d')
}

# headers_show <url>: shows the status line and the cache headers of a GET.
# Sets RD_CODE, RD_CACHE and RD_MS.
headers_show() {
  show "curl -s -D - -o /dev/null \"$1\" | grep -iE '^(HTTP|x-cache|x-response-time)'"
  RD_CODE=$(printf '%s\n' "$LAST" | sed -n 's/^HTTP\/[0-9.]* \([0-9]*\).*/\1/p' | head -n 1)
  RD_CACHE=$(printf '%s\n' "$LAST" | tr -d '\r' | awk -F': ' 'tolower($1) == "x-cache" {print $2}')
  RD_MS=$(printf '%s\n' "$LAST" | tr -d '\r' | awk -F': ' 'tolower($1) == "x-response-time" {print $2}' | sed 's/ms//')
  : "$RD_MS"
}

# total_show <base url>: shows the total number of incidents and sets TOTAL.
total_show() {
  show "curl -s \"$1/api/incidents\" | grep -o '\"total\":[0-9]*'"
  TOTAL=${LAST#*:}
}

# post_show <env> <title> <priority>: shows a POST and sets PO_CODE and PO_ID.
post_show() {
  show "curl -s -m 10 -w '\nHTTP %{http_code}\n' -X POST $(url_of "$1")/api/incidents -H 'Content-Type: application/json' -d '{\"title\":\"$2\",\"system_name\":\"demo-host\",\"priority\":\"$3\"}'"
  PO_CODE=$(printf '%s\n' "$LAST" | tail -n 1 | sed 's/^HTTP //')
  PO_ID=$(printf '%s\n' "$LAST" | grep -o '"id":[0-9]*' | head -n 1 | cut -d: -f2)
}

# keys_show: lists the incident keys stored in Redis and sets KEYS (their number).
keys_show() {
  show "$(redis_cmd --scan --pattern '"incidents*"')"
  KEYS=$(printf '%s\n' "$LAST" | grep -c .)
  [ -n "$LAST" ] || note "(no keys)"
}

# await_state <env> <service> <state>: polls /status until it reports the state.
await_state() {
  local e=$1 service=$2 want=$3 t0=$SECONDS
  printf '  %swaiting for /status: %s=%s%s' "$DIM" "$service" "$want" "$RESET"
  while [ $((SECONDS - t0)) -lt "$STATE_TIMEOUT_S" ]; do
    fetch_status "$e"
    if [ "$(svc "$ST_BODY" "$service")" = "$want" ]; then
      printf '%s  (%s s)%s\n' "$DIM" $((SECONDS - t0)) "$RESET"
      return 0
    fi
    sleep 1
  done
  printf '  %stimed out%s\n' "$RED" "$RESET"
  return 1
}

# sync_web: lets the page poll /status at least once after a change.
sync_web() {
  printf '  %swaiting for the page to catch up (it polls every 3 s)%s\n' "$DIM" "$RESET"
  sleep "$WEB_SYNC_S"
}

# ============================================================================ steps

step_makefile() {
  show "make help"
  local help=$LAST
  show "make -n down"
  show "make -n clean"
  local listed
  listed=$(printf '%s\n' "$help" | grep -cE '^  (build|up-dev|up-prod|down) ')
  check "make help lists build, up-dev, up-prod and down (of 4)" 4 "$listed"
  where Makefile '^build:'
  where Makefile '^up-dev:'
  where Makefile '^up-prod:'
  where Makefile '^down:'
  where Makefile '^clean:'
  label why: "down removes containers and networks but keeps the data volumes. clean also removes the volumes and the images."
}

step_up() {
  quiet "make build" "about 5 s when cached"
  show "docker image ls --filter 'reference=bugtracker-*'"
  quiet "make up-dev" "about 15 s"
  quiet "make up-prod" "about 20 s"
  local bad=0 pair e s
  for pair in "dev web" "dev db" "prod web" "prod db" "prod cache"; do
    read -r e s <<<"$pair"
    [ "$(health_of "$e" "$s")" = healthy ] || bad=$((bad + 1))
  done
  check "containers that are not healthy (of 5)" 0 "$bad"
  where Makefile 'up -d --build --wait' F
  label why: "up --wait returns only when every container is healthy, so the page is ready when the command ends."
}

step_envs() {
  show "$(dc dev) config --services"
  local dev_services=$LAST
  show "$(dc prod) config --services"
  local prod_services=$LAST
  show "$(dc dev) ps --format 'table {{.Service}}\t{{.Status}}\t{{.Ports}}'"
  show "$(dc prod) ps --format 'table {{.Service}}\t{{.Status}}\t{{.Ports}}'"
  show "grep -nE 'restart:|memory:' docker-compose.prod.yml"
  show "grep -cE 'restart:|memory:' docker-compose.dev.yml"
  local dev_extras=$LAST
  check "dev services" "db web" "$(printf '%s\n' "$dev_services" | sort | paste -sd' ' -)"
  check "prod services (adds the cache)" "cache db web" "$(printf '%s\n' "$prod_services" | sort | paste -sd' ' -)"
  check "dev restart and memory settings" 0 "$dev_extras"
  where docker-compose.dev.yml '^name:'
  where docker-compose.prod.yml '^name:'
  where docker-compose.prod.yml '^  cache:'
  label why: "Two files because the environments differ: prod adds Redis, restarts after a crash and caps memory. The rest is identical, so what runs in dev is what runs in prod."
}

step_secrets() {
  show "ls -l .env.dev .env.prod"
  show "grep -E '^[A-Z_]+=' .env.prod | sed 's/=.*/=<hidden>/'"
  show "git check-ignore -v .env.dev .env.prod"
  show "git ls-files .env.dev .env.prod | wc -l"
  local tracked=$LAST
  show "grep -n PASSWORD docker-compose.prod.yml"
  show "grep -cE 'PASSWORD: *[^\$[:space:]]' docker-compose.dev.yml docker-compose.prod.yml"
  local literals
  literals=$(printf '%s\n' "$LAST" | awk -F: '{s += $2} END {print s + 0}')
  check ".env.dev permissions" 600 "$(mode_of .env.dev)"
  check ".env.prod permissions" 600 "$(mode_of .env.prod)"
  check "real .env files tracked by Git" 0 "$tracked"
  check "literal passwords in the compose files" 0 "$literals"
  where .gitignore '.env.*' F
  where Makefile 'umask 077' F
  # shellcheck disable=SC2016  # the pattern is matched literally, not expanded
  where docker-compose.prod.yml 'POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}' F
  where docker-compose.prod.yml 'target: /docker-entrypoint-initdb.d/init.sql' F
  label why: "Passwords exist only in .env.* (mode 600, ignored by Git). Compose reads them as variables, so the repository never holds a secret. init.sql is mounted read-only."
}

step_network() {
  local e s ports expected
  for pair in "dev web" "dev db" "prod web" "prod db" "prod cache"; do
    read -r e s <<<"$pair"
    show "docker port $(cname "$e" "$s")"
    [ -n "$LAST" ] || note "(no published ports)"
    ports=$(printf '%s\n' "$LAST" | awk '{print $3}' | sort -u | paste -sd, -)
    expected=''
    [ "$s" = web ] && expected="127.0.0.1:$(env_value "$e" WEB_PORT)"
    check "$e $s published ports" "$expected" "$ports"
  done
  for e in dev prod; do
    show "docker network inspect $(project_of "$e")_backend -f '{{.Internal}} {{range .Containers}}{{.Name}} {{end}}'"
    check "$e backend network is internal" true "${LAST%% *}"
    show "docker network inspect $(project_of "$e")_frontend -f '{{range .Containers}}{{.Name}} {{end}}'"
    check "$e frontend network holds only the web service" "$(cname "$e" web)" "$(printf '%s' "$LAST" | sed 's/ *$//')"
  done
  for pair in "dev db" "prod db" "prod cache"; do
    read -r e s <<<"$pair"
    show "$(dc "$e") exec -T $s wget -q -T 3 -O /dev/null http://1.1.1.1"
    if [ "$RC" -ne 0 ]; then pass "$e $s cannot reach the internet"; else fail "$e $s reached the internet"; fi
  done
  # shellcheck disable=SC2016  # the pattern is matched literally, not expanded
  where docker-compose.prod.yml 'internal: true' F
  # shellcheck disable=SC2016  # the pattern is matched literally, not expanded
  # shellcheck disable=SC2016  # the pattern is matched literally, not expanded
  where docker-compose.prod.yml '127.0.0.1:${WEB_PORT}:3000' F
  label why: "backend is internal: its containers have no route out. Only web is also on frontend and publishes a port, bound to 127.0.0.1."
}

step_healthchecks() {
  local pair e s n bad=0
  for pair in "dev web" "dev db" "prod web" "prod db" "prod cache"; do
    read -r e s <<<"$pair"
    n=$(cname "$e" "$s")
    show "docker inspect -f '{{.State.Health.Status}} {{.Config.Healthcheck.Test}}' $n"
    [ "${LAST%% *}" = healthy ] || bad=$((bad + 1))
  done
  check "containers that are not healthy (of 5)" 0 "$bad"
  where Dockerfile '^HEALTHCHECK'
  where docker-compose.dev.yml 'pg_isready' F
  where docker-compose.prod.yml 'redis-cli -h 127.0.0.1 ping' F
  where src/routes.js "router.get('/live'" F
  label why: "web asks /live, which never touches the database. db runs pg_isready over TCP (-h 127.0.0.1), which fails until init.sql has loaded. cache sends PING with its password."
}

step_hardening() {
  local pair e s n uid line root=0 rw=0 caps=0 nnp=0 ro cd so mem
  for pair in "dev web" "dev db" "prod web" "prod db" "prod cache"; do
    read -r e s <<<"$pair"
    n=$(cname "$e" "$s")
    show "echo \"uid \$(docker exec $n id -u)  \$(docker inspect -f 'readonly={{.HostConfig.ReadonlyRootfs}} cap_drop={{.HostConfig.CapDrop}} security={{.HostConfig.SecurityOpt}} memory={{.HostConfig.Memory}}' $n)\""
    line=$LAST
    uid=$(printf '%s' "$line" | sed -n 's/^uid \([0-9]*\) .*/\1/p')
    ro=$(printf '%s' "$line" | sed -n 's/.*readonly=\([a-z]*\) .*/\1/p')
    cd=$(printf '%s' "$line" | sed -n 's/.*cap_drop=\(\[[^]]*\]\).*/\1/p')
    so=$(printf '%s' "$line" | sed -n 's/.*security=\(\[[^]]*\]\).*/\1/p')
    mem=$(printf '%s' "$line" | sed -n 's/.*memory=\([0-9]*\).*/\1/p')
    [ "$uid" = 0 ] && root=$((root + 1))
    [ "$ro" = true ] || rw=$((rw + 1))
    case $cd in *ALL*) ;; *) caps=$((caps + 1)) ;; esac
    case $so in *no-new-privileges*) ;; *) nnp=$((nnp + 1)) ;; esac
    [ "$e" = prod ] && { [ "${mem:-0}" -gt 0 ] || fail "$e $s has no memory limit"; }
  done
  check "containers running as root (of 5)" 0 "$root"
  check "containers with a writable root filesystem" 0 "$rw"
  check "containers that keep a capability" 0 "$caps"
  check "containers without no-new-privileges" 0 "$nnp"
  where Dockerfile '^USER node'
  where docker-compose.prod.yml 'cap_drop:' F
  where docker-compose.prod.yml 'no-new-privileges:true' F
  where docker-compose.prod.yml 'memory: 256M' F
  label why: "If someone got a shell inside a container: it is not root, it cannot write to its filesystem, it has no Linux capabilities and it cannot gain privileges."
}

step_status() {
  local dev_body dev_code
  status_show dev
  dev_body=$ST_BODY
  dev_code=$ST_CODE
  status_show prod
  check "dev HTTP code" 200 "$dev_code"
  check "dev overall status" ok "$(top "$dev_body")"
  check "dev database" up "$(svc "$dev_body" database)"
  check "dev cache" disabled "$(svc "$dev_body" cache)"
  check "prod HTTP code" 200 "$ST_CODE"
  check "prod overall status" ok "$(top "$ST_BODY")"
  check "prod database" up "$(svc "$ST_BODY" database)"
  check "prod cache" up "$(svc "$ST_BODY" cache)"
  where src/routes.js "router.get('/status'" F
  where src/routes.js 'async function statusHandler' F
  label why: "/status asks the database and Redis directly. 503 only when the database is down. With Redis down it answers 200 'degraded', because the app still works without it."
}

# api_query <query string> <view>: shows the cache headers of a request, then a
# view of its content. The content request is served by the cache (a HIT).
api_query() {
  local qs=$1 view=$2 url
  url="$(url_of prod)/api/incidents${qs:+?$qs}"
  headers_show "$url"
  Q_CACHE=$RD_CACHE
  case $view in
    rows)     show "curl -s \"$url\" | grep -o '\"system_name\"' | wc -l" ;;
    priority) show "curl -s \"$url\" | grep -o '\"priority\":\"[A-Z]*\"' | sort | uniq -c" ;;
    status)   show "curl -s \"$url\" | grep -o '\"status\":\"[A-Z_]*\"' | sort | uniq -c" ;;
    system)   show "curl -s \"$url\" | grep -o '\"system_name\":\"[^\"]*\"' | sort | uniq -c" ;;
  esac
  Q_VIEW=$LAST
}

step_api() {
  local first_cache repeat
  show "$(redis_cmd flushdb)"
  show "$(redis_cmd dbsize)"
  check "the cache starts empty (keys)" 0 "$LAST"

  api_query "limit=10" rows
  first_cache=$Q_CACHE
  check "limit=10 returns rows" 10 "$(printf '%s' "$Q_VIEW" | tr -d ' ')"
  check "limit=10 first read" MISS "$first_cache"
  api_query "limit=50" rows
  check "limit=50 returns rows" 50 "$(printf '%s' "$Q_VIEW" | tr -d ' ')"
  api_query "priority=CRITICAL&limit=10" priority
  check "priority=CRITICAL returns only critical incidents (rows and values)" "10 \"priority\":\"CRITICAL\"" "$(printf '%s' "$Q_VIEW" | sed 's/^ *//')"

  if [ "$FULL" -eq 1 ]; then
    api_query "status=OPEN&limit=10" status
    check "status=OPEN returns only open incidents" "10 \"status\":\"OPEN\"" "$(printf '%s' "$Q_VIEW" | sed 's/^ *//')"
    show "$(psql_cmd prod "SELECT system_name FROM incidents GROUP BY system_name ORDER BY count(*) DESC LIMIT 1")"
    local system=$LAST
    api_query "q=$system&limit=10" system
    local matched
    matched=$(printf '%s\n' "$Q_VIEW" | grep -c '"system_name"')
    check_ok "q=$system returns rows" test "$matched" -ge 1
    check "every row matches the search" 0 "$(printf '%s\n' "$Q_VIEW" | grep '"system_name"' | grep -cvF -- "$system")"
    api_query "limit=1000" rows
    check "limit=1000 is capped to the maximum" 100 "$(printf '%s' "$Q_VIEW" | tr -d ' ')"
  fi

  keys_show
  check_ok "each query is cached under its own key (keys)" test "$KEYS" -ge 3
  headers_show "$(url_of prod)/api/incidents?limit=10"
  repeat=$RD_CACHE
  check "the same query again" HIT "$repeat"
  where src/routes.js 'function sanitizeFilters' F
  where src/routes.js 'const MAX_LIMIT' F
  where src/routes.js 'function getCacheKey' F
  label why: "Each combination of filters has its own Redis key. limit is capped at 100 and invalid values fall back to the defaults."
}

step_cache_config() {
  show "make test-cache"
  check_has "Redis answers PONG" "$LAST" PONG
  show "$(redis_cmd config get maxmemory)"
  check "memory cap in bytes" 67108864 "$(printf '%s\n' "$LAST" | tail -n 1)"
  show "$(redis_cmd config get maxmemory-policy)"
  check "eviction policy" allkeys-lru "$(printf '%s\n' "$LAST" | tail -n 1)"
  show "$(redis_cmd config get save)"
  check "snapshots to disk (save)" "" "$(printf '%s\n' "$LAST" | tail -n 1)"
  show "$(redis_cmd config get appendonly)"
  check "append-only file" no "$(printf '%s\n' "$LAST" | tail -n 1)"
  where docker-compose.prod.yml '--maxmemory-policy allkeys-lru' F
  where Makefile '^test-cache:'
  label why: "Redis is only a cache: nothing is saved to disk, memory is capped at 64 MB and the least recently used keys are evicted first."
}

step_cache() {
  local ttl miss hit total_before total_after
  ttl=$(env_value prod CACHE_TTL_SECONDS)
  ttl=${ttl:-60}

  show "$(redis_cmd flushdb)"
  headers_show "$(url_of prod)/api/incidents"
  miss=$RD_CACHE
  show "$(redis_cmd ttl incidents)"
  local ttl_now=$LAST
  headers_show "$(url_of prod)/api/incidents"
  hit=$RD_CACHE
  check "first read" MISS "$miss"
  check_ok "the key expires by itself (TTL between 1 and $ttl s)" in_range "$ttl_now" 1 "$ttl"
  check "second read" HIT "$hit"

  phase "to create an incident"
  total_show "$(url_of prod)"
  total_before=$TOTAL
  post_show prod "Cache invalidation demo $(date +%H:%M:%S)" LOW
  check "the write was accepted" 201 "$PO_CODE"
  keys_show
  check "keys left in Redis after the write" 0 "$KEYS"
  headers_show "$(url_of prod)/api/incidents"
  check "first read after the write" MISS "$RD_CACHE"
  total_show "$(url_of prod)"
  total_after=$TOTAL
  check "the new incident is already counted (total + 1)" $((total_before + 1)) "$total_after"
  headers_show "$(url_of prod)/api/incidents"
  check "the read after that" HIT "$RD_CACHE"
  where src/routes.js 'async function readThrough' F
  where src/routes.js 'cache.delPattern' F
  label why: "Every write deletes the cached keys, so no read can return stale data. If Redis is down during a write, the keys expire by themselves after ${ttl} s."
}

step_cache_ui() {
  if [ "$AUTO" -eq 1 ]; then
    note "Skipped in --auto mode: this step needs someone clicking in the page."
    SKIP=$((SKIP + 1))
    return 0
  fi
  local counters h0 m0 h1 m1
  counters="$(redis_cmd info stats) | tr -d '\r' | grep -E '^keyspace_(hits|misses):'"
  show "$(redis_cmd flushdb)"
  show "$counters"
  h0=$(printf '%s\n' "$LAST" | sed -n 's/^keyspace_hits://p')
  m0=$(printf '%s\n' "$LAST" | sed -n 's/^keyspace_misses://p')
  phase "when 'Read now' has been pressed twice"
  show "$counters"
  h1=$(printf '%s\n' "$LAST" | sed -n 's/^keyspace_hits://p')
  m1=$(printf '%s\n' "$LAST" | sed -n 's/^keyspace_misses://p')
  local dh=$((${h1:-0} - ${h0:-0})) dm=$((${m1:-0} - ${m0:-0}))
  if [ "$dm" -ge 1 ] && [ "$dh" -ge 1 ]; then
    pass "Redis saw the page's reads: +$dm miss, +$dh hit"
  else
    note "No reads from the page were detected (hits +$dh, misses +$dm): not counted."
    SKIP=$((SKIP + 1))
  fi
  where src/public/app.js 'async function loadIncidents' F
  label why: "The page reads through the same Redis key as curl. Redis counts hits and misses itself, so the terminal can confirm what the page did."
}

step_cache_speed() {
  local url cold warm c_mean c_min c_max w_mean w_min w_max ratio cold_miss warm_hit
  url="$(url_of prod)/api/incidents"
  local one="curl -s -D - -o /dev/null \"$url\" | tr -d '\\r' | awk -F': ' 'tolower(\$1)==\"x-cache\" {c=\$2} tolower(\$1)==\"x-response-time\" {t=\$2} END {print c, t}'"
  show "for i in \$(seq $SAMPLES); do $(redis_cmd del incidents) >/dev/null; $one; done"
  cold=$LAST
  show "curl -s -o /dev/null \"$url\"; for i in \$(seq $SAMPLES); do $one; done"
  warm=$LAST
  cold_miss=$(printf '%s\n' "$cold" | grep -c '^MISS ')
  warm_hit=$(printf '%s\n' "$warm" | grep -c '^HIT ')
  read -r c_mean c_min c_max <<<"$(printf '%s\n' "$cold" | sed -n 's/^MISS \([0-9.]*\)ms.*/\1/p' | stats)"
  read -r w_mean w_min w_max <<<"$(printf '%s\n' "$warm" | sed -n 's/^HIT \([0-9.]*\)ms.*/\1/p' | stats)"
  ratio=$(awk -v a="${c_mean:-0}" -v b="${w_mean:-0}" 'BEGIN {if (b > 0) printf "%.1f", a / b; else print "n/a"}')
  printf '  MISS (PostgreSQL)  mean %s ms   min %s   max %s\n' "$c_mean" "$c_min" "$c_max"
  printf '  HIT  (Redis)       mean %s ms   min %s   max %s\n' "$w_mean" "$w_min" "$w_max"
  printf '  a HIT is %sx faster than a MISS\n' "$ratio"
  check "cold reads that were a MISS (of $SAMPLES)" "$SAMPLES" "$cold_miss"
  check "warm reads that were a HIT (of $SAMPLES)" "$SAMPLES" "$warm_hit"
  check_ok "a HIT is faster than a MISS on average (${ratio}x)" faster "${w_mean:-1}" "${c_mean:-0}"
  label why: "The time is measured by the server and sent in X-Response-Time. A MISS includes the full-table count that the cache saves."
}

step_persistence() {
  local vol rows_before id title old_id new_id left
  vol="$(project_of dev)_db-data"
  title="Persistence demo $(date +%H:%M:%S)"

  show "make test-db"
  check_has "PostgreSQL accepts connections" "$LAST" 'accepting connections'
  rows_before=$(printf '%s\n' "$LAST" | grep -E '^[0-9]+$' | tail -n 1)
  check_ok "the row count is numeric ($rows_before rows)" in_range "$rows_before" 1 999999999
  post_show dev "$title" HIGH
  check "the incident was accepted" 201 "$PO_CODE"
  id=$PO_ID
  show "$(psql_cmd dev "SELECT id, title, priority FROM incidents WHERE id = ${id:-0}")"
  check_has "the row is in PostgreSQL" "$LAST" "$title"
  show "docker volume ls --filter name=$vol"
  check_ok "the data volume exists" docker volume inspect "$vol"

  phase "to remove the database container"
  old_id=$(cid dev db)
  DB_DEV_DOWN=1
  quiet "$(dc dev) rm -sf db" "about 5 s"
  show "$(dc dev) ps -aq db | wc -l"
  left=$LAST
  show "docker volume ls -q --filter name=$vol"
  local volume_listed=$LAST
  await_state dev database down
  sync_web
  status_show dev
  check "db containers left" 0 "$left"
  check "the data volume survived" "$vol" "$volume_listed"
  check "/status HTTP code while the database is gone" 503 "$ST_CODE"
  check "web container stays healthy" healthy "$(health_of dev web)"

  phase "to create the database container again"
  quiet "$(dc dev) up -d --wait db" "about 10 s"
  DB_DEV_DOWN=0
  new_id=$(cid dev db)
  note "old container ${old_id:0:12}   new container ${new_id:0:12}"
  await_state dev database up
  sync_web
  status_show dev
  show "$(psql_cmd dev "SELECT id, title, priority FROM incidents WHERE id = ${id:-0}")"
  local row=$LAST
  show "$(psql_cmd dev "SELECT count(*) FROM incidents")"
  local rows_after
  rows_after=$(printf '%s\n' "$LAST" | grep -E '^[0-9]+$' | tail -n 1)
  show "$(dc dev) logs db | grep -c 'Skipping initialization'"
  local init_runs=$LAST
  check_ok "it is a different container" test "$old_id" != "$new_id"
  check "/status HTTP code after recovery" 200 "$ST_CODE"
  check_has "the incident survived" "$row" "$title"
  check "rows are the old count + 1" $(( ${rows_before:-0} + 1 )) "${rows_after:-x}"
  check "the existing volume skipped initialization (times)" 1 "$init_runs"
  where docker-compose.dev.yml 'db-data:/var/lib/postgresql' F
  where docker-compose.dev.yml 'target: /docker-entrypoint-initdb.d/init.sql' F
  where Makefile '^test-db:'
  label why: "The data lives in the named volume db-data, not in the container. init.sql runs only while the volume is empty, so the new container does not re-seed it."
}

step_init() {
  if [ "$AUTO" -eq 1 ]; then
    note "Skipped in --auto mode: it deletes the dev data."
    SKIP=$((SKIP + 1))
    return 0
  fi
  local answer
  printf '  This deletes the dev data volume. Type y to continue: '
  read -r answer
  if [ "$answer" != y ]; then
    note "Skipped."
    SKIP=$((SKIP + 1))
    return 0
  fi
  DB_DEV_DOWN=1
  quiet "$(dc dev) down -v" "about 10 s"
  quiet "$(dc dev) up -d --wait" "about 20 s"
  DB_DEV_DOWN=0
  show "$(dc dev) logs db | grep -c 'running /docker-entrypoint-initdb.d/init.sql'"
  check "init.sql ran on the empty volume (times)" 1 "$LAST"
  show "make test-db"
  check "rows loaded by init.sql" 50006 "$(printf '%s\n' "$LAST" | tail -n 1)"
  where db/init.sql 'CREATE TABLE incidents' F
  where db/init.sql 'generate_series' F
  label why: "With the volume deleted the database starts empty, so the image runs init.sql by itself. This is the contrast that shows the volume is what keeps the data."
}

step_redis_outage() {
  local code body
  CACHE_DOWN=1
  show "make kill-cache"
  await_state prod cache down
  sync_web
  status_show prod
  code=$ST_CODE
  body=$ST_BODY
  headers_show "$(url_of prod)/api/incidents"
  local read_code=$RD_CODE read_cache=$RD_CACHE
  show "$(dc prod) logs --no-log-prefix web | grep cache_unavailable | tail -n 1"
  check "/status HTTP code (the app is still usable)" 200 "$code"
  check "overall status" degraded "$(top "$body")"
  check "cache" down "$(svc "$body" cache)"
  check "web container stays healthy" healthy "$(health_of prod web)"
  check "reads keep working (HTTP code)" 200 "$read_code"
  check "reads are served by PostgreSQL" MISS "$read_cache"
  check_has "the outage is in the server log" "$LAST" cache_unavailable
  where src/routes.js 'const degraded' F
  where Makefile '^kill-cache:'
  label why: "Redis only speeds things up. With it down the app answers 200 'degraded' and reads go to PostgreSQL."

  phase "to start Redis again"
  show "make start-cache"
  CACHE_DOWN=0
  await_state prod cache up
  sync_web
  status_show prod
  code=$ST_CODE
  body=$ST_BODY
  headers_show "$(url_of prod)/api/incidents"
  local first=$RD_CACHE
  headers_show "$(url_of prod)/api/incidents"
  local second=$RD_CACHE
  show "$(dc prod) logs --no-log-prefix web | grep cache_available | tail -n 1"
  check "/status HTTP code" 200 "$code"
  check "overall status" ok "$(top "$body")"
  check "cache" up "$(svc "$body" cache)"
  check "first read after the restart (the cache restarts empty)" MISS "$first"
  check "second read" HIT "$second"
  check_has "the recovery is in the server log" "$LAST" cache_available
  label why: "ioredis reconnects by itself. Redis keeps nothing on disk, so it restarts empty and cannot serve stale data."
}

step_db_outage() {
  local code body
  headers_show "$(url_of prod)/api/incidents"
  DB_PROD_DOWN=1
  show "make kill-db ENV=prod"
  await_state prod database down
  sync_web
  status_show prod
  code=$ST_CODE
  body=$ST_BODY
  show "docker inspect -f '{{.State.Health.Status}}' $(cname prod web)"
  local web_health=$LAST
  headers_show "$(url_of prod)/api/incidents"
  local read_code=$RD_CODE read_cache=$RD_CACHE
  post_show prod "Must fail while the database is down" LOW
  check "/status HTTP code" 503 "$code"
  check "database" down "$(svc "$body" database)"
  check "web container stays healthy" healthy "$web_health"
  if [ "$read_code" = 200 ] && [ "$read_cache" = HIT ]; then
    pass "Redis still serves the last list while PostgreSQL is down"
  else
    note "The cached list had expired, so the read could not be served (HTTP $read_code)."
  fi
  check "a write is rejected" 503 "$PO_CODE"
  where Dockerfile '^HEALTHCHECK'
  where src/routes.js "router.get('/live'" F
  where Makefile '^kill-db:'
  label why: "/live does not touch the database, so the web container stays healthy while /status reports 503. Reads can still come from Redis until the key expires. Writes fail cleanly."

  phase "to start PostgreSQL again"
  show "make start-db ENV=prod"
  DB_PROD_DOWN=0
  await_state prod database up
  sync_web
  status_show prod
  code=$ST_CODE
  body=$ST_BODY
  headers_show "$(url_of prod)/api/incidents"
  check "/status HTTP code" 200 "$code"
  check "overall status" ok "$(top "$body")"
  check "reads work again (HTTP code)" 200 "$RD_CODE"
  label why: "The connection pool reconnects by itself: the web container is not restarted."
}

step_prod_persistence() {
  local vol title id old_id new_id before after
  vol="$(project_of prod)_db-data"
  title="Prod persistence $(date +%H:%M:%S)"

  show "$(psql_cmd prod "SELECT count(*) FROM incidents")"
  before=$(printf '%s\n' "$LAST" | grep -E '^[0-9]+$' | tail -n 1)
  check_ok "the row count is numeric (${before:-none} rows)" in_range "${before:-x}" 1 999999999
  post_show prod "$title" HIGH
  check "the incident was accepted" 201 "$PO_CODE"
  id=$PO_ID
  show "$(psql_cmd prod "SELECT id, title FROM incidents WHERE id = ${id:-0}")"
  check_has "the row is in PostgreSQL" "$LAST" "$title"
  show "docker volume ls -q --filter name=$vol"
  check "the prod data volume exists" "$vol" "$LAST"

  phase "to remove the prod database container"
  old_id=$(cid prod db)
  DB_PROD_DOWN=1
  quiet "$(dc prod) rm -sf db" "about 5 s"
  show "$(dc prod) ps -aq db | wc -l"
  check "prod db containers left" 0 "$(printf '%s' "$LAST" | tr -d ' ')"
  show "docker volume ls -q --filter name=$vol"
  check "the prod data volume survived" "$vol" "$LAST"
  await_state prod database down
  sync_web
  status_show prod
  check "/status HTTP code while the database is gone" 503 "$ST_CODE"
  check "web container stays healthy" healthy "$(health_of prod web)"

  phase "to create the prod database container again"
  quiet "$(dc prod) up -d --wait db" "about 10 s"
  DB_PROD_DOWN=0
  new_id=$(cid prod db)
  note "old container ${old_id:0:12}   new container ${new_id:0:12}"
  await_state prod database up
  sync_web
  status_show prod
  check "/status HTTP code after recovery" 200 "$ST_CODE"
  show "$(psql_cmd prod "SELECT id, title FROM incidents WHERE id = ${id:-0}")"
  check_has "the incident survived (read from PostgreSQL, not from Redis)" "$LAST" "$title"
  show "$(psql_cmd prod "SELECT count(*) FROM incidents")"
  after=$(printf '%s\n' "$LAST" | grep -E '^[0-9]+$' | tail -n 1)
  check "rows are the old count + 1" $(( ${before:-0} + 1 )) "${after:-x}"
  check_ok "it is a different container" test "$old_id" != "$new_id"
  where docker-compose.prod.yml 'db-data:/var/lib/postgresql' F
  where docker-compose.prod.yml 'target: /docker-entrypoint-initdb.d/init.sql' F
  label why: "The data lives in the named volume, not in the container. Removing the container and creating it again keeps the incident, and init.sql does not run again."
}

step_make_down() {
  local before after left
  show "$(psql_cmd prod "SELECT count(*) FROM incidents")"
  before=$(printf '%s\n' "$LAST" | grep -E '^[0-9]+$' | tail -n 1)
  quiet "make down" "about 15 s"
  show "docker ps -aq --filter name=bugtracker | wc -l"
  left=$(printf '%s' "$LAST" | tr -d ' ')
  check "containers left after make down" 0 "$left"
  show "docker volume ls -q --filter name=bugtracker | wc -l"
  check "volumes kept by make down (dev and prod data)" 2 "$(printf '%s' "$LAST" | tr -d ' ')"
  quiet "make up-prod" "about 20 s"
  quiet "make up-dev" "about 20 s"
  await_state prod database up
  show "$(psql_cmd prod "SELECT count(*) FROM incidents")"
  after=$(printf '%s\n' "$LAST" | grep -E '^[0-9]+$' | tail -n 1)
  check "incidents after make down and up (unchanged)" "${before:-x}" "${after:-y}"
  where Makefile '^down:'
  label why: "down removes the containers and networks and keeps the volumes. up starts them again on the same volumes, so the data is still there."
}

# =================================================================== map and list

print_map() {
  local row section requirement file pattern mode why hit line last='' missing=0
  for row in "${MAP_ROWS[@]}"; do
    IFS='|' read -r section requirement file pattern mode why <<<"$row"
    if [ "$section" != "$last" ]; then printf '\n%s%s%s\n' "$BOLD" "$section" "$RESET"; last=$section; fi
    if [ "$mode" = F ]; then
      hit=$(grep -nF -m 1 -- "$pattern" "$file" 2>/dev/null)
    else
      hit=$(grep -n -m 1 -- "$pattern" "$file" 2>/dev/null)
    fi
    if [ -n "$hit" ]; then
      line=${hit%%:*}
      printf '  %-46s %s:%s\n' "$requirement" "$file" "$line"
    else
      printf '  %-46s %s%s  NOT FOUND: %s%s\n' "$requirement" "$RED" "$file" "$pattern" "$RESET"
      missing=$((missing + 1))
    fi
    if [ -n "$why" ]; then printf '  %s%46s %s%s\n' "$DIM" '' "$why" "$RESET"; fi
  done
  printf '\n'
  if [ "$missing" -eq 0 ]; then
    printf '%s pointers, all found.\n' "${#MAP_ROWS[@]}"
  else
    printf '%s of %s pointers not found.\n' "$missing" "${#MAP_ROWS[@]}"
    return 1
  fi
}

# select_steps: fills SEL with the steps of the chosen path.
select_steps() {
  local entry set
  SEL=()
  for entry in "${STEPS[@]}"; do
    set=$(printf '%s' "$entry" | cut -d'|' -f2)
    if [ "$set" = core ] || [ "$FULL" -eq 1 ]; then SEL+=("$entry"); fi
  done
}

print_list() {
  local entry n=0 id set title
  for entry in "${SEL[@]}"; do
    n=$((n + 1))
    IFS='|' read -r id set title _ <<<"$entry"
    printf '  %2s  %-5s %s\n' "$n" "$set" "$title"
  done
  printf '\n  %s steps. Use --full for the complete path, --from N --to M for a range.\n' "$n"
}

# ====================================================================== run

preflight() {
  local tool
  for tool in docker curl make awk sed grep stat fold git; do
    command -v "$tool" >/dev/null || die "missing tool: $tool"
  done
  docker info >/dev/null 2>&1 || die "the Docker daemon is not reachable"
  if [ ! -f .env.dev ] || [ ! -f .env.prod ]; then
    make setup-env >/dev/null || die "make setup-env failed"
  fi
}

require_running() {
  local pair e s
  for pair in "dev web" "dev db" "prod web" "prod db" "prod cache"; do
    read -r e s <<<"$pair"
    [ "$(health_of "$e" "$s")" = healthy ] ||
      die "the environments are not running: run make up-dev up-prod first, or start from the step that builds them"
  done
}

# Starts again whatever the demo stopped, so the environments are never left broken.
restore_services() {
  local did=0
  if [ "$DB_DEV_DOWN" -eq 1 ]; then compose dev up -d --wait >/dev/null 2>&1; did=1; fi
  if [ "$DB_PROD_DOWN" -eq 1 ]; then compose prod up -d --wait db >/dev/null 2>&1; did=1; fi
  if [ "$CACHE_DOWN" -eq 1 ]; then compose prod start cache >/dev/null 2>&1; did=1; fi
  if [ "$did" -eq 1 ]; then printf '\n%sThe demo started again the services it had stopped.%s\n' "$YELLOW" "$RESET"; fi
  return 0
}

cleanup() {
  local code=$?
  trap - EXIT INT TERM
  restore_services
  [ -n "$TMP" ] && rm -rf "$TMP"
  exit "$code"
}

summary() {
  local elapsed=$((SECONDS - START_TIME))
  printf '\n'
  hr
  printf '  %s%s checks passed%s' "$GREEN" "$PASS" "$RESET"
  if [ "$FAIL" -gt 0 ]; then printf '   %s%s failed%s' "$RED" "$FAIL" "$RESET"; else printf '   0 failed'; fi
  printf '   %s not counted   %sm %ss\n' "$SKIP" $((elapsed / 60)) $((elapsed % 60))
  if [ "$FAIL" -gt 0 ]; then printf '\n  Checks that failed:\n%s' "$FAILED"; fi
  printf '\n  Both environments are running: dev %s, prod %s\n\n' "$(url_of dev)" "$(url_of prod)"
}

main() {
  while [ $# -gt 0 ]; do
    case $1 in
      --auto) AUTO=1 ;;
      --full) FULL=1 ;;
      --list) LIST=1 ;;
      --map)  MAP=1 ;;
      --from) shift; FROM=${1:-x} ;;
      --to)   shift; TO=${1:-x} ;;
      -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
      *) die "unknown option: $1 (see --help)" ;;
    esac
    shift
  done
  case $FROM$TO in *[!0-9]*|'') die "--from and --to need a number" ;; esac
  [ -t 0 ] || AUTO=1
  setup_terminal

  if [ "$MAP" -eq 1 ]; then print_map; exit $?; fi
  select_steps
  if [ "$LIST" -eq 1 ]; then print_list; exit 0; fi

  preflight
  TMP=$(mktemp -d)
  trap cleanup EXIT
  trap 'exit 130' INT TERM

  local total=${#SEL[@]} n=0 entry id set title action look runs_up=0
  for entry in "${SEL[@]}"; do
    n=$((n + 1))
    [ "$n" -ge "$FROM" ] && [ "$n" -le "$TO" ] || continue
    [ "$(printf '%s' "$entry" | cut -d'|' -f1)" = up ] && runs_up=1
  done
  [ "$runs_up" -eq 1 ] || require_running

  n=0
  for entry in "${SEL[@]}"; do
    n=$((n + 1))
    [ "$n" -lt "$FROM" ] && continue
    [ "$n" -gt "$TO" ] && break
    IFS='|' read -r id set title action look <<<"$entry"
    look=${look//@DEV@/$(url_of dev)}
    look=${look//@PROD@/$(url_of prod)}
    printf '\n%s' "$BOLD"; hr
    printf '[%s/%s]  %s%s\n' "$n" "$total" "$title" "$RESET"
    label 'do:' "$action"
    if [ -n "$look" ]; then label 'see:' "$look"; fi
    gate
    "step_$id"
  done
  summary
  exit $((FAIL > 0))
}

if [ -z "${DEMO_LIB:-}" ]; then main "$@"; fi
