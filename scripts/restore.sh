#!/usr/bin/env bash
# Restaura una copia creada por scripts/backup.sh (sustituye TODOS los datos actuales).
#
#   scripts/restore.sh backups/fabricview-AAAAMMDD-HHMMSS.dump
#
# Sigue el procedimiento de TimescaleDB: timescaledb_pre_restore() → pg_restore → timescaledb_post_restore().
set -euo pipefail
cd "$(dirname "$0")/.."

dump="${1:-}"
[[ -f "$dump" ]] || { echo "Uso: scripts/restore.sh backups/FICHERO.dump" >&2; exit 1; }

envval() { grep -E "^$1=" .env | tail -n1 | cut -d= -f2-; }
U=$(envval POSTGRES_USER); U=${U:-fabricview}
D=$(envval POSTGRES_DB); D=${D:-fabricview}

if [[ "${FABRIC_RESTORE_YES:-}" != "1" ]]; then
  read -r -p "Se sustituirán todos los datos de '${D}' por ${dump}. ¿Continuar? (escribe SI) " answer
  [[ "$answer" == "SI" ]] || { echo "Cancelado."; exit 1; }
fi

echo "▸ Parando servicios que usan la base de datos"
docker compose stop api collector notifier frontend proxy

echo "▸ Recreando la base de datos vacía"
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U "$U" -d postgres \
  -c "DROP DATABASE IF EXISTS \"${D}\" WITH (FORCE);" \
  -c "CREATE DATABASE \"${D}\";"
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U "$U" -d "$D" \
  -c "CREATE EXTENSION IF NOT EXISTS timescaledb;" \
  -c "SELECT timescaledb_pre_restore();" >/dev/null

echo "▸ Restaurando ${dump}"
docker compose exec -T db pg_restore -U "$U" -d "$D" --no-owner < "$dump" || {
  echo "pg_restore ha devuelto avisos; se continúa (revísalos arriba)." >&2; }
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U "$U" -d "$D" -c "SELECT timescaledb_post_restore();" >/dev/null

echo "▸ Arrancando servicios"
# Sin código fuente (instalación pública) no se puede compilar: solo imágenes ya descargadas.
if [[ -d backend ]]; then docker compose up -d || true; else docker compose up -d --no-build || true; fi
echo "Restauración completada."
