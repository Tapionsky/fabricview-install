#!/usr/bin/env bash
# Instalador de FabricView en un Ubuntu Server limpio (26.04 o 24.04), con un solo comando:
#
#   curl -fsSL https://raw.githubusercontent.com/Tapionsky/fabricview-install/main/install.sh | sudo bash
#
# Instala Docker, descarga FabricView en /opt/fabricview, genera la configuración con secretos
# aleatorios, activa el botón «Actualizar» de la web y arranca la última versión publicada.
# Volver a ejecutarlo es seguro: si ya está instalado, solo lo actualiza.
#
# Opciones (variables de entorno, todas opcionales), p. ej. «… | sudo FV_PORT=8080 bash»:
#   FV_COMPANY="Mi empresa"   FV_SITE="Sede Central"   FV_ADMIN_EMAIL=admin@empresa.com
#   FV_PORT=80                puerto web (HTTP)      FV_HTTPS_PORT=443   puerto HTTPS
#   FV_DEMO=1                 datos de ejemplo (sin equipos reales)
#   FV_VERSION=0.3.0          versión concreta (por defecto, la última)
#   FV_DIR=/opt/fabricview    carpeta de instalación
#   FV_REGISTRY=…             registro de imágenes alternativo (espejo propio)
set -euo pipefail

REPO_URL="${FV_REPO_URL:-https://github.com/Tapionsky/fabricview-install.git}"
DIR="${FV_DIR:-/opt/fabricview}"
SVC_USER="fabricview"

