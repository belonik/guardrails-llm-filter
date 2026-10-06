#!/usr/bin/env bash
#
# Functional + regression checks for the fixes merged into fork/main, run
# against the stand in this directory (docker compose).
#
#   ./test-fixes.sh                 # run every check against a running stand
#   ./test-fixes.sh --up            # build if needed, up -d, wait, then check
#   ./test-fixes.sh --only fio,tools
#   ./test-fixes.sh --list
#   ./test-fixes.sh --down          # stop the stand (keeps the pg volume)
#
# What each check is for (issue -> what would break without the fix):
#
#   stand            both replicas up, same build, metrics endpoint serving
#   engine-auth      #41 /v1/mask|/v1/unmask refuse to answer without the token
#   engine-roundtrip #41 mask hides the originals, unmask restores them exactly
#   scan-only        #20 boots and scans with no upstream at all (no panic),
#                        and starts no gateway listener when the plane is off
#   grpc-max-message #22 a ~5.5 MiB management-API response survives the
#                        grpc-gateway hop; with the default 4 MiB it does not
#   fio              #35 hyphenated and comma-inverted ФИО fully masked, no
#                        half-name left in the clear, greeting not dragged in
#   tools            #36 tool definitions masked in all three wire formats,
#                        machine-facing keywords left intact
#   counters         #23 /v1/metrics/summary reports the same lifetime numbers
#                        from both replicas (shared store), +delta on both
#   baseline         the ordinary path still works: /healthz, /readyz,
#                        /metrics, /v1/scan, masking round-trip via the proxy
#
# The oracle for "what the model actually saw" is the capture file written by
# the mock upstream (./capture/requests.jsonl), keyed by the X-Test-Id header.
#
# Exit code 0 only if every check passed.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

# --- options ----------------------------------------------------------------

DO_UP=0
DO_DOWN=0
ONLY=""
LIST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --up) DO_UP=1; shift ;;
    --down) DO_DOWN=1; shift ;;
    --only) ONLY="${2:-}"; shift 2 ;;
    --list) LIST=1; shift ;;
    -h|--help) sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
done

# --- config -----------------------------------------------------------------

# .env is optional: every value has the same default in docker-compose.yml.
if [ -f .env ]; then set -a; . ./.env; set +a; fi

HOST="${HOST:-127.0.0.1}"
GW1="${GW1_PORT:-8080}"
GW2="${GW2_PORT:-8081}"
API1="${API1_PORT:-9080}"
API2="${API2_PORT:-9081}"
METRICS1="${METRICS1_PORT:-9090}"
ENGINE1="${ENGINE1_PORT:-9100}"
ENGINE2="${ENGINE2_PORT:-9101}"
TOKEN="${GUARDRAILS_ENGINE_API_TOKEN:-stand-engine-token}"
IMAGE="${GUARDRAILS_IMAGE:-guardrails-llm-filter:test}"
CAPTURE="$DIR/capture/requests.jsonl"
TIMEOUT="${TIMEOUT:-60}"
RUN_ID="$(date +%s)-$$"

API1_URL="http://$HOST:$API1"
API2_URL="http://$HOST:$API2"
GW1_URL="http://$HOST:$GW1"
GW2_URL="http://$HOST:$GW2"
ENGINE1_URL="http://$HOST:$ENGINE1"
METRICS1_URL="http://$HOST:$METRICS1"

# Sizes for the #22 check: comfortably past grpc-go's built-in 4 MiB receive
# limit, well inside the stand's 32 MiB request cap.
BIG_TARGET_BYTES=$((5 * 1024 * 1024 + 512 * 1024)) # ~5.5 MiB
GRPC_DEFAULT_LIMIT=$((4 * 1024 * 1024))            # 4 MiB

TMP="$(mktemp -d)"
ONEOFFS=()
cleanup() {
  for c in "${ONEOFFS[@]:-}"; do [ -n "$c" ] && docker rm -f "$c" >/dev/null 2>&1; done
  rm -rf "$TMP"
}
trap cleanup EXIT

# --- output -----------------------------------------------------------------

if [ -t 1 ]; then
  RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; BLD=$'\033[1m'; RST=$'\033[0m'
else
  RED=""; GRN=""; YLW=""; BLD=""; RST=""
fi
PASS=0
FAIL=0
FAILURES=()

