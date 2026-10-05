-- BigQuery Standard SQL
-- Silver: patient universe, eligibility, and ranking features.

CREATE SCHEMA IF NOT EXISTS `silver`;

CREATE OR REPLACE TABLE `silver.outreach_outcomes`
PARTITION BY DATE(event_ts)
CLUSTER BY campaign_id, patient_id AS
WITH normalized AS (
  SELECT
    event_id,
    event_ts,
    patient_id,
    campaign_id,
    UPPER(TRIM(event_type)) AS event_type,
    NULLIF(TRIM(event_subtype), '') AS event_subtype,
    NULLIF(TRIM(vendor_status_code), '') AS vendor_status_code,
    NULLIF(TRIM(appointment_id), '') AS appointment_id,
    appointment_dt,
    _ingested_at
  FROM `bronze.outreach_outcomes_raw`
  WHERE event_id IS NOT NULL
    AND event_ts IS NOT NULL
    AND patient_id IS NOT NULL
    AND event_type IS NOT NULL
    AND TRIM(event_type) != ''
)
SELECT * EXCEPT (rn)
FROM (
  SELECT
    *,
    ROW_NUMBER() OVER (
      PARTITION BY event_id
      ORDER BY _ingested_at DESC, event_ts DESC
    ) AS rn
  FROM normalized
)
WHERE rn = 1;

CREATE OR REPLACE TABLE `silver.patient_universe` AS
WITH latest_intake AS (
  SELECT
    intake_ts AS snapshot_ts,
    patient_id,
    UPPER(risk_tier) AS risk_tier,
    risk_score_raw,
    consent_sms,
    do_not_contact,
    phone_e164,
    last_pcp_visit_dt,
    chronic_condition_count,
    no_show_count_12m,
    preferred_language,
    ROW_NUMBER() OVER (
      PARTITION BY patient_id
      ORDER BY intake_ts DESC, _ingested_at DESC
    ) AS rn
  FROM `bronze.patient_api_intake`
),
latest_vip AS (
  SELECT
    arrival_ts AS snapshot_ts,
    patient_id,
    UPPER(risk_tier) AS risk_tier,
    vip_reason,
    ROW_NUMBER() OVER (
      PARTITION BY patient_id
      ORDER BY arrival_ts DESC, _ingested_at DESC
    ) AS rn
  FROM `bronze.vip_arrivals`
),
base AS (
  SELECT
    IFNULL(i.patient_id, v.patient_id) AS patient_id,
    GREATEST(IFNULL(i.snapshot_ts, v.snapshot_ts), IFNULL(v.snapshot_ts, i.snapshot_ts)) AS snapshot_ts,
    CASE
      WHEN v.patient_id IS NOT NULL AND (i.patient_id IS NULL OR v.snapshot_ts >= i.snapshot_ts) THEN 'VIP'
      ELSE UPPER(COALESCE(i.risk_tier, v.risk_tier))
    END AS risk_tier,
    i.risk_score_raw,
    i.consent_sms,
    i.do_not_contact,
    i.phone_e164,
    i.last_pcp_visit_dt,
    i.chronic_condition_count,
    i.no_show_count_12m,
    i.preferred_language,
    v.patient_id IS NOT NULL AS is_vip_arrival,
    v.vip_reason,
    IFNULL(REGEXP_CONTAINS(i.phone_e164, r'^\+[1-9]\d{7,14}$'), FALSE) AS is_valid_phone,
    DATE_DIFF(CURRENT_DATE(), IFNULL(i.last_pcp_visit_dt, DATE '1900-01-01'), DAY) AS days_since_pcp_visit,
    MAX(IF(o.event_type = 'OPT_OUT', 1, 0)) OVER (PARTITION BY IFNULL(i.patient_id, v.patient_id)) AS has_opted_out,
    MAX(IF(o.event_type = 'SCHEDULED', 1, 0)) OVER (PARTITION BY IFNULL(i.patient_id, v.patient_id)) AS already_scheduled
  FROM latest_intake i
  FULL OUTER JOIN latest_vip v
    ON i.patient_id = v.patient_id
  LEFT JOIN `silver.outreach_outcomes` o
    ON COALESCE(i.patient_id, v.patient_id) = o.patient_id
  WHERE i.rn = 1 OR v.rn = 1
)
SELECT
  patient_id,
  snapshot_ts,
  risk_tier,
  risk_score_raw,
  consent_sms,
  do_not_contact,
  phone_e164,
  last_pcp_visit_dt,
  chronic_condition_count,
  no_show_count_12m,
  preferred_language,
  is_vip_arrival,
  vip_reason,
  is_valid_phone,
  days_since_pcp_visit,
  IFNULL(has_opted_out, 0) = 1 AS has_opted_out,
  IFNULL(already_scheduled, 0) = 1 AS already_scheduled,
  (
    consent_sms = TRUE
    AND do_not_contact = FALSE
    AND is_valid_phone = TRUE
    AND IFNULL(has_opted_out, 0) = 0
    AND IFNULL(already_scheduled, 0) = 0
    AND risk_tier IN ('VIP', 'HIGH')
  ) AS is_eligible
FROM base
QUALIFY ROW_NUMBER() OVER (PARTITION BY patient_id ORDER BY snapshot_ts DESC) = 1;

CREATE OR REPLACE TABLE `silver.patient_priority_scored` AS
SELECT
  CURRENT_TIMESTAMP() AS scored_ts,
  patient_id,
  risk_tier,
  is_eligible,
  CASE
    WHEN risk_tier = 'VIP' THEN 1
    WHEN risk_tier = 'HIGH' THEN 2
    ELSE 9
  END AS risk_tier_rank,
  IFNULL(risk_score_raw, 0.0) AS risk_score_raw,
  IFNULL(days_since_pcp_visit, 0) AS days_since_pcp_visit,
  IFNULL(chronic_condition_count, 0) AS chronic_condition_count,
  IFNULL(no_show_count_12m, 0) AS no_show_count_12m,
  (
    IFNULL(risk_score_raw, 0.0) * 0.45
    + LEAST(IFNULL(days_since_pcp_visit, 0), 365) * 0.20
    + LEAST(IFNULL(chronic_condition_count, 0), 10) * 0.20
    + LEAST(IFNULL(no_show_count_12m, 0), 8) * 0.15
  ) AS weighted_priority_score
FROM `silver.patient_universe`;
