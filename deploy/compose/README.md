# Стенд для проверки фиксов (`deploy/compose`)

Одноразовый стенд на docker compose: две реплики сервиса на общем Postgres,
mock-LLM, который **записывает всё, что до него дошло** после маскирования, и
набор проверок `test-fixes.sh`. Нужен, чтобы убедиться, что влитые в
`fork/main` фиксы работают вместе, а не только в юнит-тестах.

Это не боевой compose. Боевой (с nginx, шагом выката и т.п.) живёт в
deploy-репозитории; здесь всё опубликовано только на `127.0.0.1`.

## Топология

```
test-fixes.sh ──:8080──► guardrails-1 ─┐
              ──:8081──► guardrails-2 ─┼──► mock-llm :8890 (capture + echo)
              ──:9080/9081  management API + /v1/metrics/summary
              ──:9100/9101  engine API (bearer-токен)
                       └──────────────┴──► postgres (общий стор: правила,
                                            настройки, аудит, masking state,
                                            распределённые счётчики)
```

Две реплики на одном сторе — не украшение: фикс #23 (распределённые счётчики)
проверяется только тогда, когда два процесса пишут в общий стор, а
`/v1/metrics/summary` обязан отдавать одинаковые lifetime-числа с обоих.

## Быстрый старт

```sh
# 1. образ (или ./build.sh --no-push для версии с тегом по коммиту)
docker build -t guardrails-llm-filter:test .

# 2. стенд + прогон проверок
cd deploy/compose
cp .env.example .env
./test-fixes.sh --up
```

`--up` сам создаст `.env`, соберёт образ, если его нет, поднимет compose и
дождётся готовности management API.

Другие режимы:

```sh
./test-fixes.sh                 # прогнать проверки по уже поднятому стенду
./test-fixes.sh --list          # список проверок
./test-fixes.sh --only fio,tools
./test-fixes.sh --down          # остановить (том postgres сохраняется)
docker compose down -v          # остановить и стереть данные
```

Проверка на **том образе, который поедет на сервер** (а не на локальной
сборке):

```sh
GUARDRAILS_IMAGE=hub.edna.ru/genai/guardrails-llm-filter:20261006-1400-9accd7d \
  ./test-fixes.sh --up
```

## Что проверяется

| Проверка | Задача | Суть |
|---|---|---|
| `stand` | — | обе реплики живы, один и тот же билд, `/metrics` отвечает |
| `engine-auth` | #41 | `/v1/mask` без токена и с чужим токеном → 401 + `WWW-Authenticate`, `/v1/engine/version` — без токена |
| `engine-roundtrip` | #41 | `/v1/mask` не отдаёт оригиналы, `unmask(mask(x)) == x`, неизвестный `correlation_id` → 404, а не passthrough |
| `scan-only` | #20 | сервис поднимается и сканирует **без upstream вообще** (раньше падал), а при `DATA_PLANE_ENABLED=false` не поднимает gateway-листенер |
| `grpc-max-message` | #22 | ответ `/v1/scan` на ~5.5 MiB проходит через grpc-gateway; контрольный контейнер без `GUARDRAILS_GRPC_MAX_MESSAGE_BYTES` на том же запросе падает |
| `fio` | #35 | «Анна-Мария Ковалёва» и «Смирнов, Пётр Ильич» маскируются целиком (в теле для модели нет «Анна-» и «Смирнов,»), приветствие перед запятой не затягивается в совпадение |
| `tools` | #36 | определения инструментов маскируются в chat/completions, messages и responses; `name`, `type`, `format`, `required` остаются нетронутыми |
| `counters` | #23 | после трафика в обе реплики `/v1/metrics/summary` отдаёт одинаковый `requests_masked_total`, равный сумме трафика обеих реплик |
| `baseline` | — | обычный путь не сломан: `/healthz`, `/readyz`, `/metrics`, `/v1/scan`, полный round-trip через прокси, аудит |

Оракул «что увидела модель» — файл `capture/requests.jsonl`: mock-LLM
дописывает туда каждый полученный запрос, ключ — заголовок `X-Test-Id`.
Посмотреть глазами:

```sh
jq -c 'select(.test_id|startswith("fio-")) | {path, body}' capture/requests.jsonl
```

## Порты

| Порт | Что | Кому |
|---|---|---|
| 8080 / 8081 | data plane реплик 1 и 2 | только 127.0.0.1 |
| 9080 / 9081 | management API + `/v1/metrics/summary` (без аутентификации!) | только 127.0.0.1 |
| 9090 / 9091 | Prometheus | только 127.0.0.1 |
| 9100 / 9101 | engine API (bearer) | только 127.0.0.1 |
| 8890 | mock-LLM | только 127.0.0.1 |

Порты переопределяются через `.env` (`GW1_PORT`, `API1_PORT`, …), переменные
`*_ENGINE_API_TOKEN` и `GUARDRAILS_IMAGE` читает и compose, и `test-fixes.sh`.

## Полезное

```sh
docker compose logs -f guardrails-1     # логи реплики
docker compose ps                       # что поднято
docker compose --profile redis up -d    # поднять ещё и redis
```

Профиль `redis` — на случай, если нужно прогнать engine API и счётчики на
втором бэкенде: замените в `.env` `GUARDRAILS_STORE_BACKEND=redis` и
`GUARDRAILS_STORE_REDIS_ADDR=redis:6379` (в compose эти переменные пока не
проброшены — стенд использует postgres).

## Что из этого стоит перенести в боевой compose

Стенд задаёт переменные, которых в боевом compose ещё нет. При выкате этих
фиксов в боевой файл нужно добавить:

```yaml
# #23: на postgres/redis "auto" включает распределённые счётчики
GUARDRAILS_METRICS_SUMMARY_SOURCE: auto
# #20: false — режим компонента без gateway и без требования upstream
GUARDRAILS_DATA_PLANE_ENABLED: "true"
# #41: engine-only API со своим токеном (по умолчанию выключен)
GUARDRAILS_ENGINE_API_ADDR: ":9100"       # если нужен — и опубликовать порт
GUARDRAILS_ENGINE_API_TOKEN: ${GUARDRAILS_ENGINE_API_TOKEN}
```

`GUARDRAILS_GRPC_MAX_MESSAGE_BYTES` в боевом compose уже есть (100000000) —
фикс #22 именно про то, что теперь эта настройка действительно ограничивает
и приём, и отправку на обеих сторонах grpc-gateway-хопа.
