#!/usr/bin/env bash
# Сборка образа guardrails-llm-filter и отправка в hub.edna.ru.
#
#   ./build.sh                 собрать и запушить (тег по дате+коммиту)
#   ./build.sh --tag v1.2.0    собрать и запушить с явным тегом
#   ./build.sh --no-push       только собрать, локально
#   ./build.sh --platform linux/arm64   собрать под другую платформу
#
# Выполняется НА РАЗРАБОТЧЕСКОЙ МАШИНЕ. На сервере сборки нет вовсе: туда
# едет готовый образ, compose-файл и .env. Причина та же, что у соседних
# сервисов: сборка требует исходников, node и Go-тулчейна, сети к npm и
# proxy.golang.org, и каждый из этих шагов на боевом сервере — операция,
# которую делают руками и потому неправильно.
#
# Контекст сборки — сам репозиторий: в отличие от mcp-bpm, общих библиотек
# рядом нет, Dockerfile самодостаточен (frontend + Go-бинарь + distroless).
set -Eeuo pipefail

# Вывод в UTF-8 независимо от локали: на чистой системе LANG не задан.
export PYTHONIOENCODING=utf-8 LC_ALL=C.UTF-8 LANG=C.UTF-8

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REGISTRY="${REGISTRY:-hub.edna.ru}"
# Переопределяется, если сервис должен лежать в другом пространстве имён:
#   IMAGE_PATH=genai/guardrails-llm-filter ./build.sh
IMAGE_PATH="${IMAGE_PATH:-genai/guardrails-llm-filter}"
IMAGE="$REGISTRY/$IMAGE_PATH"

PUSH=1
TAG=""
# Платформа ЦЕЛЕВОГО сервера, а не машины сборки. На Apple Silicon
# `docker build` по умолчанию делает linux/arm64, и такой образ на
# amd64-сервере падает с «exec format error» — контейнер создаётся,
# pull проходит, ошибка вылезает только при запуске.
PLATFORM="${PLATFORM:-linux/amd64}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="${2:-}"; shift 2 ;;
    --platform) PLATFORM="${2:-}"; shift 2 ;;
    --no-push) PUSH=0; shift ;;
    -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
done

red() { printf '\033[31m%s\033[0m\n' "$*"; }
grn() { printf '\033[32m%s\033[0m\n' "$*"; }
ylw() { printf '\033[33m%s\033[0m\n' "$*"; }
say() { printf '\n\033[34m==>\033[0m %s\n' "$*"; }
die() { red "[FAIL] $*"; exit 1; }

command -v docker >/dev/null || die "docker не найден"
[[ -f "$REPO_DIR/Dockerfile" ]] || die "нет $REPO_DIR/Dockerfile"

# Тег по умолчанию — дата и короткий хеш коммита. Дата нужна, чтобы теги
# сортировались; хеш — чтобы по образу можно было найти исходник. Тег
# latest ставится дополнительно, но разворачивать по нему нельзя: он не
# говорит, что именно запущено.
COMMIT=""
if [[ -z "$TAG" ]]; then
  stamp="$(date +%Y%m%d-%H%M)"
  if git -C "$REPO_DIR" rev-parse --short HEAD >/dev/null 2>&1; then
    COMMIT="$(git -C "$REPO_DIR" rev-parse --short HEAD)"
    dirty=""
    # Грязное дерево в теге — чтобы «собрал с несохранёнными правками» было
    # видно в docker images, а не выяснялось через неделю на сервере.
    git -C "$REPO_DIR" diff --quiet HEAD 2>/dev/null || dirty="-dirty"
    TAG="${stamp}-${COMMIT}${dirty}"
  else
    TAG="$stamp"
  fi
else
  COMMIT="$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo none)"
fi
[[ -n "$COMMIT" ]] || COMMIT=none
VER="${TAG}"
DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

say "Сборка $IMAGE:$TAG"
echo "  контекст  : $REPO_DIR"
echo "  платформа : $PLATFORM"
echo "  version   : $VER  commit: $COMMIT"

# buildx умеет --platform с эмуляцией; классический `docker build`
# на чужой архитектуре молча соберёт образ под свою.
docker buildx version >/dev/null 2>&1 || die "нужен docker buildx (входит в Docker Desktop и docker-buildx-plugin)"

# --load кладёт образ в локальный демон, иначе buildx собирает в кэш и
# образа не будет ни в `docker images`, ни для самопроверки ниже.
docker buildx build \
  --platform "$PLATFORM" \
  --load \
  -f "$REPO_DIR/Dockerfile" \
  --build-arg "VERSION=$VER" \
  --build-arg "COMMIT=$COMMIT" \
  --build-arg "DATE=$DATE" \
  -t "$IMAGE:$TAG" \
  -t "$IMAGE:latest" \
  "$REPO_DIR"