section() { printf '\n%s== %s%s\n' "$BLD" "$*" "$RST"; }
ok() { PASS=$((PASS + 1)); printf '  %sPASS%s %s\n' "$GRN" "$RST" "$1"; }
bad() {
  FAIL=$((FAIL + 1))
  FAILURES+=("$1")
  printf '  %sFAIL%s %s%s\n' "$RED" "$RST" "$1" "${2:+ — $2}"
}
skip() { printf '  %sSKIP%s %s%s\n' "$YLW" "$RST" "$1" "${2:+ — $2}"; }
short() { printf '%s' "$1" | head -c 240; }

assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "ожидалось [$3], получено [$(short "$2")]"; fi; }
assert_ne() { if [ "$2" != "$3" ]; then ok "$1"; else bad "$1" "значение не должно быть [$3]"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "нет [$3] в [$(short "$2")]" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) bad "$1" "в теле осталось [$3]: [$(short "$2")]" ;; *) ok "$1" ;; esac; }
assert_ge() { if [ "$2" -ge "$3" ] 2>/dev/null; then ok "$1"; else bad "$1" "[$2] < [$3]"; fi; }

# --- http/docker helpers ----------------------------------------------------

code() { curl -s -o /dev/null -w '%{http_code}' -m "$TIMEOUT" "$@"; }
body() { curl -s -m "$TIMEOUT" "$@"; }
code_size() { curl -s -o "$1" -w '%{http_code} %{size_download}' -m "$TIMEOUT" "${@:2}"; }

api_health() { body "$API1_URL/v1/health"; }
api1_get() { body "$API1_URL$1"; }
api2_get() { body "$API2_URL$1"; }

# captured_body <test-id>: the (masked) body the mock upstream received for that
# request, compact JSON. Waits briefly for the capture line to land on disk.
captured_body() {
  local id="$1" i
  for i in $(seq 1 25); do
    [ -f "$CAPTURE" ] && grep -qF -- "$id" "$CAPTURE" && break
    sleep 0.2
  done
  jq -c --arg id "$id" 'select(.test_id == $id) | .body' "$CAPTURE" 2>/dev/null | tail -1
}

# proxy_post <port> <path> <test-id> <payload-file> <out-file> -> http code
proxy_post() {
  local port="$1" path="$2" id="$3" in="$4" out="$5"
  curl -s -m "$TIMEOUT" -X POST "http://$HOST:$port$path" \
    -H 'Content-Type: application/json' \
    -H "X-Test-Id: $id" \
    --data-binary "@$in" -o "$out" -w '%{http_code}'
}

# wait_http <url> <seconds>: poll until the URL answers 200.
wait_http() {
  local url="$1" limit="${2:-20}" i
  for i in $(seq 1 "$limit"); do
    [ "$(code -m 2 "$url")" = "200" ] && return 0
    sleep 1
  done
  return 1
}

has_check() { [ -z "$ONLY" ] || case ",$ONLY," in *",$1,"*) true ;; *) false ;; esac; }

# --- checks -----------------------------------------------------------------

check_stand() {
  section "stand: оба реплики подняты и отвечают"
  local h1 h2 v1 v2
  h1="$(code "$API1_URL/v1/health")"
  h2="$(code "$API2_URL/v1/health")"
  assert_eq "replica-1 management API /v1/health" "$h1" "200"
  assert_eq "replica-2 management API /v1/health" "$h2" "200"

  v1="$(api1_get /v1/version)"
  v2="$(api2_get /v1/version)"
  assert_eq "одинаковый билд на обоих репликах (version)" \
    "$(printf '%s' "$v1" | jq -r '.version // "?"')" \
    "$(printf '%s' "$v2" | jq -r '.version // "?"')"
  printf '       version=%s commit=%s\n' \
    "$(printf '%s' "$v1" | jq -r '.version // "?"')" \
    "$(printf '%s' "$v1" | jq -r '.commit // "?"')"

  assert_eq "data-plane /healthz" "$(code "$GW1_URL/healthz")" "200"
  assert_eq "data-plane /readyz" "$(code "$GW1_URL/readyz")" "200"
  assert_eq "Prometheus /metrics" "$(code "$METRICS1_URL/metrics")" "200"
  # The masked-request family only shows up once something has been masked, so
  # assert it in `baseline` (after traffic) rather than here.
}

