-- Bronze DQ: checks raw intake for gaps, dupes, and bad contact data.
-- In this repo, these queries log findings for walkthrough and auditability.
-- In production, the same checks could quarantine bad data, alert operators,
-- or halt the pipeline before downstream transforms consume invalid rows.

-- 1) No dupes for the same patient and timestamp.
SELECT
  patient_id,
  intake_ts,
  source_system,
  COUNT(*) AS dup_count
FROM `bronze.patient_api_intake`
GROUP BY patient_id, intake_ts, source_system
HAVING COUNT(*) > 1;

-- 2) No missing IDs or timestamps in intake.
SELECT
  intake_batch_id,
  intake_ts,
  patient_id,
  source_system
FROM `bronze.patient_api_intake`
WHERE intake_batch_id IS NULL
   OR intake_ts IS NULL
   OR patient_id IS NULL;

-- 3) No consent without a valid SMS number.
SELECT
  patient_id,
  consent_sms,
  phone_e164
FROM `bronze.patient_api_intake`
WHERE consent_sms = TRUE
  AND (phone_e164 IS NULL OR NOT REGEXP_CONTAINS(phone_e164, r'^\+[1-9]\d{7,14}$'));

-- 4) No duplicate VIP arrival rows for the same patient and timestamp.
SELECT
  patient_id,
  arrival_ts,
  COUNT(*) AS dup_count
FROM `bronze.vip_arrivals`
GROUP BY patient_id, arrival_ts
HAVING COUNT(*) > 1;

-- 5) No missing IDs or timestamps in outcomes.
SELECT
  event_id,
  event_ts,
  patient_id,
  event_type
FROM `bronze.outreach_outcomes_raw`
WHERE event_id IS NULL
   OR event_ts IS NULL
   OR patient_id IS NULL
   OR event_type IS NULL;
