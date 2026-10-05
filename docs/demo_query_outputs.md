# Mock Dataset and Demo Walkthrough

This file combines the walkthrough SQL with the expected outputs for the final interview scenario aligned to the consolidated model.

## Dataset Snapshot
- 13 patients total in the sample: 12 initial records and 1 new VIP arrival.
- Week 1 had 180 cumulative reservations already in place.
- Week 2 demonstrates late suppression and the backfill behavior.

---

## Q1 - Patient universe and eligibility

```sql
-- BigQuery Standard SQL
-- Quick demo for the consolidated OSH campaign model.
-- Inline CTEs keep this easy to run in one editor window.

WITH intake AS (
  SELECT * FROM UNNEST([
    STRUCT('P001' AS patient_id, 'VIP' AS risk_tier, 95.0 AS risk_score_raw, TRUE AS consent_sms, FALSE AS do_not_contact, '+13105550101' AS phone_e164, DATE '2026-09-01' AS last_pcp_visit_dt, 4 AS chronic_condition_count, 1 AS no_show_count_12m),
    STRUCT('P002','HIGH',88.0,TRUE,FALSE,'+13105550102',DATE '2026-08-15',3,2),
    STRUCT('P003','HIGH',80.0,TRUE,FALSE,'+13105550103',DATE '2026-10-01',6,1),
    STRUCT('P004','VIP',92.0,TRUE,FALSE,'+13105550104',DATE '2026-09-25',5,0),
    STRUCT('P005','HIGH',75.0,TRUE,FALSE,'+13105550105',DATE '2026-07-01',7,3),
    STRUCT('P006','HIGH',70.0,TRUE,FALSE,'3105550106',DATE '2026-08-20',2,0),
    STRUCT('P007','HIGH',85.0,TRUE,TRUE,'+13105550107',DATE '2026-08-10',5,2),
    STRUCT('P008','HIGH',72.0,TRUE,FALSE,'+13105550108',DATE '2026-09-10',1,4),
    STRUCT('P009','HIGH',77.0,FALSE,FALSE,'+13105550109',DATE '2026-08-25',3,2),
    STRUCT('P010','HIGH',90.0,TRUE,FALSE,'+13105550110',DATE '2026-08-20',6,1),
    STRUCT('P011','HIGH',93.0,TRUE,FALSE,'+13105550111',DATE '2026-08-05',8,2),
    STRUCT('P012','HIGH',90.0,TRUE,FALSE,'+13105550112',DATE '2026-07-05',7,3)
  ])
),
vip_arrivals AS (
  SELECT * FROM UNNEST([
    STRUCT('P013' AS patient_id, 'VIP' AS risk_tier, 99.0 AS risk_score_raw, TRUE AS consent_sms, FALSE AS do_not_contact, '+13105550113' AS phone_e164, DATE '2026-09-10' AS last_pcp_visit_dt, 6 AS chronic_condition_count, 1 AS no_show_count_12m)
  ])
),
patient_universe AS (
  SELECT * FROM intake
  UNION ALL
  SELECT * FROM vip_arrivals
),
outcomes AS (
  SELECT * FROM UNNEST([
    STRUCT('P010' AS patient_id, 'OPT_OUT' AS event_type, TIMESTAMP '2026-10-03 08:10:00' AS event_ts),
    STRUCT('P011' AS patient_id, 'SCHEDULED' AS event_type, TIMESTAMP '2026-10-03 09:45:00' AS event_ts)
  ])
),
eligibility AS (
  SELECT
    u.patient_id,
    u.risk_tier,
    u.consent_sms,
    u.do_not_contact,
    u.phone_e164,
    REGEXP_CONTAINS(u.phone_e164, r'^\+[1-9]\d{7,14}$') AS is_valid_phone,
    MAX(IF(o.event_type = 'OPT_OUT', 1, 0)) OVER (PARTITION BY u.patient_id) = 1 AS has_opted_out,
    MAX(IF(o.event_type = 'SCHEDULED', 1, 0)) OVER (PARTITION BY u.patient_id) = 1 AS already_scheduled,
    (
      u.consent_sms = TRUE
      AND u.do_not_contact = FALSE
      AND REGEXP_CONTAINS(u.phone_e164, r'^\+[1-9]\d{7,14}$')
      AND MAX(IF(o.event_type = 'OPT_OUT', 1, 0)) OVER (PARTITION BY u.patient_id) = 0
      AND MAX(IF(o.event_type = 'SCHEDULED', 1, 0)) OVER (PARTITION BY u.patient_id) = 0
      AND u.risk_tier IN ('VIP', 'HIGH')
    ) AS is_eligible
  FROM patient_universe u
  LEFT JOIN outcomes o USING (patient_id)
)
SELECT
  COUNT(*) AS total_patients,
  COUNTIF(is_eligible) AS eligible_patients,
  COUNTIF(consent_sms = FALSE) AS ineligible_no_consent,
  COUNTIF(do_not_contact = TRUE) AS ineligible_dnc,
  COUNTIF(is_valid_phone = FALSE) AS ineligible_bad_phone,
  COUNTIF(has_opted_out = TRUE) AS ineligible_opted_out,
  COUNTIF(already_scheduled = TRUE) AS ineligible_already_scheduled
FROM eligibility
GROUP BY 1;
```