# Сверяем архитектуру СОБРАННОГО образа с запрошенной: тихое
# расхождение здесь и есть «exec format error» на сервере.
got="$(docker image inspect "$IMAGE:$TAG" --format '{{.Os}}/{{.Architecture}}')"
want="${PLATFORM%%/*}/$(echo "$PLATFORM" | cut -d/ -f2)"
[[ "$got" == "$want" ]] || die "образ собран как $got, запрошено $want"
echo "  платформа : $got"

grn "[ok] образ собран: $IMAGE:$TAG"

# Проверка образа до отправки. Runtime-слой distroless: ни shell, ни curl
# внутри нет, поэтому healthcheck только СНАРУЖИ, с хоста, через
# опубликованный порт. Сервис поднимаем в компонентном режиме
# (GUARDRAILS_DATA_PLANE_ENABLED=false) — так ему не нужен upstream, и
# проверяется ровно то, что должно отвечать сразу после выката.
HOST_ARCH="linux/$(docker version --format '{{.Server.Arch}}' 2>/dev/null || echo unknown)"
say "Проверка образа"
cname="guardrails-selftest-$$"
docker rm -f "$cname" >/dev/null 2>&1 || true
docker run -d --name "$cname" \
  -e GUARDRAILS_LOG_LEVEL=warn \
  -e GUARDRAILS_DATA_PLANE_ENABLED=false \
  -e GUARDRAILS_API_ADDR=:9080 \
  -e GUARDRAILS_STORE_BACKEND=in_memory \
  -p 127.0.0.1::9080 \
  "$IMAGE:$TAG" >/dev/null

ok=0
for _ in $(seq 1 30); do
  if docker port "$cname" 9080 >/dev/null 2>&1; then
    hostport="$(docker port "$cname" 9080 | head -1 | sed 's/.*://')"
    if curl -fsS -m 2 "http://127.0.0.1:$hostport/v1/health" >/dev/null 2>&1; then ok=1; break; fi
  fi
  sleep 1
done

if [[ "$ok" -ne 1 ]]; then
  logs="$(docker logs --tail 40 "$cname" 2>&1 || true)"
  docker rm -f "$cname" >/dev/null 2>&1 || true
  # «exec format error» под неродной платформой означает отсутствие
  # binfmt/qemu на машине сборки, а не плохой образ: на сервере нужной
  # архитектуры он запустится. Считать это провалом сборки нельзя.
  if [[ "$PLATFORM" != "$HOST_ARCH" && "$logs" == *"exec format error"* ]]; then
    ylw "[warn] образ $PLATFORM не запускается на $HOST_ARCH (нет binfmt/qemu)"
    echo "       самопроверка /v1/health пропущена — проверьте после выката:" >&2
    echo "       deploy/compose/test-fixes.sh" >&2
  else
    red "[FAIL] образ не отвечает на /v1/health — логи:"
    printf '%s\n' "$logs" >&2
    exit 1
  fi
else
  port="$(docker port "$cname" 9080 | head -1 | sed 's/.*://')"
  ver="$(curl -fsS -m 3 "http://127.0.0.1:$port/v1/version" 2>/dev/null || true)"
  grn "[ok] контейнер поднимается и отвечает на /v1/health"
  # Билд-идентичность: образ должен рассказывать, из какого коммита он собран.
  if [[ -n "$ver" ]]; then
    echo "  /v1/version: $(printf '%s' "$ver" | tr -d '\n' | head -c 200)"
    case "$ver" in
      *"$COMMIT"*) : ;;
      *) ylw "[warn] в /v1/version нет коммита $COMMIT — проверьте build-args" ;;
    esac
  fi
fi
docker rm -f "$cname" >/dev/null 2>&1 || true

if [[ "$PUSH" -eq 0 ]]; then
  say "Готово (без отправки)"
  echo "  $IMAGE:$TAG"
  exit 0
fi

say "Отправка в $REGISTRY"
# Логин не делаем за человека: docker login пишет креды в ~/.docker/config.json,
# и делать это молча из скрипта неправильно. Проверяем и объясняем.
if ! docker push "$IMAGE:$TAG"; then
  die "push не прошёл. Если дело в доступе: docker login $REGISTRY"
fi
docker push "$IMAGE:latest" >/dev/null || true

grn "[ok] отправлено: $IMAGE:$TAG"
cat <<EOF

Дальше — развернуть и проверить:

  cd deploy/compose
  cp .env.example .env
  GUARDRAILS_IMAGE=$IMAGE:$TAG docker compose up -d
  ./test-fixes.sh

Тег запомните: разворачивать по latest нельзя — по нему не видно,
что именно работает на сервере.
EOF