check_engine_auth() {
  section "#41 engine API: без токена не отвечает"
  local out="$TMP/engine-auth.json" hdrs="$TMP/engine-auth.hdr" c

  c="$(curl -s -D "$hdrs" -o "$out" -w '%{http_code}' -m "$TIMEOUT" \
    -X POST "$ENGINE1_URL/v1/mask" -H 'Content-Type: application/json' \
    -d '{"texts":["почта a@b.c"],"correlation_id":"auth-'$RUN_ID'"}')"
  assert_eq "/v1/mask без Authorization -> 401" "$c" "401"
  assert_contains "ответ содержит code=unauthorized" "$(cat "$out")" "unauthorized"
  # Go canonicalizes header names (Www-Authenticate), so compare lowercased.
  assert_contains "есть заголовок WWW-Authenticate: Bearer" \
    "$(tr 'A-Z' 'a-z' < "$hdrs")" "www-authenticate: bearer"

  c="$(code -X POST "$ENGINE1_URL/v1/mask" -H 'Content-Type: application/json' \
    -H 'Authorization: Bearer not-the-token' \
    -d '{"texts":["почта a@b.c"],"correlation_id":"auth2-'$RUN_ID'"}')"
  assert_eq "/v1/mask с чужим токеном -> 401" "$c" "401"

  c="$(code -X POST "$ENGINE1_URL/v1/mask" -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $TOKEN" \
    -d '{"texts":["почта a@b.c"],"correlation_id":"auth3-'$RUN_ID'"}')"
  assert_eq "/v1/mask с верным токеном -> 200" "$c" "200"

  c="$(code "$ENGINE1_URL/v1/engine/version")"
  assert_eq "/v1/engine/version без токена -> 200 (по контракту)" "$c" "200"
  assert_contains "версия контракта v1" "$(body "$ENGINE1_URL/v1/engine/version")" '"v1"'
}

check_engine_roundtrip() {
  section "#41 engine API: mask не отдаёт оригиналы, unmask возвращает их"
  local cid="rt-$RUN_ID" out="$TMP/mask.json" unmasked txt
  txt="Оплату подтвердил Иванов Иван Петрович, почта ivan.petrov@example.com"

  c="$(curl -s -o "$out" -w '%{http_code}' -m "$TIMEOUT" -X POST "$ENGINE1_URL/v1/mask" \
    -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" \
    -d "$(jq -nc --arg t "$txt" --arg c "$cid" '{texts:[$t],correlation_id:$c}')")"
  assert_eq "/v1/mask -> 200" "$c" "200"

  local masked
  masked="$(jq -r '.masked_texts[0] // ""' "$out")"
  assert_contains "текст замаскирован (есть плейсхолдер)" "$masked" "<"
  assert_not_contains "в ответе нет оригинального email" "$masked" "ivan.petrov@example.com"
  assert_not_contains "в ответе нет оригинальной фамилии" "$masked" "Иванов"
  assert_not_contains "в /v1/mask нет поля с оригиналами" "$(cat "$out")" "Иванов Иван Петрович"

  local c2
  c2="$(curl -s -o "$TMP/unmask.json" -w '%{http_code}' -m "$TIMEOUT" -X POST "$ENGINE1_URL/v1/unmask" \
    -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" \
    -d "$(jq -nc --arg c "$cid" '{texts:["ответ на замаскированный текст"],correlation_id:$c}')")"
  assert_eq "/v1/unmask -> 200" "$c2" "200"

  unmasked="$(curl -s -m "$TIMEOUT" -X POST "$ENGINE1_URL/v1/unmask" \
    -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" \
    -d "$(jq -nc --arg c "$cid" --arg t "$masked" '{texts:[$t],correlation_id:$c}')" | jq -r '.texts[0] // ""')"
  assert_eq "unmask(mask(x)) == x" "$unmasked" "$txt"

  local c404
  c404="$(code -X POST "$ENGINE1_URL/v1/unmask" -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $TOKEN" \
    -d '{"texts":["<EMAIL_1>"],"correlation_id":"never-masked-'$RUN_ID'"}')"
  assert_eq "unmask с неизвестным correlation_id -> 404 (не passthrough)" "$c404" "404"
}

