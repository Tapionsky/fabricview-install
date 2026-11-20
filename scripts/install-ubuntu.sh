#!/usr/bin/env bash
# Prepara un Ubuntu Server (probado para 24.04 y pensado para 26.04) para ejecutar FabricView:
# instala Docker Engine + plugin compose desde el repositorio oficial de Docker.
#
#   sudo scripts/install-ubuntu.sh
#
# Si el repositorio de Docker aún no publica paquetes para tu versión de Ubuntu,
# usa los de la LTS anterior: sudo DOCKER_APT_CODENAME=noble scripts/install-ubuntu.sh
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Ejecuta con sudo" >&2; exit 1; }
. /etc/os-release
[[ "${ID}" == "ubuntu" ]] || echo "Aviso: este script está pensado para Ubuntu (detectado: ${ID})" >&2
CODENAME="${DOCKER_APT_CODENAME:-${VERSION_CODENAME}}"

if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
  echo "Docker ya está instalado: $(docker --version)"
else
  apt-get update
  apt-get install -y ca-certificates curl git openssl
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  if ! apt-get update; then
    echo "El repositorio de Docker no responde para '${CODENAME}'. Reintenta con DOCKER_APT_CODENAME=noble" >&2
    exit 1
  fi
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
fi

if [[ -n "${SUDO_USER:-}" ]] && ! id -nG "$SUDO_USER" | grep -qw docker; then
  usermod -aG docker "$SUDO_USER"
  echo "Usuario ${SUDO_USER} añadido al grupo docker (cierra sesión y vuelve a entrar)."
fi
echo "Listo: $(docker --version) · $(docker compose version)"

# Botón «Actualizar» de la web: unidades de systemd del actualizador.
"$(dirname "$0")/install-updater.sh"
