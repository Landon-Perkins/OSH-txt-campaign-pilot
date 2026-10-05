-- BigQuery Standard SQL
-- Gold: campaign config, dispatch logic, and outcome facts.

CREATE SCHEMA IF NOT EXISTS `gold`;

CREATE TABLE IF NOT EXISTS `gold.dim_campaign_week` (
  campaign_id STRING NOT NULL,
  week_num INT64 NOT NULL,
  week_start_date DATE NOT NULL,
  week_end_date DATE NOT NULL,
  cumulative_target_pct FLOAT64 NOT NULL,
  cumulative_target_count INT64 NOT NULL,
  weekly_target_count INT64 NOT NULL,
  PRIMARY KEY (campaign_id, week_num) NOT ENFORCED
);

CREATE TABLE IF NOT EXISTS `gold.fact_campaign_dispatch` (
  dispatch_id STRING NOT NULL,
  campaign_id STRING NOT NULL,
  week_num INT64 NOT NULL,
  dispatch_ts TIMESTAMP NOT NULL,
  patient_id STRING NOT NULL,
  risk_tier STRING,
  weighted_priority_score FLOAT64,
  selected_rank INT64,
  send_status STRING,
  suppression_reason STRING,
  PRIMARY KEY (dispatch_id) NOT ENFORCED
)
PARTITION BY DATE(dispatch_ts)
CLUSTER BY campaign_id, week_num, risk_tier;

CREATE TABLE IF NOT EXISTS `gold.fact_appointment_outcome` (
  outcome_id STRING NOT NULL,
  campaign_id STRING,
  patient_id STRING NOT NULL,
  event_ts TIMESTAMP NOT NULL,
  event_type STRING,
  appointment_id STRING,
  appointment_dt TIMESTAMP,
  PRIMARY KEY (outcome_id) NOT ENFORCED
)
PARTITION BY DATE(event_ts)
CLUSTER BY campaign_id, patient_id;

MERGE `gold.dim_campaign_week` t
USING (
  SELECT 'OSH_PILOT_2026Q4' AS campaign_id, 1 AS week_num, DATE '2026-10-05' AS week_start_date, DATE '2026-10-11' AS week_end_date, 0.20 AS cumulative_target_pct, 200 AS cumulative_target_count, 200 AS weekly_target_count UNION ALL
  SELECT 'OSH_PILOT_2026Q4', 2, DATE '2026-10-12', DATE '2026-10-18', 0.40, 400, 200 UNION ALL
  SELECT 'OSH_PILOT_2026Q4', 3, DATE '2026-10-19', DATE '2026-10-25', 0.60, 600, 200 UNION ALL
  SELECT 'OSH_PILOT_2026Q4', 4, DATE '2026-10-26', DATE '2026-11-01', 0.80, 800, 200 UNION ALL
  SELECT 'OSH_PILOT_2026Q4', 5, DATE '2026-11-02', DATE '2026-11-08', 1.00, 1000, 200
) s
ON t.campaign_id = s.campaign_id
AND t.week_num = s.week_num
WHEN MATCHED THEN UPDATE SET
  week_start_date = s.week_start_date,
  week_end_date = s.week_end_date,
  cumulative_target_pct = s.cumulative_target_pct,
  cumulative_target_count = s.cumulative_target_count,
  weekly_target_count = s.weekly_target_count
WHEN NOT MATCHED THEN INSERT (
  campaign_id,
  week_num,
  week_start_date,
  week_end_date,
  cumulative_target_pct,
  cumulative_target_count,
  weekly_target_count
)
VALUES (
  s.campaign_id,
  s.week_num,
  s.week_start_date,
  s.week_end_date,
  s.cumulative_target_pct,
  s.cumulative_target_count,
  s.weekly_target_count
);

