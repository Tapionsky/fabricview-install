#!/usr/bin/env bash
# Actualiza FabricView en el servidor.
#
#   scripts/update.sh            → última versión publicada (último tag vX.Y.Z)
#   scripts/update.sh 0.2.0      → versión concreta (también sirve para volver atrás*)
#   scripts/update.sh --build    → compila las imágenes en el propio servidor (sin registro;
#                                  o FABRIC_UPDATE_MODE=build en .env para hacerlo siempre)
#
# Pasos: copia de seguridad → código de despliegue del tag → imágenes → reinicio → comprobación.
# Si algo falla antes de reiniciar no se toca nada; si la versión nueva no arranca, se vuelve
# automáticamente a la anterior.
# *Las migraciones de base de datos solo van hacia delante: para volver a una versión anterior
#  con cambios de esquema, restaura además la copia (scripts/restore.sh).
set -euo pipefail

# El checkout del tag puede reescribir este mismo fichero: se ejecuta desde una copia temporal.
if [[ -z "${FV_UPDATE_ROOT:-}" ]]; then
  FV_UPDATE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"; export FV_UPDATE_ROOT
  tmp=$(mktemp)
  cp "$0" "$tmp"
  exec bash "$tmp" "$@"
fi
trap 'rm -f "$0"' EXIT
cd "$FV_UPDATE_ROOT"

BUILD=0
VERSION=""
for arg in "$@"; do
  case "$arg" in
    --build) BUILD=1 ;;
    -h|--help) sed -n "2,14p" scripts/update.sh; exit 0 ;;
    -*) echo "Opción desconocida: $arg" >&2; exit 1 ;;
    *) VERSION="${arg#v}" ;;
  esac
