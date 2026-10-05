-- Gold DQ: final send sanity check before the API post.
-- In this repo, these queries log validation failures for walkthrough visibility.
-- In production, they should be treated as the final operational gate:
-- they can alert, quarantine the send set, or halt the pipeline before any vendor POST is attempted.

-- 1) No dupes by campaign, week, and patient.
SELECT
  campaign_id,
  week_num,
  patient_id,
  COUNT(*) AS dup_count
FROM `gold.fact_campaign_dispatch`
GROUP BY campaign_id, week_num, patient_id
HAVING COUNT(*) > 1;

-- 2) Weekly reserved + sent count must stay under target.
WITH weekly_counts AS (
  SELECT
    campaign_id,
    week_num,
    COUNTIF(send_status IN ('PLANNED', 'SENT')) AS reserved_or_sent
  FROM `gold.fact_campaign_dispatch`
  GROUP BY campaign_id, week_num
)
SELECT
  w.campaign_id,
  w.week_num,
  w.reserved_or_sent,
  c.weekly_target_count
FROM weekly_counts w
JOIN `gold.dim_campaign_week` c
  ON w.campaign_id = c.campaign_id
 AND w.week_num = c.week_num
WHERE w.reserved_or_sent > c.weekly_target_count;

-- 3) Cumulative reserved + sent count must stay under checkpoint.
WITH cumulative_by_week AS (
  SELECT
    c.campaign_id,
    c.week_num,
    SUM(CASE WHEN f.send_status IN ('PLANNED', 'SENT') THEN 1 ELSE 0 END) OVER (
      PARTITION BY c.campaign_id
      ORDER BY c.week_num
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS cumulative_reserved_count,
    c.cumulative_target_count
  FROM `gold.dim_campaign_week` c
  LEFT JOIN (
    SELECT
      campaign_id,
      week_num,
      patient_id,
      send_status
    FROM `gold.fact_campaign_dispatch`
  ) f
    ON c.campaign_id = f.campaign_id
   AND c.week_num = f.week_num
),
flagged AS (
  SELECT
    campaign_id,
    week_num,
    cumulative_reserved_count,
    cumulative_target_count
  FROM cumulative_by_week
  GROUP BY campaign_id, week_num, cumulative_reserved_count, cumulative_target_count
)
SELECT
  campaign_id,
  week_num,
  cumulative_reserved_count,
  cumulative_target_count
FROM flagged
WHERE cumulative_reserved_count > cumulative_target_count;

-- 4) Every sent row must still be eligible in the latest score snapshot.
SELECT
  d.campaign_id,
  d.week_num,
  d.patient_id,
  d.send_status
FROM `gold.fact_campaign_dispatch` d
LEFT JOIN (
  SELECT
    patient_id,
    is_eligible,
    ROW_NUMBER() OVER (PARTITION BY patient_id ORDER BY scored_ts DESC) AS rn
  FROM `silver.patient_priority_scored`
) s
  ON d.patient_id = s.patient_id
 AND s.rn = 1
WHERE d.send_status = 'SENT'
  AND IFNULL(s.is_eligible, FALSE) = FALSE;

-- 5) No missing IDs in dispatch output.
SELECT
  campaign_id,
  week_num,
  patient_id,
  dispatch_id
FROM `gold.fact_campaign_dispatch`
WHERE campaign_id IS NULL
   OR week_num IS NULL
   OR patient_id IS NULL
   OR dispatch_id IS NULL;

-- 6) No planned or sent rows for junk tiers.
SELECT
  d.campaign_id,
  d.week_num,
  d.patient_id,
  d.risk_tier,
  d.send_status
FROM `gold.fact_campaign_dispatch` d
WHERE d.send_status IN ('PLANNED', 'SENT')
  AND COALESCE(d.risk_tier, '') NOT IN ('VIP', 'HIGH');

-- 7) Suppressions should backfill immediately when capacity is still open.
WITH capacity_by_week AS (
  SELECT
    w.campaign_id,
    w.week_num,
    w.weekly_target_count - COUNTIF(f.send_status IN ('PLANNED', 'SENT')) AS remaining_capacity
  FROM `gold.dim_campaign_week` w
  LEFT JOIN `gold.fact_campaign_dispatch` f
    ON w.campaign_id = f.campaign_id
   AND w.week_num = f.week_num
  GROUP BY w.campaign_id, w.week_num, w.weekly_target_count
),
backfill_check AS (
  SELECT
    s.campaign_id,
    s.week_num,
    s.patient_id,
    s.selected_rank,
    COUNTIF(b.send_status IN ('PLANNED', 'SENT') AND b.selected_rank > s.selected_rank) AS replacement_count
  FROM `gold.fact_campaign_dispatch` s
  LEFT JOIN `gold.fact_campaign_dispatch` b
    ON s.campaign_id = b.campaign_id
   AND s.week_num = b.week_num
   AND b.send_status IN ('PLANNED', 'SENT')
   AND b.selected_rank > s.selected_rank
  WHERE s.send_status = 'SUPPRESSED'
  GROUP BY s.campaign_id, s.week_num, s.patient_id, s.selected_rank
)
SELECT
  c.campaign_id,
  c.week_num,
  c.patient_id,
  c.selected_rank,
  c.replacement_count,
  p.remaining_capacity
FROM backfill_check c
JOIN capacity_by_week p
  ON c.campaign_id = p.campaign_id
 AND c.week_num = p.week_num
WHERE p.remaining_capacity > 0
  AND c.replacement_count = 0;
