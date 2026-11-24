#!/usr/bin/env bash
# Rebuild a scratch database from the migrations and run the tests. Needs Postgres 16 binaries.
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"; BIN=/usr/lib/postgresql/16/bin; PORT=54329; D=/tmp/pgdata_bk
if ! $BIN/pg_isready -h /tmp -p $PORT >/dev/null 2>&1; then
  [ -d $D ] || { mkdir -p $D; chown postgres $D; su postgres -c "$BIN/initdb -D $D -A trust >/dev/null"; }
  su postgres -c "$BIN/pg_ctl -D $D -o '-p $PORT -k /tmp' -l /tmp/pg_bk.log start >/dev/null"; sleep 2
fi
P="psql -h /tmp -p $PORT -U postgres -v ON_ERROR_STOP=1 -q"
$P -d postgres -c "drop database if exists bk" -c "create database bk"
$P -d bk -f "$DIR/tests/00_supabase_stub.sql"
for f in "$DIR"/migrations/*.sql; do $P -d bk -f "$f"; done
$P -d bk -f "$DIR/tests/01_workflow_and_rls.sql"
