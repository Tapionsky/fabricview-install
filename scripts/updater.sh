#!/usr/bin/env bash
# Actualizador del servidor: une el botón «Actualizar» de la web con scripts/update.sh.
#
#   scripts/updater.sh check     comprueba la última versión publicada y escribe .control/status.json
#   scripts/updater.sh process   atiende las peticiones de la web (.control/inbox/*.json)
#   scripts/updater.sh watch     bucle de `process` + `check` (sin systemd, p. ej. en desarrollo)
#
# En producción lo lanzan las unidades de systemd que instala `sudo scripts/install-updater.sh`:
# una unidad *path* vigila .control/inbox y un *timer* comprueba versiones cada hora.
# La API nunca ejecuta nada en el host: solo deja una petición con un número de versión, que aquí
# se valida otra vez (formato X.Y.Z y tag existente en el repositorio).
set -euo pipefail

# git checkout puede reescribir este fichero durante una actualización: se ejecuta desde una copia.
if [[ -z "${FV_UPDATER_ROOT:-}" ]]; then
  FV_UPDATER_ROOT="$(cd "$(dirname "$0")/.." && pwd)"; export FV_UPDATER_ROOT
  tmp=$(mktemp)
  cp "$0" "$tmp"
  exec bash "$tmp" "$@"
fi
trap 'rm -f "$0"' EXIT
cd "$FV_UPDATER_ROOT"

CTL="$FV_UPDATER_ROOT/.control"
INBOX="$CTL/inbox"
mkdir -p "$INBOX"
command -v python3 >/dev/null || { echo "Falta python3" >&2; exit 1; }
command -v timeout >/dev/null || timeout() { shift; "$@"; }  # macOS sin coreutils

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
envval() { [[ -f .env ]] && grep -E "^$1=" .env | tail -n1 | cut -d= -f2- || true; }

# Escribe JSON de forma atómica. Uso: json_write FICHERO <<< '{"clave": …}' (se valida con python).
json_write() {
  local file="$1" tmpf
  tmpf=$(mktemp "$CTL/.tmp.XXXXXX")
  python3 -c 'import json,sys; json.dump(json.load(sys.stdin), sys.stdout, ensure_ascii=False, indent=1)' > "$tmpf"
  chmod 644 "$tmpf"
  mv -f "$tmpf" "$file"
}

# Estado de la actualización (lo lee la web). Uso: set_state estado versión desde mensaje paso
set_state() {
  STATE="$1" VERSION_="$2" FROM="$3" MESSAGE="$4" STEP="${5:-}" STARTED="${STARTED_AT:-}" BY="${REQUESTED_BY:-}" NOW="$(now)" \
  python3 - <<'PY' | json_write "$CTL/state.json"
import json, os
st = os.environ["STATE"]
out = {"state": st, "version": os.environ["VERSION_"], "from": os.environ["FROM"], "message": os.environ["MESSAGE"],
       "step": os.environ["STEP"], "started_at": os.environ["STARTED"] or os.environ["NOW"],
       "requested_by": os.environ["BY"]}
if st in ("success", "failed"):
    out["finished_at"] = os.environ["NOW"]
print(json.dumps(out))
PY
}

latest_tag() {
  git tag -l 'v*' --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -n1 || true
}

