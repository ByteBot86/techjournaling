-- supabase/migrations/002_user_id_triggers.sql
--
-- n8n's Supabase Vector Store (insert mode) only writes text/metadata/embedding columns.
-- This trigger auto-fills the user_id FK column from metadata->>'user_id' so that
-- RPC match functions can filter by user_id column properly.

CREATE OR REPLACE FUNCTION fill_user_id_from_metadata()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.user_id IS NULL AND (NEW.metadata->>'user_id') IS NOT NULL THEN
    NEW.user_id := (NEW.metadata->>'user_id')::uuid;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Apply to all vector tables

CREATE TRIGGER journal_entries_fill_user_id
  BEFORE INSERT ON journal_entries
  FOR EACH ROW EXECUTE FUNCTION fill_user_id_from_metadata();

CREATE TRIGGER weekly_condensations_fill_user_id
  BEFORE INSERT ON weekly_condensations
  FOR EACH ROW EXECUTE FUNCTION fill_user_id_from_metadata();

CREATE TRIGGER monthly_condensations_fill_user_id
  BEFORE INSERT ON monthly_condensations
  FOR EACH ROW EXECUTE FUNCTION fill_user_id_from_metadata();

CREATE TRIGGER yearly_condensations_fill_user_id
  BEFORE INSERT ON yearly_condensations
  FOR EACH ROW EXECUTE FUNCTION fill_user_id_from_metadata();

CREATE TRIGGER amphitheater_fill_user_id
  BEFORE INSERT ON amphitheater
  FOR EACH ROW EXECUTE FUNCTION fill_user_id_from_metadata();

CREATE TRIGGER weekly_plans_fill_user_id
  BEFORE INSERT ON weekly_plans
  FOR EACH ROW EXECUTE FUNCTION fill_user_id_from_metadata();