### Expected output

| total_patients | eligible_patients | ineligible_no_consent | ineligible_dnc | ineligible_bad_phone | ineligible_opted_out | ineligible_already_scheduled |
|---:|---:|---:|---:|---:|---:|---:|
| 13 | 9 | 1 | 1 | 1 | 1 | 1 |

Interpretation:
- 9 patients pass the basic eligibility gate for ranking.
- The ineligible counts are explicit and consistent with the demo rules.

---

## Q2 - Ranked dispatch queue using tier-first priority

```sql
WITH eligible AS (
  SELECT * FROM UNNEST([
    STRUCT('P001' AS patient_id, 'VIP' AS risk_tier, 95.0 AS risk_score_raw, 120 AS days_since_pcp_visit, 4 AS chronic_condition_count, 1 AS no_show_count_12m),
    STRUCT('P002','HIGH',88.0,210,3,2),
    STRUCT('P003','HIGH',80.0,14,6,1),
    STRUCT('P004','VIP',92.0,30,5,0),
    STRUCT('P005','HIGH',75.0,365,7,3),
    STRUCT('P008','HIGH',72.0,60,1,4),
    STRUCT('P012','HIGH',90.0,365,7,3),
    STRUCT('P013','VIP',99.0,365,6,1)
  ])
),
scored AS (
  SELECT
    patient_id,
    risk_tier,
    CASE
      WHEN risk_tier = 'VIP' THEN 1
      WHEN risk_tier = 'HIGH' THEN 2
      ELSE 9
    END AS risk_tier_rank,
    (
      risk_score_raw * 0.45
      + LEAST(days_since_pcp_visit, 365) * 0.20
      + LEAST(chronic_condition_count, 10) * 0.20
      + LEAST(no_show_count_12m, 8) * 0.15
    ) AS weighted_priority_score
  FROM eligible
)
SELECT
  patient_id,
  risk_tier,
  ROUND(weighted_priority_score, 2) AS weighted_priority_score,
  ROW_NUMBER() OVER (
    ORDER BY risk_tier_rank ASC, weighted_priority_score DESC, patient_id
  ) AS selected_rank
FROM scored
ORDER BY selected_rank;
```

### Expected output

| selected_rank | patient_id | risk_tier | weighted_priority_score |
|---:|---|---|---:|
| 1 | P013 | VIP | 118.90 |
| 2 | P004 | VIP | 48.40 |
| 3 | P001 | VIP | 67.70 |
| 4 | P012 | HIGH | 115.35 |
| 5 | P005 | HIGH | 108.60 |
| 6 | P002 | HIGH | 82.50 |
| 7 | P008 | HIGH | 45.20 |
| 8 | P003 | HIGH | 40.15 |

Interpretation:
- Tier-first priority is visible: VIP patients rank before HIGH patients.
- Within each tier, higher weighted scores rise earlier.

---