# ¿Está publicada la imagen? (--insecure solo como segundo intento: registros espejo por HTTP;
# la descarga real la hace el demonio de Docker con su propia configuración).
image_exists() {
  timeout 60 docker manifest inspect "$1" >/dev/null 2>&1 && return 0
  [[ "$1" == ghcr.io/* ]] && return 1  # GHCR siempre es HTTPS: no hay segundo intento
  timeout 30 docker manifest inspect --insecure "$1" >/dev/null 2>&1
}

cmd_check() {
  local current latest ready=false error="" registry
  current=$(envval FABRIC_VERSION)
  if [[ -d .git ]]; then
    if ! timeout 90 git fetch --tags --force --quiet origin 2>"$CTL/.fetch.err"; then
      error="No se pudo consultar el repositorio: $(head -c 300 "$CTL/.fetch.err" | tr '\n' ' ')"
    fi
    rm -f "$CTL/.fetch.err"
    latest=$(latest_tag); latest=${latest#v}
  else
    error="Esta instalación no es un clon de git: actualiza con scripts/update.sh X.Y.Z"
    latest=""
  fi
  registry=$(envval FABRIC_REGISTRY); registry=${registry:-ghcr.io/tapionsky}
  if [[ -n "$latest" && "$(envval FABRIC_UPDATE_MODE)" == "build" ]]; then
    ready=true  # se compila en el servidor: no depende del registro
  elif [[ -n "$latest" ]] && command -v docker >/dev/null; then
    if image_exists "$registry/fabricview-backend:$latest" && image_exists "$registry/fabricview-frontend:$latest"; then
      ready=true
    fi
  fi
  # Novedades: asuntos de los commits entre tags más recientes que la versión instalada (máx. 10 versiones).
  CURRENT="$current" LATEST="$latest" READY="$ready" ERROR="$error" NOW="$(now)" python3 - <<'PY' | json_write "$CTL/status.json"
import json, os, re, subprocess

def vkey(v):
    m = re.match(r"^v?(\d+)\.(\d+)\.(\d+)", v or "")
    return tuple(map(int, m.groups())) if m else ()

def git(*args):
    try:
        return subprocess.run(["git", *args], capture_output=True, text=True, timeout=30).stdout.strip()
    except Exception:
        return ""

cur = os.environ["CURRENT"]
tags = [t for t in git("tag", "-l", "v*", "--sort=-v:refname").splitlines() if re.match(r"^v\d+\.\d+\.\d+$", t)]
newer = [t for t in tags if vkey(t) > vkey(cur)][:10]
changelog = []
for t in newer:
    idx = tags.index(t)
    prev = tags[idx + 1] if idx + 1 < len(tags) else None
    rng = f"{prev}..{t}" if prev else t
    # Repositorio de instalación: las novedades vienen en RELEASE_NOTES.txt de cada versión.
    notes = git("show", f"{t}:RELEASE_NOTES.txt")
    if notes:
        subjects = [ln.strip().lstrip("-• ").strip() for ln in notes.splitlines() if ln.strip()][:40]
    else:
        subjects = [s for s in git("log", "--no-merges", "--format=%s", "-n", "40", rng).splitlines() if s]
    changelog.append({"version": t[1:], "date": git("log", "-1", "--format=%cs", t) or None, "changes": subjects})
print(json.dumps({
    "current": cur, "latest": os.environ["LATEST"] or None, "latest_ready": os.environ["READY"] == "true",
    "checked_at": os.environ["NOW"], "error": os.environ["ERROR"] or None, "changelog": changelog,
}))
PY
  echo "Comprobado: instalada ${current:-?} · última ${latest:-ninguna} · imágenes listas: $ready${error:+ · $error}"
}

cmd_update() {
  local req="$1" version from
  # La petición se valida y se borra antes de hacer nada (así nunca se repite en bucle).
  version=$(python3 -c '
import json, re, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
v = str(d.get("version", ""))
print(v if re.fullmatch(r"[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}", v) else "")' "$req")
  REQUESTED_BY=$(python3 -c 'import json,sys
try: print(str(json.load(open(sys.argv[1])).get("requested_by",""))[:200])
except Exception: print("")' "$req")
  rm -rf "$req"
  export REQUESTED_BY
  STARTED_AT=$(now); export STARTED_AT
  from=$(envval FABRIC_VERSION)
  if [[ -z "$version" ]]; then
    set_state failed "" "$from" "Petición de actualización no válida"
    return 0
  fi
  if [[ -n "$from" ]] && ! python3 -c 'import sys
k = lambda v: tuple(int(x) for x in v.split("-")[0].split("."))
try:
    sys.exit(0 if k(sys.argv[1]) > k(sys.argv[2]) else 1)
except ValueError:
    sys.exit(0)' "$version" "$from"; then
    set_state failed "$version" "$from" "Desde la web solo se puede actualizar a una versión más reciente que ${from}"
    return 0
  fi
  if [[ -d .git ]] && ! git rev-parse -q --verify "refs/tags/v${version}" >/dev/null; then
    timeout 90 git fetch --tags --force --quiet origin || true
    if ! git rev-parse -q --verify "refs/tags/v${version}" >/dev/null; then
      set_state failed "$version" "$from" "La versión ${version} no existe en el repositorio"
      return 0
    fi
  fi

  set_state running "$version" "$from" "Actualizando de ${from} a ${version}" "Preparando"
  # Si systemd lo mata (tiempo agotado, apagado…), que la web no se quede en «actualizando».
  trap 'set_state failed "$version" "$from" "Actualización interrumpida en el servidor; revisa el registro" "Interrumpida"; exit 1' TERM INT HUP
  echo "== $(now) · actualización ${from} → ${version} (pedida por ${REQUESTED_BY:-?}) ==" > "$CTL/update.log"
  chmod 644 "$CTL/update.log"
  # update.sh anota cada paso en state.json (FV_STATE_FILE) para que la web muestre el progreso.
  if FV_STATE_FILE="$CTL/state.json" bash "$FV_UPDATER_ROOT/scripts/update.sh" "$version" >> "$CTL/update.log" 2>&1; then
    set_state success "$version" "$from" "FabricView ${version} instalado correctamente" "Completado"
  else
    local msg
    msg=$(grep -E '^(✖|ERROR|Error|La API|No se|Falta|Hay )' "$CTL/update.log" | tail -n1 || true)
    set_state failed "$version" "$from" "${msg:-La actualización ha fallado: revisa el registro}" "Error"
  fi
  cmd_check >/dev/null 2>&1 || true
}

take_lock() {
  exec 9>"$CTL/.lock"
  command -v flock >/dev/null || return 0  # macOS: sin bloqueo (solo desarrollo)
  flock -w "${1:-0}" 9
}

cmd_process() {
  take_lock 0 || { echo "Ya hay un proceso del actualizador en marcha"; return 0; }
  # Solo se aceptan ficheros normales; cualquier otra cosa (enlaces, carpetas, FIFO…) se elimina
  # para que la unidad path de systemd no se dispare en bucle.
  for f in update.json check.json; do
    if [[ -e "$INBOX/$f" || -L "$INBOX/$f" ]] && { [[ -L "$INBOX/$f" ]] || [[ ! -f "$INBOX/$f" ]]; }; then
      rm -rf "${INBOX:?}/$f"
    fi
  done
  if [[ -f "$INBOX/update.json" ]]; then
    cmd_update "$INBOX/update.json"
  fi
  if [[ -f "$INBOX/check.json" ]]; then
    # La petición se borra al terminar: mientras existe, la web sabe que la comprobación sigue en marcha.
    cmd_check || true
    rm -f "$INBOX/check.json"
  fi
  find "$INBOX" -mindepth 1 -maxdepth 1 ! -name update.json ! -name check.json ! -name '.req-*' -exec rm -rf {} + 2>/dev/null || true
}

case "${1:-}" in
  check)
    # Espera a que termine una actualización en curso (git fetch/checkout simultáneos fallarían).
    take_lock 1800 || { echo "El actualizador está ocupado"; exit 0; }
    cmd_check ;;
  process) cmd_process ;;
  watch)
    echo "Vigilando $INBOX (Ctrl+C para salir)"
    last=0
    while true; do
      cmd_process
      if (( $(date +%s) - last > 3600 )); then cmd_check || true; last=$(date +%s); fi
      sleep 3
    done ;;
  *) sed -n '2,12p' "$FV_UPDATER_ROOT/scripts/updater.sh"; exit 1 ;;
esac