CREATE OR REPLACE TABLE `gold.dispatch_candidates_current` AS
WITH remaining_capacity AS (
  SELECT
    w.weekly_target_count - COUNTIF(f.send_status IN ('PLANNED', 'SENT') AND f.week_num = 1) AS weekly_remaining,
    w.cumulative_target_count - COUNTIF(f.send_status IN ('PLANNED', 'SENT')) AS cumulative_remaining
  FROM `gold.dim_campaign_week` w
  LEFT JOIN `gold.fact_campaign_dispatch` f
    ON f.campaign_id = w.campaign_id
  WHERE w.campaign_id = 'OSH_PILOT_2026Q4'
    AND w.week_num = 1 -- ToDo: Design Goal - implement the full week 2-5 pacing
  GROUP BY w.weekly_target_count, w.cumulative_target_count
),
ranked AS (
  SELECT
    p.patient_id,
    p.risk_tier,
    p.risk_tier_rank,
    p.weighted_priority_score,
    ROW_NUMBER() OVER (
      ORDER BY p.risk_tier_rank ASC, p.weighted_priority_score DESC, p.patient_id
    ) AS selected_rank
  FROM `silver.patient_priority_scored` p
  WHERE p.is_eligible = TRUE
    AND p.patient_id NOT IN (
      SELECT patient_id
      FROM `gold.fact_campaign_dispatch`
      WHERE campaign_id = 'OSH_PILOT_2026Q4'
        AND send_status IN ('PLANNED', 'SENT', 'DISPLACED')
    )
)
SELECT
  GENERATE_UUID() AS dispatch_id,
  'OSH_PILOT_2026Q4' AS campaign_id,
  1 AS week_num,
  CURRENT_TIMESTAMP() AS dispatch_ts,
  r.patient_id,
  r.risk_tier,
  r.weighted_priority_score,
  r.selected_rank,
  'PLANNED' AS send_status,
  CAST(NULL AS STRING) AS suppression_reason
FROM ranked r
CROSS JOIN remaining_capacity c
WHERE r.selected_rank <= LEAST(GREATEST(c.weekly_remaining, 0), GREATEST(c.cumulative_remaining, 0));

INSERT INTO `gold.fact_campaign_dispatch` (
  dispatch_id,
  campaign_id,
  week_num,
  dispatch_ts,
  patient_id,
  risk_tier,
  weighted_priority_score,
  selected_rank,
  send_status,
  suppression_reason
)
SELECT
  c.dispatch_id,
  c.campaign_id,
  c.week_num,
  c.dispatch_ts,
  c.patient_id,
  c.risk_tier,
  c.weighted_priority_score,
  c.selected_rank,
  c.send_status,
  c.suppression_reason
FROM `gold.dispatch_candidates_current` c
WHERE NOT EXISTS (
  SELECT 1
  FROM `gold.fact_campaign_dispatch` f
  WHERE f.campaign_id = c.campaign_id
    AND f.week_num = c.week_num
    AND f.patient_id = c.patient_id
);

MERGE `gold.fact_appointment_outcome` t
USING (
  SELECT
    event_id AS outcome_id,
    campaign_id,
    patient_id,
    event_ts,
    event_type,
    appointment_id,
    appointment_dt
  FROM `silver.outreach_outcomes`
  WHERE event_type IN ('SCHEDULED', 'RESCHEDULED', 'CANCELLED')
) s
ON t.outcome_id = s.outcome_id
WHEN MATCHED THEN UPDATE SET
  campaign_id = s.campaign_id,
  patient_id = s.patient_id,
  event_ts = s.event_ts,
  event_type = s.event_type,
  appointment_id = s.appointment_id,
  appointment_dt = s.appointment_dt
WHEN NOT MATCHED THEN INSERT (
  outcome_id,
  campaign_id,
  patient_id,
  event_ts,
  event_type,
  appointment_id,
  appointment_dt
)
VALUES (
  s.outcome_id,
  s.campaign_id,
  s.patient_id,
  s.event_ts,
  s.event_type,
  s.appointment_id,
  s.appointment_dt
);