done
if [[ -n "$VERSION" && ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "✖ Versión no válida: $VERSION (formato X.Y.Z)" >&2; exit 1
fi

[[ -f .env ]] || { echo "✖ Falta .env (ejecuta scripts/init-env.sh)" >&2; exit 1; }
# FABRIC_UPDATE_MODE=build en .env: siempre compilar en el servidor (instalaciones sin registro).
[[ "$(grep -E '^FABRIC_UPDATE_MODE=' .env | tail -n1 | cut -d= -f2-)" == "build" ]] && BUILD=1

step() {
  printf '\n\033[1;36m▸ %s\033[0m\n' "$*"
  # Progreso para la web (lo pasa scripts/updater.sh).
  if [[ -n "${FV_STATE_FILE:-}" && -f "$FV_STATE_FILE" ]]; then
    python3 - "$FV_STATE_FILE" "$*" <<'PY' || true
import json, os, sys, tempfile
path, step = sys.argv[1], sys.argv[2]
with open(path) as f:
    d = json.load(f)
d["step"] = step
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
with os.fdopen(fd, "w") as f:
    json.dump(d, f, ensure_ascii=False)
os.chmod(tmp, 0o644)
os.replace(tmp, path)
PY
  fi
}
fail() { echo "✖ $*" >&2; exit 1; }
set_env_version() {
  if grep -qE '^FABRIC_VERSION=' .env; then
    sed -i.bak "s|^FABRIC_VERSION=.*|FABRIC_VERSION=$1|" .env && rm -f .env.bak
  else
    echo "FABRIC_VERSION=$1" >> .env
  fi
}
api_healthy() {
  local id
  for _ in $(seq 1 "${1:-40}"); do
    id=$(docker compose ps -q api 2>/dev/null || true)
    if [[ -n "$id" && "$(docker inspect -f '{{.State.Health.Status}}' "$id" 2>/dev/null)" == "healthy" ]]; then
      return 0
    fi
    sleep 3
  done
  return 1
}

# Versión que informa la API en marcha (vacía si no responde).
running_version() {
  docker compose exec -T api python -c "import json,urllib.request;print(json.load(urllib.request.urlopen('http://127.0.0.1:8000/api/health',timeout=5))['version'])" 2>/dev/null || true
}
# Servicios de la lista que no están en marcha.
services_down() {
  local running s out=""
  running=$(docker compose ps --status running --services 2>/dev/null || true)
  for s in "$@"; do grep -qx "$s" <<<"$running" || out="${out:+$out }$s"; done
  echo "$out"
}

# Carpeta compartida con la API para el botón «Actualizar» (ver scripts/updater.sh). Si Docker la
# creó antes como root no se puede tocar aquí: install-updater.sh la arregla.
mkdir -p .control/inbox 2>/dev/null || echo "Aviso: no se puede crear .control/inbox (ejecuta sudo scripts/install-updater.sh)" >&2

envget() { grep -E "^$1=" .env | tail -n1 | cut -d= -f2- || true; }
PGU=$(envget POSTGRES_USER); PGU=${PGU:-fabricview}
PGD=$(envget POSTGRES_DB); PGD=${PGD:-fabricview}
schema_rev() {
  docker compose exec -T db psql -U "$PGU" -d "$PGD" -Atc "SELECT version_num FROM alembic_version" 2>/dev/null || true
}

prev_version=$(grep -E '^FABRIC_VERSION=' .env | cut -d= -f2 || true)
FABRIC_PORTS_HINT="$(envget FABRIC_HTTP_PORT)/$(envget FABRIC_HTTPS_PORT)"; FABRIC_PORTS_HINT=${FABRIC_PORTS_HINT:-80/443}
prev_ref=""

step "Copia de seguridad de la base de datos"
backup_out=$(scripts/backup.sh) || fail "La copia de seguridad ha fallado; no se actualiza"
echo "$backup_out"
backup_file=$(printf '%s\n' "$backup_out" | sed -n 's/^Copia creada: \([^ ]*\) .*/\1/p')
schema_before=$(schema_rev)

if [[ -d .git ]]; then
  step "Descargando cambios del repositorio"
  if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    git status --short --untracked-files=no >&2
    fail "Hay cambios locales en ficheros del repositorio: guárdalos o descártalos (git stash) antes de actualizar"
  fi
  prev_ref=$(git rev-parse HEAD)
  git fetch --tags --force --quiet origin || fail "No se pudo descargar del repositorio (¿red o credenciales?)"
  if [[ -z "$VERSION" ]]; then
    VERSION=$(git tag -l 'v*' --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -n1 | sed 's/^v//' || true)
  fi
  [[ -n "$VERSION" ]] || fail "No hay versiones publicadas (tags vX.Y.Z)"
  git rev-parse -q --verify "refs/tags/v${VERSION}" >/dev/null || fail "No existe la versión ${VERSION}"
  git -c advice.detachedHead=false checkout --quiet "v${VERSION}"
fi
[[ -n "$VERSION" ]] || fail "Indica la versión: scripts/update.sh 0.2.0"

# Deshace el checkout y la versión de .env (antes de reiniciar nada).
undo_checkout() {
  set_env_version "${prev_version}"
  if [[ -n "$prev_ref" ]]; then git -c advice.detachedHead=false checkout --quiet "$prev_ref" || true; fi
}

step "Versión: ${prev_version:-?} → ${VERSION}"
set_env_version "$VERSION"

# Con imágenes del registro nunca se compila (la instalación pública no incluye el código fuente).
UP_FLAGS=(--no-build)
[[ $BUILD -eq 1 ]] && UP_FLAGS=()
if [[ $BUILD -eq 1 ]]; then
  [[ -d backend && -d frontend ]] || { undo_checkout; fail "Esta instalación no incluye el código fuente: no se puede compilar (usa FABRIC_UPDATE_MODE=registry)"; }
  step "Compilando imágenes en este servidor"
  docker compose build --pull || { undo_checkout; fail "No se pudieron compilar las imágenes; no se ha cambiado nada"; }
else
  step "Descargando imágenes"
  docker compose pull --quiet || {
    undo_checkout
    fail "No se pudieron descargar las imágenes ${VERSION} (¿aún publicándose o falta docker login ghcr.io?); no se ha cambiado nada"
  }
fi

step "Reiniciando servicios"
# Si la API nueva no queda sana, `up` termina con error (dependencias service_healthy): se sigue
# igualmente para poder comprobarlo y volver atrás.
docker compose up -d --remove-orphans ${UP_FLAGS[@]+"${UP_FLAGS[@]}"} || true

step "Comprobando la API"
if api_healthy 40 && [[ "$(running_version)" == "$VERSION" ]]; then
  echo "API sana · FabricView ${VERSION} en marcha"
  # El proxy y la web no afectan a la API: si no arrancan (p. ej. puerto ocupado) no se vuelve atrás,
  # pero se informa en lugar de dar la actualización por buena en silencio.
  missing=$(services_down proxy frontend)
  docker image prune -f >/dev/null || true
  [[ -z "$missing" ]] || fail "La API funciona, pero no arranca: ${missing}. ¿Puerto ${FABRIC_PORTS_HINT} ocupado? Revisa: docker compose logs --tail 50 ${missing}"
  exit 0
fi

docker compose logs --tail 60 api >&2 || true
if [[ -n "$prev_version" && "$prev_version" != "$VERSION" ]]; then
  step "La versión ${VERSION} no arranca: volviendo a ${prev_version}"
  undo_checkout
  schema_after=$(schema_rev)
  if [[ -n "$schema_before" && -n "$schema_after" && "$schema_after" != "$schema_before" ]]; then
    # La versión nueva ya migró la base de datos: la anterior no la entendería. Se restaura la copia.
    if [[ -n "$backup_file" && -f "$backup_file" ]]; then
      step "Restaurando la copia previa (el esquema cambió de ${schema_before:-?} a ${schema_after})"
      FABRIC_RESTORE_YES=1 scripts/restore.sh "$backup_file" || true
    else
      fail "La versión ${VERSION} no arrancó y cambió el esquema, pero no hay copia que restaurar. Revisa backups/"
    fi
  fi
  docker compose up -d --remove-orphans ${UP_FLAGS[@]+"${UP_FLAGS[@]}"} || true
  if api_healthy 40; then
    fail "La API de la versión ${VERSION} no arrancó; se ha vuelto a ${prev_version} (copia de seguridad: ${backup_file:-backups/})"
  fi
fi
fail "La API no ha arrancado bien. Revisa: docker compose logs --tail 100 api"
