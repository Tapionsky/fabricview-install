#!/usr/bin/env bash
# Copia de seguridad de la base de datos en backups/ (formato pg_dump custom).
# Conserva las últimas ${FABRIC_BACKUP_KEEP:-14}.
# Restaurar: scripts/restore.sh backups/FICHERO.dump
set -euo pipefail
cd "$(dirname "$0")/.."

envval() { grep -E "^$1=" .env | tail -n1 | cut -d= -f2-; }
PGUSER_=$(envval POSTGRES_USER); PGDB_=$(envval POSTGRES_DB)
mkdir -p backups
file="backups/fabricview-$(date +%Y%m%d-%H%M%S).dump"

if ! docker compose ps --status running db --quiet | grep -q .; then
  echo "La base de datos no está en marcha; se omite la copia." >&2
  exit 0
fi
docker compose exec -T db pg_dump -U "${PGUSER_:-fabricview}" -d "${PGDB_:-fabricview}" -Fc > "$file" \
  2> >(grep -vE "circular foreign-key|continuous_agg|might not be able to restore|full dump instead" >&2)
chmod 600 "$file"
echo "Copia creada: $file ($(du -h "$file" | cut -f1))"

ls -1t backups/fabricview-*.dump | tail -n +"$(( ${FABRIC_BACKUP_KEEP:-14} + 1 ))" | xargs -r rm -f
