-- =============================================================================
-- ONE-TIME SETUP - technician feedback table (NOT part of the repair-triage-agents job,
-- so a job run can never recreate or drop technician feedback).
-- The app writes here (POST /api/feedback); Agent 1 reads confirmed causes back in on every
-- run, and Agent 3's live views turn it into accuracy tracking and the improvement backlog.
-- Statements are separated by lines containing only ';'.
-- =============================================================================

CREATE TABLE IF NOT EXISTS ultraviolet.gold_real.triage_feedback (
  feedback_id STRING NOT NULL,
  submitted_at TIMESTAMP NOT NULL,
  technician STRING COMMENT 'X-Forwarded-Email of the signed-in app user',
  order_number STRING COMMENT 'SAP order number if the technician entered one; SAP labels win over feedback for the same order',
  catalog STRING,
  family STRING,
  symptom STRING,
  serial STRING,
  failure_text STRING,
  predicted_top3 ARRAY<STRING>,
  predicted_confidence STRING,
  level_used STRING,
  actual_cause STRING COMMENT 'One of the 14 normalized causes, confirmed by the technician after repair',
  verdict STRING COMMENT 'top1 | top3 | missed (computed server-side from predicted_top3 vs actual_cause)',
  manual_helpful BOOLEAN COMMENT 'Was the synthetic-manual procedure useful for this repair (NULL = not answered)',
  comment STRING
)
COMMENT 'Technician feedback from the Repair Triage app: the confirmed cause after repair vs what the triage card predicted. Feeds Agent 1 (new labels) and Agent 3 (live accuracy, improvement backlog).'
;

-- The app can write feedback but nothing else in gold_real
GRANT SELECT, MODIFY ON TABLE ultraviolet.gold_real.triage_feedback TO `3bbe28b9-4419-4316-809e-be29afc4e452`
;
