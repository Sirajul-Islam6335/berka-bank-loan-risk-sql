#!/usr/bin/env bash
# Runs every SQL script in sql/ in order, stopping at the first error.
#
#   ./scripts/run_all.sh            run inside the Docker container (default)
#   ./scripts/run_all.sh --local    use your own psql against localhost
#
# With --local, the usual PG* environment variables are respected
# (PGHOST, PGPORT, PGUSER, PGPASSWORD). Note that 01_load_raw_data.sql reads
# the files from /data/raw on the database server, so --local only works if
# that path exists on the machine running Postgres.
#
# The scripts print their check queries; that output is hidden here. Run a
# file on its own (or open it in VS Code) to see the results.

set -euo pipefail
cd "$(dirname "$0")/.."

# pick up .env if there is one
if [[ -f .env ]]; then
    set -a; source .env; set +a
fi
DB="${POSTGRES_DB:-berka_bank}"
USER_NAME="${POSTGRES_USER:-postgres}"

if [[ "${1:-}" == "--local" ]]; then
    run_sql() { PGOPTIONS='--client-min-messages=warning' psql -d "$DB" -v ON_ERROR_STOP=1 -q -f "sql/$1"; }
else
    run_sql() { docker compose exec -T -e PGOPTIONS='--client-min-messages=warning' db \
                    psql -U "$USER_NAME" -d "$DB" -v ON_ERROR_STOP=1 -q -f "/sql/$1"; }
fi

start=$(date +%s)
for file in $(ls sql | grep -E '^[0-9]{2}_.*\.sql$' | sort); do
    echo "==> $file"
    run_sql "$file" > /dev/null
done
echo
echo "All scripts ran successfully in $(( $(date +%s) - start ))s."
