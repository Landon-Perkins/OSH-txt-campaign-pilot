-- BigQuery Standard SQL
-- Bronze: immutable landing tables for intake and outcome feeds.

CREATE SCHEMA IF NOT EXISTS `bronze`;

CREATE TABLE IF NOT EXISTS `bronze.patient_api_intake` (
  intake_batch_id STRING NOT NULL,
  intake_ts TIMESTAMP NOT NULL,
  patient_id STRING NOT NULL,
  source_system STRING,
  risk_tier STRING,
  risk_score_raw FLOAT64,
  consent_sms BOOL,
  do_not_contact BOOL,
  phone_e164 STRING,
  last_pcp_visit_dt DATE,
  chronic_condition_count INT64,
  no_show_count_12m INT64,
  preferred_language STRING,
  payload_json STRING,
  _ingested_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
)
PARTITION BY DATE(intake_ts)
CLUSTER BY risk_tier, patient_id;

CREATE TABLE IF NOT EXISTS `bronze.vip_arrivals` (
  arrival_batch_id STRING NOT NULL,
  arrival_ts TIMESTAMP NOT NULL,
  patient_id STRING NOT NULL,
  risk_tier STRING,
  vip_reason STRING,
  payload_json STRING,
  _ingested_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
)
PARTITION BY DATE(arrival_ts)
CLUSTER BY patient_id;

CREATE TABLE IF NOT EXISTS `bronze.outreach_outcomes_raw` (
  event_id STRING NOT NULL,
  event_ts TIMESTAMP NOT NULL,
  patient_id STRING NOT NULL,
  campaign_id STRING,
  event_type STRING,
  event_subtype STRING,
  vendor_status_code STRING,
  appointment_id STRING,
  appointment_dt TIMESTAMP,
  event_payload_json STRING,
  _ingested_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
)
PARTITION BY DATE(event_ts)
CLUSTER BY campaign_id, patient_id;
