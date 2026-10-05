-- Silver DQ: sanity-checks the patient universe and score logic before Gold uses it.
-- In this repo, these queries log issues for transparency and review.
-- In production, they could trigger alerts, quarantine the dataset, or stop the run
-- before invalid patient-level logic reaches the Gold dispatch layer.

-- Curated outcome events have required fields and normalized event types.
SELECT
  event_id,
  event_ts,
  patient_id,
  event_type
FROM `silver.outreach_outcomes`
WHERE event_id IS NULL
   OR event_ts IS NULL
   OR patient_id IS NULL
   OR event_type IS NULL
   OR event_type = ''
   OR event_type != UPPER(TRIM(event_type));

-- Event deduplication leaves one row per source event.
SELECT
  event_id,
  COUNT(*) AS duplicate_count
FROM `silver.outreach_outcomes`
GROUP BY event_id
HAVING COUNT(*) > 1;

-- 1) No dupes in the latest patient snapshot.
SELECT
  patient_id,
  COUNT(*) AS dup_count
FROM `silver.patient_universe`
GROUP BY patient_id
HAVING COUNT(*) > 1;

-- 2) No missing patient keys or core attributes.
SELECT
  patient_id,
  risk_tier,
  consent_sms,
  do_not_contact,
  phone_e164,
  is_valid_phone
FROM `silver.patient_universe`
WHERE patient_id IS NULL
   OR risk_tier IS NULL
   OR consent_sms IS NULL
   OR do_not_contact IS NULL
   OR is_valid_phone IS NULL;

-- 3) No eligible row with missing consent/contact basics.
SELECT
  patient_id,
  risk_tier,
  is_eligible,
  consent_sms,
  do_not_contact,
  phone_e164
FROM `silver.patient_universe`
WHERE is_eligible = TRUE
  AND (
    consent_sms IS NOT TRUE
    OR do_not_contact IS NOT FALSE
    OR phone_e164 IS NULL
    OR NOT REGEXP_CONTAINS(phone_e164, r'^\+[1-9]\d{7,14}$')
  );

-- 4) Every scored patient needs a valid tier and stable rank.
SELECT
  patient_id,
  risk_tier,
  risk_tier_rank,
  weighted_priority_score
FROM `silver.patient_priority_scored`
WHERE patient_id IS NULL
   OR risk_tier IS NULL
   OR risk_tier_rank IS NULL
   OR weighted_priority_score IS NULL;

-- 5) No eligible patient if they already opted out or booked.
SELECT
  p.patient_id,
  p.is_eligible,
  p.has_opted_out,
  p.already_scheduled
FROM `silver.patient_universe` p
WHERE p.is_eligible = TRUE
  AND (
    p.has_opted_out = TRUE
    OR p.already_scheduled = TRUE
  );