check_scan_only() {
  section "#20 scan-only: сервис живёт без upstream и без data plane"

  # (a) Data plane ON, no upstream at all: must boot, and /v1/scan must work.
  local name="gr-verify-noup-$RUN_ID" port=19098
  docker rm -f "$name" >/dev/null 2>&1
  if docker run -d --name "$name" \
    -e GUARDRAILS_LOG_LEVEL=warn \
    -e GUARDRAILS_API_ADDR=:9080 \
    -e GUARDRAILS_STORE_BACKEND=in_memory \
    -p "127.0.0.1:$port:9080" "$IMAGE" >/dev/null 2>&1; then
    ONEOFFS+=("$name")
    if wait_http "http://$HOST:$port/v1/health" 20; then
      ok "без GUARDRAILS_UPSTREAM_BASE_URL сервис поднимается (раньше падал)"
      local c
      c="$(code -m "$TIMEOUT" -X POST "http://$HOST:$port/v1/scan" \
        -H 'Content-Type: application/json' \
        -d '{"texts":["почта a@b.c"]}')"
      assert_eq "/v1/scan работает без upstream" "$c" "200"
      assert_eq "процесс не упал после запроса" \
        "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" "true"
    else
      bad "без GUARDRAILS_UPSTREAM_BASE_URL сервис поднимается" "нет ответа /v1/health"
      printf '       логи: %s\n' "$(docker logs --tail 5 "$name" 2>&1 | tr '\n' ' ' | head -c 300)"
    fi
    docker rm -f "$name" >/dev/null 2>&1
  else
    bad "контейнер scan-only (без upstream) запускается" "docker run не удался"
  fi

  # (b) Data plane OFF: no gateway listener on 8080, management API still there.
  local name2="gr-verify-nodp-$RUN_ID" api_port=19097 gw_port=19096
  docker rm -f "$name2" >/dev/null 2>&1
  if docker run -d --name "$name2" \
    -e GUARDRAILS_LOG_LEVEL=warn \
    -e GUARDRAILS_DATA_PLANE_ENABLED=false \
    -e GUARDRAILS_API_ADDR=:9080 \
    -e GUARDRAILS_STORE_BACKEND=in_memory \
    -p "127.0.0.1:$api_port:9080" \
    -p "127.0.0.1:$gw_port:8080" "$IMAGE" >/dev/null 2>&1; then
    ONEOFFS+=("$name2")
    if wait_http "http://$HOST:$api_port/v1/health" 20; then
      ok "GUARDRAILS_DATA_PLANE_ENABLED=false: сервис поднимается без upstream"
      assert_eq "/v1/scan доступен" \
        "$(code -m "$TIMEOUT" -X POST "http://$HOST:$api_port/v1/scan" \
          -H 'Content-Type: application/json' -d '{"texts":["почта a@b.c"]}')" "200"
      local gwcode
      gwcode="$(code -m 3 "http://$HOST:$gw_port/healthz")"
      assert_eq "gateway-листенер не поднят (порт 8080 молчит)" "$gwcode" "000"
    else
      bad "GUARDRAILS_DATA_PLANE_ENABLED=false: сервис поднимается" "нет ответа /v1/health"
      printf '       логи: %s\n' "$(docker logs --tail 5 "$name2" 2>&1 | tr '\n' ' ' | head -c 300)"
    fi
    docker rm -f "$name2" >/dev/null 2>&1
  else
    bad "контейнер с выключенным data plane запускается" "docker run не удался"
  fi
}

