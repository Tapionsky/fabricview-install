#!/usr/bin/env bash
# Crea .env a partir de .env.example con secretos aleatorios.
# Uso: scripts/init-env.sh [--demo]
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -f .env ]]; then
  echo "Ya existe .env; no se toca. Bórralo antes si quieres regenerarlo." >&2
  exit 1
fi
command -v openssl >/dev/null || { echo "Falta openssl" >&2; exit 1; }

secret=$(openssl rand -base64 48 | tr -d '\n')
dbpass=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 32)
demo=0
[[ "${1:-}" == "--demo" ]] && demo=1

sed -e "s|^FABRIC_SECRET_KEY=.*|FABRIC_SECRET_KEY=${secret}|" \
    -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${dbpass}|" \
    -e "s|^FABRIC_DEMO=.*|FABRIC_DEMO=${demo}|" \
    -e "s|^FABRIC_VERSION=.*|FABRIC_VERSION=$(tr -d '[:space:]' < VERSION)|" \
    .env.example > .env
chmod 600 .env
# Buzón del botón «Actualizar» (debe existir antes del primer `docker compose up`; ver install-updater.sh)
mkdir -p .control/inbox
echo "Creado .env (permisos 600). Revisa FABRIC_TENANT_NAME, FABRIC_SITE_NAME y el acceso web."
echo "Guarda una copia de FABRIC_SECRET_KEY en lugar seguro: sin ella no se pueden leer las credenciales cifradas."