# Todo va dentro de main(): con «curl | bash» así no se ejecuta nada si la descarga se corta a medias.
main() {
  say() { printf '\n\033[1;36m▸ %s\033[0m\n' "$*"; }
  ok() { printf '  \033[32m✔\033[0m %s\n' "$*"; }
  warn() { printf '  \033[33m!\033[0m %s\n' "$*" >&2; }
  die() { printf '\n\033[1;31m✖ %s\033[0m\n' "$*" >&2; exit 1; }
  # Como el usuario de servicio y con su HOME (docker y git leen su configuración de ahí).
  as_svc() { runuser -u "$SVC_USER" -- env HOME="/var/lib/${SVC_USER}" "$@"; }

  [[ $EUID -eq 0 ]] || die "Ejecuta el instalador con sudo:  curl -fsSL … | sudo bash"
  [[ -r /etc/os-release ]] || die "No se reconoce el sistema operativo"
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || die "FabricView se instala en Ubuntu Server (detectado: ${PRETTY_NAME:-desconocido})"
  case "$(dpkg --print-architecture)" in
    amd64 | arm64) ;;
    *) die "Arquitectura no soportada: $(dpkg --print-architecture) (se necesita amd64 o arm64)" ;;
  esac
  [[ "$DIR" == /* && "$DIR" != *[[:space:]]* ]] || die "FV_DIR debe ser una ruta absoluta sin espacios"
  if [[ -n "${FV_VERSION:-}" && ! "${FV_VERSION#v}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    die "FV_VERSION no válida: ${FV_VERSION} (formato X.Y.Z)"
  fi
  local pv
  for pv in FV_PORT FV_HTTPS_PORT; do
    if [[ -n "${!pv:-}" ]] && ! [[ "${!pv}" =~ ^[0-9]+$ && "${!pv}" -ge 1 && "${!pv}" -le 65535 ]]; then
      die "${pv} no válido: ${!pv}"
    fi
  done

  echo
  echo "  ███  FabricView · instalación en ${PRETTY_NAME}"
  local mem_mb disk_gb
  mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
  disk_gb=$(df -Pm / | awk 'NR==2 {print int($4/1024)}')
  ((mem_mb >= 1800)) || warn "Memoria: ${mem_mb} MB. Se recomiendan 4 GB (mínimo 2 GB)."
  ((disk_gb >= 10)) || warn "Espacio libre: ${disk_gb} GB. Se recomiendan 20 GB."

  say "Paquetes básicos"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl git openssl python3 >/dev/null
  ok "git, curl, openssl y python3"

  say "Docker"
  if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
    ok "Ya instalado: $(docker --version)"
  else
    install_docker
    ok "$(docker --version) · $(docker compose version --short)"
  fi
  systemctl enable --now docker >/dev/null 2>&1 || true
  docker info >/dev/null 2>&1 || die "Docker no responde (systemctl status docker)"

  say "Usuario de servicio «${SVC_USER}»"
  if ! id "$SVC_USER" >/dev/null 2>&1; then
    useradd --system --create-home --home-dir "/var/lib/${SVC_USER}" --shell /usr/sbin/nologin "$SVC_USER"
  fi
  usermod -aG docker "$SVC_USER"
  ok "Sin acceso por consola; solo gestiona FabricView"

  say "Descargando FabricView en ${DIR}"
  local fresh=1
  if [[ -d "$DIR/.git" ]]; then
    fresh=0
    chown -R "$SVC_USER:$SVC_USER" "$DIR"
    as_svc git -C "$DIR" fetch --tags --force --quiet origin || die "No se pudo contactar con ${REPO_URL}"
    ok "Ya existía: se actualizará"
  else
    [[ ! -e "$DIR" || -z "$(ls -A "$DIR" 2>/dev/null)" ]] || die "${DIR} existe y no está vacía (¿otra instalación?). Usa FV_DIR=/otra/ruta"
    install -d -o "$SVC_USER" -g "$SVC_USER" -m 0755 "$DIR"
    as_svc git clone --quiet "$REPO_URL" "$DIR" || die "No se pudo descargar ${REPO_URL} (¿hay acceso a Internet?)"
    ok "Descargado"
  fi
  local version="${FV_VERSION:-}"
  version="${version#v}"
  if [[ -z "$version" ]]; then
    version=$(as_svc git -C "$DIR" tag -l 'v*' --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -n1 | sed 's/^v//' || true)
  fi
  [[ -n "$version" ]] || die "No hay ninguna versión publicada todavía"
  as_svc git -C "$DIR" rev-parse -q --verify "refs/tags/v${version}" >/dev/null || die "No existe la versión ${version}"

  cd "$DIR"
  if [[ ! -f .env ]]; then
    say "Configuración"
    # init-env.sh de la versión a instalar (en la rama principal puede no existir aún).
    as_svc git -c advice.detachedHead=false checkout --quiet "v${version}"
    if [[ "${FV_DEMO:-0}" == "1" ]]; then as_svc scripts/init-env.sh --demo >/dev/null; else as_svc scripts/init-env.sh >/dev/null; fi
    set_env FABRIC_UPDATE_MODE registry
    [[ -n "${FV_REGISTRY:-}" ]] && set_env FABRIC_REGISTRY "$FV_REGISTRY"
    [[ -n "${FV_COMPANY:-}" ]] && set_env FABRIC_TENANT_NAME "$FV_COMPANY"
    [[ -n "${FV_SITE:-}" ]] && set_env FABRIC_SITE_NAME "$FV_SITE"
    [[ -n "${FV_ADMIN_EMAIL:-}" ]] && set_env FABRIC_ADMIN_EMAIL "$FV_ADMIN_EMAIL"
    [[ -n "${FV_PORT:-}" ]] && set_env FABRIC_HTTP_PORT "$FV_PORT"
    [[ -n "${FV_HTTPS_PORT:-}" ]] && set_env FABRIC_HTTPS_PORT "$FV_HTTPS_PORT"
    local tz
    tz=$(timedatectl show -p Timezone --value 2>/dev/null || true)
    [[ -n "$tz" && "$tz" != "Etc/UTC" && "$tz" != "UTC" ]] && set_env TZ "$tz"
    ok "Secretos aleatorios generados en ${DIR}/.env (permisos 600)"
  else
    ok "Se conserva la configuración existente (.env)"
  fi

  # Puertos web libres (si ya los usa FabricView, es una reinstalación y no cuenta).
  local p busy=""
  for p in "$(envget FABRIC_HTTP_PORT)" "$(envget FABRIC_HTTPS_PORT)"; do
    [[ -n "$p" ]] || continue
    if ss -Hltn "sport = :$p" 2>/dev/null | grep -q . && ! docker ps --format '{{.Names}} {{.Ports}}' | grep -q "proxy.*:$p->"; then
      busy="${busy:+$busy, }$p"
    fi
  done
  [[ -z "$busy" ]] || die "El puerto ${busy} ya está en uso por otro programa. Libéralo o elige otros: curl … | sudo FV_PORT=8080 FV_HTTPS_PORT=8443 bash (o cámbialos en ${DIR}/.env y repite)"

  say "Botón «Actualizar» de la web"
  scripts/install-updater.sh >/dev/null || warn "No se pudo instalar el actualizador (sudo ${DIR}/scripts/install-updater.sh)"
  ok "Comprobará cada hora si hay versión nueva"

  say "Arrancando FabricView ${version} (descarga de imágenes: puede tardar unos minutos)"
  as_svc scripts/update.sh "$version" || die "La instalación no ha terminado bien. Revisa: cd ${DIR} && sudo -u ${SVC_USER} docker compose logs --tail 80"

  local port ip pass email
  port=$(envget FABRIC_HTTP_PORT); port=${port:-80}
  email=$(envget FABRIC_ADMIN_EMAIL)
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  pass=$(as_svc docker compose logs --no-color api 2>/dev/null | sed -n 's/.*Contraseña generada:[[:space:]]*\([^[:space:]]*\).*/\1/p' | tail -n1 || true)

  echo
  printf '\033[1;32m  ✔ FabricView %s instalado\033[0m\n\n' "$version"
  if [[ "$port" == "80" ]]; then echo "  Abre en el navegador:  http://${ip:-IP-del-servidor}"; else echo "  Abre en el navegador:  http://${ip:-IP-del-servidor}:${port}"; fi
  # La contraseña se genera en el primer arranque correcto (puede ser un reintento tras un fallo).
  if [[ -n "$pass" ]]; then
    echo "  Usuario:               ${email}"
    echo "  Contraseña:            ${pass}"
    echo "  (cámbiala en «Mi cuenta» al entrar; no se volverá a mostrar)"
  elif [[ $fresh -eq 1 ]]; then  # p. ej. FABRIC_ADMIN_PASSWORD fijada a mano en .env
    echo "  Contraseña inicial:    sudo -u ${SVC_USER} docker compose -f ${DIR}/docker-compose.yml logs api | grep -A1 'Administrador inicial'"
  fi
  echo
  echo "  Plan gratuito: hasta 10 equipos. Para ampliarlo: Ajustes › Licencia."
  echo "  Las versiones nuevas se instalan desde la web con el botón «Actualizar»."
  echo "  Copias de seguridad: ${DIR}/backups (antes de cada actualización)."
  echo
}

set_env() {
  local key="$1" value="$2"
  # Valor en una sola línea y sin caracteres que rompan .env.
  value=$(printf '%s' "$value" | tr -d '\n\r' | tr -d '`$\\"')
  if grep -qE "^${key}=" .env; then
    KEY="$key" VALUE="$value" python3 - <<'PY'
import os
key, value = os.environ["KEY"], os.environ["VALUE"]
with open(".env") as f:
    lines = f.read().splitlines()
lines = [f"{key}={value}" if line.startswith(key + "=") else line for line in lines]
with open(".env", "w") as f:
    f.write("\n".join(lines) + "\n")
PY
  else
    printf '%s=%s\n' "$key" "$value" >> .env
  fi
}

envget() { grep -E "^$1=" .env | tail -n1 | cut -d= -f2- || true; }

install_docker() {
  . /etc/os-release
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  local codename
  # Si Docker aún no publica paquetes para esta versión de Ubuntu, se usan los de la LTS anterior.
  for codename in "${DOCKER_APT_CODENAME:-${VERSION_CODENAME}}" noble; do
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${codename} stable" \
      > /etc/apt/sources.list.d/docker.list
    if apt-get update -qq 2>/dev/null && apt-cache show docker-ce >/dev/null 2>&1; then
      apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
      return 0
    fi
    echo "  Docker no publica paquetes para «${codename}»; probando con la LTS anterior…" >&2
  done
  rm -f /etc/apt/sources.list.d/docker.list
  echo "No se pudo instalar Docker desde su repositorio oficial" >&2
  exit 1
}

main "$@"