# build_big_scan <file>: a JSON scan request whose response is ~5.5 MiB (the
# masked text comes back at input size, which is what has to survive the
# grpc-gateway hop).
build_big_scan() {
  python3 - "$1" "$BIG_TARGET_BYTES" <<'PY'
import json, sys
out, target = sys.argv[1], int(sys.argv[2])
chunk = "Строка документа для проверки лимита gRPC. Почта ivan.petrov@example.com, тел. +7 916 123-45-67. "
per = len(chunk.encode())
n = max(1, target // per)
with open(out, "w", encoding="utf-8") as f:
    json.dump({"texts": [chunk * n]}, f, ensure_ascii=False)
PY
}

check_grpc_max_message() {
  section "#22 лимит gRPC: ответ >4 MiB проходит management API"
  build_big_scan "$TMP/big-scan.json"
  local req_size
  req_size="$(wc -c < "$TMP/big-scan.json" | tr -d ' ')"
  printf '       запрос: %s байт (цель ~%s)\n' "$req_size" "$BIG_TARGET_BYTES"

  # Positive: the stand runs with GUARDRAILS_GRPC_MAX_MESSAGE_BYTES set.
  local res
  res="$(code_size "$TMP/big-scan-resp.json" -X POST "$API1_URL/v1/scan" \
    -H 'Content-Type: application/json' --data-binary "@$TMP/big-scan.json")"
  local c="${res%% *}" size="${res##* }"
  assert_eq "scan с ответом >4 MiB -> 200 (лимит поднят)" "$c" "200"
  assert_ge "размер ответа превышает встроенный лимит grpc-go (4 MiB)" "${size%.*}" "$GRPC_DEFAULT_LIMIT"

  # Negative control: the same scan against the same image compiled-in defaults.
  # Without GRPC_MAX_MESSAGE_BYTES the 4 MiB receive limit applies and the call
  # must fail — otherwise this check proves nothing about the fix.
  local name="gr-verify-noopt-$RUN_ID" port=19095
  docker rm -f "$name" >/dev/null 2>&1
  if docker run -d --name "$name" \
    -e GUARDRAILS_LOG_LEVEL=warn \
    -e GUARDRAILS_DATA_PLANE_ENABLED=false \
    -e GUARDRAILS_API_ADDR=:9080 \
    -e GUARDRAILS_STORE_BACKEND=in_memory \
    -p "127.0.0.1:$port:9080" "$IMAGE" >/dev/null 2>&1; then
    ONEOFFS+=("$name")
    if wait_http "http://$HOST:$port/v1/health" 20; then
      local cdef
      cdef="$(code -m "$TIMEOUT" -X POST "http://$HOST:$port/v1/scan" \
        -H 'Content-Type: application/json' --data-binary "@$TMP/big-scan.json")"
      assert_ne "без GUARDRAILS_GRPC_MAX_MESSAGE_BYTES тот же scan падает" "$cdef" "200"
      printf '       контроль без фикса: HTTP %s\n' "$cdef"
      case "$cdef" in
        429) printf '       (429 = gRPC ResourceExhausted «received message larger than max», так это и выглядит без фикса)\n' ;;
      esac
    else
      skip "контроль без GUARDRAILS_GRPC_MAX_MESSAGE_BYTES" "контейнер не поднялся"
    fi
    docker rm -f "$name" >/dev/null 2>&1
  else
    skip "контроль без GUARDRAILS_GRPC_MAX_MESSAGE_BYTES" "docker run не удался"
  fi
}

# chat_payload <file> <user-text> [tools-json]
chat_payload() {
  local file="$1" text="$2" tools="${3:-}"
  if [ -n "$tools" ]; then
    jq -nc --arg t "$text" --argjson tools "$tools" \
      '{model:"mock",messages:[{role:"user",content:$t}],tools:$tools}' > "$file"
  else
    jq -nc --arg t "$text" '{model:"mock",messages:[{role:"user",content:$t}]}' > "$file"
  fi
}

# proxy_roundtrip <port> <path> <payload-file> <test-id> <out-file>: sends the
# request and returns the captured (masked) body on stdout; the HTTP code is
# read back with rt_code. The code travels through a file, not a variable: a
# command substitution runs this in a subshell, where assignments are lost.
proxy_roundtrip() {
  local port="$1" path="$2" in="$3" id="$4" out="$5" c
  c="$(proxy_post "$port" "$path" "$id" "$in" "$out")"
  printf '%s' "$c" > "$TMP/last-code"
  captured_body "$id"
}
rt_code() { cat "$TMP/last-code" 2>/dev/null; }

