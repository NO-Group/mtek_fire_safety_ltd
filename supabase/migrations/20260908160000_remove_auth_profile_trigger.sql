-- MFSL stores staff profiles in MongoDB through the data-api Edge Function.
-- A legacy public trigger on auth.users still attempted to mirror new users
-- into a removed/incompatible Postgres profile table, causing GoTrue's
-- "Database error creating new user" after the Auth row insert.
DO $$
DECLARE trigger_row record;
BEGIN
  FOR trigger_row IN
    SELECT t.tgname
    FROM pg_trigger t
    JOIN pg_proc p ON p.oid = t.tgfoid
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE t.tgrelid = 'auth.users'::regclass
      AND NOT t.tgisinternal
      AND n.nspname = 'public'
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON auth.users', trigger_row.tgname);
  END LOOP;
END $$;