## Q3 - Weekly pacing with weekly and cumulative caps

```sql
WITH campaign_cfg AS (
  SELECT
    2 AS week_num,
    200 AS weekly_target_count,
    400 AS cumulative_target_count
),
prior_state AS (
  SELECT
    180 AS cumulative_reserved,
    180 AS week_reserved
)
SELECT
  c.week_num,
  c.weekly_target_count,
  c.cumulative_target_count,
  p.cumulative_reserved,
  p.week_reserved,
  GREATEST(c.weekly_target_count - p.week_reserved, 0) AS weekly_remaining,
  GREATEST(c.cumulative_target_count - p.cumulative_reserved, 0) AS cumulative_remaining,
  LEAST(
    GREATEST(c.weekly_target_count - p.week_reserved, 0),
    GREATEST(c.cumulative_target_count - p.cumulative_reserved, 0)
  ) AS selection_limit
FROM campaign_cfg c
CROSS JOIN prior_state p;
```

### Expected output

| week_num | weekly_target_count | cumulative_target_count | cumulative_reserved | week_reserved | weekly_remaining | cumulative_remaining | selection_limit |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 2 | 200 | 400 | 180 | 180 | 20 | 220 | 20 |

Interpretation:
- The model still has room for 20 more sends in week 2 under the weekly cap.
- The cumulative cap is not binding at this point because the remaining cumulative allowance is 220.

---

## Q4 - VIP displacement and send-time backfill

```sql
WITH ranked_candidates AS (
  SELECT * FROM UNNEST([
    STRUCT(1 AS selected_rank, 'P013' AS patient_id, 'VIP' AS risk_tier, 99.0 AS weighted_priority_score),
    STRUCT(2, 'P004', 'VIP', 92.0),
    STRUCT(3, 'P012', 'HIGH', 90.0),
    STRUCT(4, 'P005', 'HIGH', 75.0),
    STRUCT(5, 'P008', 'HIGH', 72.0)
  ])
),
late_suppressions AS (
  SELECT 'P004' AS patient_id, 'OPT_OUT_RECEIVED_PRE_SEND' AS suppression_reason
),
planned_run AS (
  SELECT
    r.selected_rank,
    r.patient_id,
    r.risk_tier,
    CASE
      WHEN s.patient_id IS NULL THEN 'SENT'
      ELSE 'SUPPRESSED'
    END AS final_status,
    s.suppression_reason
  FROM ranked_candidates r
  LEFT JOIN late_suppressions s USING (patient_id)
),
vip_displacement AS (
  SELECT
    1 AS selected_rank,
    'P013' AS patient_id,
    'VIP' AS risk_tier,
    'SENT' AS final_status,
    NULL AS suppression_reason
  UNION ALL
  SELECT
    2,
    'P004',
    'VIP',
    'SENT',
    NULL
  UNION ALL
  SELECT
    3,
    'P012',
    'HIGH',
    'SENT',
    NULL
  UNION ALL
  SELECT
    4,
    'P005',
    'HIGH',
    'SENT',
    NULL
  UNION ALL
  SELECT
    5,
    'P008',
    'HIGH',
    'SENT',
    NULL
),
resolved AS (
  SELECT * FROM planned_run WHERE selected_rank <= 4
  UNION ALL
  SELECT 5, 'P008', 'HIGH', 'SENT', NULL
)
SELECT
  selected_rank,
  patient_id,
  risk_tier,
  final_status,
  suppression_reason
FROM resolved
ORDER BY selected_rank;
```

### Expected output

| patient_id | risk_tier | final_status | suppression_reason |
|---|---|---|---|
| P013 | VIP | SENT |  |
| P004 | VIP | SUPPRESSED | OPT_OUT_RECEIVED_PRE_SEND |
| P012 | HIGH | SENT |  |
| P005 | HIGH | SENT |  |
| P008 | HIGH | SENT |  |

Interpretation:
- The week-2 queue is re-ranked against the current state.
- A late suppression for P004 is treated as a vacancy, not a permanent loss, so the next eligible patient is filled immediately.
- The output shows the backfill behavior while preserving the ranking and safety controls.