check_fio() {
  section "#35 ФИО: дефисные и «Фамилия, Имя Отчество» маскируются целиком"
  local id in out cap resp

  # (1) Hyphenated compound name in the surname slot. Before the fix
  # pii.fio-ru.short masked only "Мария Ковалёва" and left "Анна-" in clear.
  id="fio-hyphen-$RUN_ID"; in="$TMP/fio1.json"; out="$TMP/fio1.out"
  chat_payload "$in" "отзыв оставила Анна-Мария Ковалёва вчера"
  cap="$(proxy_roundtrip "$GW1" /v1/chat/completions "$in" "$id" "$out")"
  assert_eq "chat/completions принят" "$(rt_code)" "200"
  assert_contains "имя замаскировано" "$cap" "<"
  assert_not_contains "в теле для модели нет «Анна-»" "$cap" "Анна-"
  assert_not_contains "в теле для модели нет «Ковалёва»" "$cap" "Ковалёва"
  resp="$(cat "$out")"
  assert_contains "клиент получил оригинал обратно (demask)" "$resp" "Анна-Мария Ковалёва"

  # (2) Comma-inverted document order. Before the fix only "Пётр Ильич" was
  # masked and "Смирнов," reached the model.
  id="fio-comma-$RUN_ID"; in="$TMP/fio2.json"; out="$TMP/fio2.out"
  chat_payload "$in" "Ответственный: Смирнов, Пётр Ильич"
  cap="$(proxy_roundtrip "$GW1" /v1/chat/completions "$in" "$id" "$out")"
  assert_eq "chat/completions (comma-inverted) принят" "$(rt_code)" "200"
  assert_contains "ФИО замаскировано" "$cap" "<"
  assert_not_contains "в теле для модели нет «Смирнов,»" "$cap" "Смирнов,"
  assert_not_contains "в теле для модели нет «Пётр Ильич»" "$cap" "Пётр Ильич"
  assert_contains "клиент получил оригинал обратно" "$(cat "$out")" "Смирнов, Пётр Ильич"

  # (3) Precision: a greeting before the comma is not a surname, so the
  # comma-inverted branch must not drag "Здравствуйте," into the match.
  id="fio-greet-$RUN_ID"; in="$TMP/fio3.json"; out="$TMP/fio3.out"
  chat_payload "$in" "Здравствуйте, Анна Сергеевна, проходите"
  cap="$(proxy_roundtrip "$GW1" /v1/chat/completions "$in" "$id" "$out")"
  assert_eq "chat/completions (greeting) принят" "$(rt_code)" "200"
  assert_contains "приветствие осталось в открытом виде" "$cap" "Здравствуйте,"
  assert_not_contains "имя при этом замаскировано" "$cap" "Анна Сергеевна"
}

check_tools() {
  section "#36 определения инструментов: маскируются во всех трёх форматах"
  local email="ivan.petrov@example.com"

  # --- chat/completions -----------------------------------------------------
  local tools id in out cap
  tools='[{"type":"function","function":{"name":"send_email","description":"Отправь письмо на '"$email"'","parameters":{"type":"object","properties":{"to":{"type":"string","format":"email","description":"адрес клиента","default":"'"$email"'"},"subject":{"type":"string","title":"Тема письма"}},"required":["to"]}}}]'
  id="tools-chat-$RUN_ID"; in="$TMP/tools1.json"; out="$TMP/tools1.out"
  chat_payload "$in" "привет" "$tools"
  cap="$(proxy_roundtrip "$GW1" /v1/chat/completions "$in" "$id" "$out")"
  assert_eq "chat/completions с tools принят" "$(rt_code)" "200"
  assert_not_contains "chat: email не дошёл до модели" "$cap" "$email"
  assert_contains "chat: в description плейсхолдер" "$cap" "<"
  assert_contains "chat: имя функции не замаскировано" "$cap" '"send_email"'
  assert_contains "chat: machine-facing format не тронут" "$cap" '"format":"email"'
  assert_contains "chat: required не тронут" "$cap" '"required":["to"]'

  # --- messages (Anthropic) -------------------------------------------------
  local mtools='[{"name":"send_email","description":"Отправь письмо на '"$email"'","input_schema":{"type":"object","properties":{"to":{"type":"string","description":"адрес клиента","default":"'"$email"'"}},"required":["to"]}}]'
  id="tools-msg-$RUN_ID"; in="$TMP/tools2.json"; out="$TMP/tools2.out"
  jq -nc --argjson tools "$mtools" \
    '{model:"claude",max_tokens:64,messages:[{role:"user",content:"привет"}],tools:$tools}' > "$in"
  cap="$(proxy_roundtrip "$GW1" /v1/messages "$in" "$id" "$out")"
  assert_eq "/v1/messages с tools принят" "$(rt_code)" "200"
  assert_not_contains "messages: email не дошёл до модели" "$cap" "$email"
  assert_contains "messages: description замаскирован" "$cap" "<"
  assert_contains "messages: имя инструмента не тронуто" "$cap" '"send_email"'
  assert_contains "messages: input_schema.required не тронут" "$cap" '"required":["to"]'

  # --- responses ------------------------------------------------------------
  local rtools='[{"type":"function","name":"send_email","description":"Отправь письмо на '"$email"'","parameters":{"type":"object","properties":{"to":{"type":"string","default":"'"$email"'"}},"required":["to"]}}]'
  id="tools-resp-$RUN_ID"; in="$TMP/tools3.json"; out="$TMP/tools3.out"
  jq -nc --argjson tools "$rtools" \
    '{model:"gpt",input:"привет",tools:$tools}' > "$in"
  cap="$(proxy_roundtrip "$GW1" /v1/responses "$in" "$id" "$out")"
  assert_eq "/v1/responses с tools принят" "$(rt_code)" "200"
  assert_not_contains "responses: email не дошёл до модели" "$cap" "$email"
  assert_contains "responses: description замаскирован" "$cap" "<"
  assert_contains "responses: имя инструмента не тронуто" "$cap" '"send_email"'
}

