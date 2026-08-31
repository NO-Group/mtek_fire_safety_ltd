#!/usr/bin/env bash
# ============================================================================
# M-TEK — Supabase deploy script (one command, reads backend/.env)
#   1. applies supabase/migrations/0001_init.sql (schema + RLS + RPCs + seeds)
#   2. seeds the CEO signature-passcode hash (bcrypt) — value stays in .env
#   3. deploys the issue-document edge function (if supabase CLI + token set)
# Usage:  bash backend/scripts/deploy-supabase.sh
# Requires: psql (libpq). Everything sensitive stays gitignored in backend/.env
# ============================================================================
set -euo pipefail

cd "$(dirname "$0")/../.."          # repo root
ENV_FILE="backend/.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "✗ $ENV_FILE not found — copy backend/.env.example and fill it in."; exit 1
fi

# parse KEY=VALUE (split on FIRST '=' so secrets may contain '=' or '#')
declare -A E
while IFS= read -r line; do
  case "$line" in ''|\#*) continue ;; esac
  k="${line%%=*}"; v="${line#*=}"
  E["$k"]="$v"
done < "$ENV_FILE"

DB_URL="${E[SUPABASE_DB_URL]:-}"
CEO_UID="${E[MTEK_CEO_UID]:-}"
CEO_SIG="${E[MTEK_CEO_SIG]:-}"

if [ -z "$DB_URL" ]; then echo "✗ SUPABASE_DB_URL missing in backend/.env"; exit 1; fi
if [ -z "$CEO_UID" ]; then echo "✗ MTEK_CEO_UID missing in backend/.env"; exit 1; fi
if ! command -v psql >/dev/null; then echo "✗ psql not installed"; exit 1; fi

echo "→ Applying migration 0001_init.sql …"
psql "$DB_URL" -v ON_ERROR_STOP=1 \
     -v ceo_uid="$CEO_UID" \
     -f supabase/migrations/0001_init.sql

echo "→ Seeding CEO signature passcode hash (value never displayed) …"
psql "$DB_URL" -v ON_ERROR_STOP=1 -v ceo_uid="$CEO_UID" -v ceo_sig="$CEO_SIG" <<'SQL'
update public.profiles
   set sig_passcode_hash = crypt(:'ceo_sig', gen_salt('bf'))
 where id = :'ceo_uid'::uuid;
SQL

echo "✓ Schema applied + CEO passcode seeded."

if command -v supabase >/dev/null && [ -n "${SUPABASE_ACCESS_TOKEN:-}" ]; then
  echo "→ Deploying edge function issue-document …"
  supabase functions deploy issue-document
  echo "✓ Edge function deployed."
else
  echo "ℹ supabase CLI or SUPABASE_ACCESS_TOKEN not set — deploy the edge function later:"
  echo "    supabase functions deploy issue-document --project-ref <ref>"
fi
