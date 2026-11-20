#!/usr/bin/env bash
# Instala el actualizador del servidor (unidades de systemd) para el botón «Actualizar» de la web.
#
#   sudo scripts/install-updater.sh            instala o reinstala
#   sudo scripts/install-updater.sh --remove   lo desinstala
#
# - fabricview-updater.path     vigila .control/inbox y lanza fabricview-updater.service
# - fabricview-updater.service  ejecuta scripts/updater.sh process como el dueño de esta carpeta
# - fabricview-update-check.timer  comprueba cada hora si hay versión nueva (scripts/updater.sh check)
#
# Seguridad: la API (contenedor, uid 10001) solo puede CREAR ficheros en .control/inbox (no leer ni
# listar la carpeta); el host valida la petición y solo acepta un número de versión con tag publicado.
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Ejecuta con sudo" >&2; exit 1; }
command -v systemctl >/dev/null || { echo "Este sistema no usa systemd: usa 'scripts/updater.sh watch'" >&2; exit 1; }

DIR="$(cd "$(dirname "$0")/.." && pwd)"
[[ "$DIR" != *[[:space:]]* ]] || { echo "La ruta de instalación no puede contener espacios: $DIR" >&2; exit 1; }
UNITS=(fabricview-updater.path fabricview-updater.service fabricview-update-check.timer fabricview-update-check.service)

if [[ "${1:-}" == "--remove" ]]; then
  systemctl disable --now fabricview-updater.path fabricview-update-check.timer 2>/dev/null || true
  for u in "${UNITS[@]}"; do rm -f "/etc/systemd/system/$u"; done
  systemctl daemon-reload
  echo "Actualizador desinstalado."
  exit 0
fi

OWNER=$(stat -c %U "$DIR")
GROUP=$(stat -c %G "$DIR")
HOME_DIR=$(getent passwd "$OWNER" | cut -d: -f6)
[[ "$OWNER" != "root" ]] || echo "Aviso: la carpeta pertenece a root; el actualizador se ejecutará como root." >&2
command -v python3 >/dev/null || apt-get install -y python3
id -nG "$OWNER" | grep -qw docker || [[ "$OWNER" == "root" ]] || {
  usermod -aG docker "$OWNER"; echo "Usuario ${OWNER} añadido al grupo docker."; }

# Buzón: el dueño lo administra; el grupo 10001 (usuario de la API en el contenedor) solo puede escribir.
install -d -o "$OWNER" -g "$GROUP" -m 0755 "$DIR/.control"
install -d -o "$OWNER" -g 10001 -m 1730 "$DIR/.control/inbox"

cat > /etc/systemd/system/fabricview-updater.path <<UNIT
[Unit]
Description=FabricView: peticiones de actualización desde la web

[Path]
PathExistsGlob=${DIR}/.control/inbox/*.json
Unit=fabricview-updater.service

[Install]
WantedBy=paths.target
UNIT

cat > /etc/systemd/system/fabricview-updater.service <<UNIT
[Unit]
Description=FabricView: procesa peticiones de actualización
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=${OWNER}
Group=${GROUP}
SupplementaryGroups=docker
Environment=HOME=${HOME_DIR}
WorkingDirectory=${DIR}
ExecStart=${DIR}/scripts/updater.sh process
TimeoutStartSec=45min
UNIT

cat > /etc/systemd/system/fabricview-update-check.service <<UNIT
[Unit]
Description=FabricView: comprueba si hay versión nueva
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=${OWNER}
Group=${GROUP}
SupplementaryGroups=docker
Environment=HOME=${HOME_DIR}
WorkingDirectory=${DIR}
ExecStart=${DIR}/scripts/updater.sh check
TimeoutStartSec=5min
UNIT

cat > /etc/systemd/system/fabricview-update-check.timer <<UNIT
[Unit]
Description=FabricView: comprobación horaria de versiones

[Timer]
OnBootSec=3min
OnUnitActiveSec=1h
RandomizedDelaySec=5min
Persistent=true

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now fabricview-updater.path fabricview-update-check.timer
systemctl start fabricview-update-check.service || echo "Aviso: la primera comprobación ha fallado (revisa: journalctl -u fabricview-update-check)" >&2
echo "Actualizador instalado para ${DIR} (usuario ${OWNER})."
echo "Estado: systemctl status fabricview-updater.path fabricview-update-check.timer"