# summary_enforce <api-url>: lifetime masked-request counter, 0 if unreadable.
summary_enforce() {
  local v
  v="$(body "$1/v1/metrics/summary" | jq -r '.requests_masked_total.enforce // 0' 2>/dev/null)"
  printf '%s' "${v:-0}"
}

check_counters() {
  section "#23 распределённые счётчики: обе реплики показывают одно и то же"

  local b1 b2
  b1="$(summary_enforce "$API1_URL")"
  b2="$(summary_enforce "$API2_URL")"

  # 3 masked requests to each replica.
  local i per=3
  for i in $(seq 1 "$per"); do
    chat_payload "$TMP/cnt-$i.json" "клиент $i, почта client$i@example.com"
    proxy_post "$GW1" /v1/chat/completions "cnt-a-$RUN_ID-$i" "$TMP/cnt-$i.json" /dev/null >/dev/null
    proxy_post "$GW2" /v1/chat/completions "cnt-b-$RUN_ID-$i" "$TMP/cnt-$i.json" /dev/null >/dev/null
  done

  # Counters are flushed to the shared store in batches (~5s). Reading a
  # replica's summary flushes that replica's own pending deltas, so read 2
  # first (flush), then 1 (flush + read the store), then 2 again.
  sleep 7
  local a1 a2
  a1="$(summary_enforce "$API1_URL")"
  a2="$(summary_enforce "$API2_URL")"
  a1="$(summary_enforce "$API1_URL")"

  assert_eq "replica-1 и replica-2 отдают одинаковый requests_masked_total" "$a1" "$a2"
  assert_eq "дельта replica-1 = +$((per * 2)) запросов (трафик обеих реплик)" \
    "$((a1 - b1))" "$((per * 2))"
  assert_ge "lifetime-счётчик не меньше локальной дельты" "$a1" "$b1"
  printf '       enforce: replica-1 %s -> %s, replica-2 %s -> %s (shared store)\n' "$b1" "$a1" "$b2" "$a2"

  # Sanity: the stand is expected to run with the shared-store source; with
  # "local" the two replicas would legitimately differ and this check would
  # (correctly) fail.
  printf '       режим: GUARDRAILS_METRICS_SUMMARY_SOURCE=%s\n' \
    "${GUARDRAILS_METRICS_SUMMARY_SOURCE:-auto}"
}

check_baseline() {
  section "baseline: обычный путь маскирования не сломан"

  # scan API. /v1/scan is the console's rule tester: it deliberately returns
  # originals in placeholders[].original, so the leak assertion is about the
  # text that would go to the model — masked_texts.
  local scan
  scan="$(body -X POST "$API1_URL/v1/scan" -H 'Content-Type: application/json' \
    -d '{"texts":["пишите на ivan.petrov@example.com или +7 916 123-45-67"]}')"
  assert_contains "scan вернул плейсхолдеры" "$scan" "<"
  assert_not_contains "scan.masked_texts не содержит email" \
    "$(printf '%s' "$scan" | jq -r '.masked_texts[0] // ""')" "ivan.petrov@example.com"
  assert_not_contains "scan.masked_texts не содержит телефон" \
    "$(printf '%s' "$scan" | jq -r '.masked_texts[0] // ""')" "916 123-45-67"

  # management API surface
  assert_eq "GET /v1/settings" "$(code "$API1_URL/v1/settings")" "200"
  assert_eq "GET /v1/rules" "$(code "$API1_URL/v1/rules")" "200"
  assert_eq "GET /v1/data-types" "$(code "$API1_URL/v1/data-types")" "200"

  # round-trip through the proxy: the model must never see the original, the
  # client must always get it back.
  local id="base-$RUN_ID" in="$TMP/base.json" out="$TMP/base.out" cap
  chat_payload "$in" "телефон клиента +7 916 123-45-67, почта ivan.petrov@example.com"
  cap="$(proxy_roundtrip "$GW1" /v1/chat/completions "$in" "$id" "$out")"
  assert_eq "data-plane запрос принят" "$(rt_code)" "200"
  assert_not_contains "email не ушёл в модель" "$cap" "ivan.petrov@example.com"
  assert_not_contains "телефон не ушёл в модель" "$cap" "916 123-45-67"
  assert_contains "клиент получил оригинальный телефон (demask)" "$(cat "$out")" "916 123-45-67"

  # audit trail written to the shared store
  local audit
  audit="$(body "$API1_URL/v1/audit/records?limit=5")"
  assert_contains "аудит-записи пишутся" "$audit" "records"

  # Prometheus surface, asserted after traffic: a counter with no observations
  # is not exported at all, so this family only exists once a request has been
  # masked.
  assert_contains "в /metrics есть счётчик masked-запросов" \
    "$(body "$METRICS1_URL/metrics")" "extproc_guardrails_requests_masked_total"
}

# --- orchestration ----------------------------------------------------------

up_stand() {
  section "поднимаю стенд"
  [ -f .env ] || { cp .env.example .env; echo "  создан .env из .env.example"; }
  mkdir -p capture && chmod 777 capture
  if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "  образ $IMAGE не найден — собираю из репозитория (docker build ../..)"
    docker build -t "$IMAGE" ../.. || { echo "сборка образа не удалась" >&2; exit 1; }
  fi
  docker compose up -d --build || exit 1
  for p in "$API1" "$API2"; do
    if wait_http "http://$HOST:$p/v1/health" 60; then
      echo "  management API :$p готов"
    else
      echo "  management API :$p не поднялся" >&2
      docker compose logs --tail 20 guardrails-1 guardrails-2 >&2 || true
      exit 1
    fi
  done
}

down_stand() {
  section "останавливаю стенд"
  docker compose down
  echo "  (том с postgres сохранён; для полной очистки: docker compose down -v)"
}

ALL_CHECKS=(stand engine-auth engine-roundtrip scan-only grpc-max-message fio tools counters baseline)

if [ "$LIST" -eq 1 ]; then
  printf '%s\n' "${ALL_CHECKS[@]}"
  exit 0
fi

[ "$DO_DOWN" -eq 1 ] && { down_stand; exit 0; }
[ "$DO_UP" -eq 1 ] && up_stand

command -v curl >/dev/null || { echo "нужен curl" >&2; exit 2; }
command -v jq >/dev/null || { echo "нужен jq" >&2; exit 2; }
command -v docker >/dev/null || { echo "нужен docker" >&2; exit 2; }

printf '%s guardrails-llm-filter: проверка фиксов%s\n' "$BLD" "$RST"
printf '  API-1 :%s  API-2 :%s  data-plane :%s/:%s  engine :%s\n' \
  "$API1" "$API2" "$GW1" "$GW2" "$ENGINE1"
printf '  capture: %s\n' "$CAPTURE"

if [ "$(code -m 3 "$API1_URL/v1/health")" != "200" ]; then
  echo "${RED}стенд не отвечает на $API1_URL/v1/health — запустите ./test-fixes.sh --up${RST}" >&2
  exit 1
fi

: > "$CAPTURE" 2>/dev/null || true

started="$(date +%s)"
for c in "${ALL_CHECKS[@]}"; do
  has_check "$c" && "check_${c//-/_}"
done
elapsed=$(( $(date +%s) - started ))

section "итог"
printf '  пройдено: %s%d%s, провалено: %s%d%s, время: %ss\n' \
  "$GRN" "$PASS" "$RST" "$([ "$FAIL" -gt 0 ] && printf '%s' "$RED")" "$FAIL" "$RST" "$elapsed"
if [ "$FAIL" -gt 0 ]; then
  printf '\n  провалившиеся проверки:\n'
  for f in "${FAILURES[@]}"; do printf '    - %s\n' "$f"; done
  exit 1
fi
printf '  %sвсе проверки пройдены%s\n' "$GRN" "$RST"
