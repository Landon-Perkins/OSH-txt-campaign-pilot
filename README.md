# Oak Street Health Case Study - Senior Data Engineer

## Objective
Design a pilot solution for a text-message appointment reminder campaign targeting 1,000 high-risk patients over 5 weeks, while protecting call center capacity and prioritizing higher-risk members.

## Slide Presentation
[Google Slide Link]()
TBD

## Scope
- GCP-native design with BigQuery, Cloud Storage, and Cloud Composer.
- Medallion architecture: Bronze, Silver, Gold.
- Layer-specific DQ gates: Bronze DQ, Silver DQ, and Gold DQ.
- Prioritization and pacing logic.
- Backfill mechanism when suppressions occur at send time.
- Gold DQ as the final pre-send gate before the outbound API POST.
- PHI-aware design and auditability.

## Repository Structure
- `sql/bronze/` - Raw landing and normalization SQL.
- `sql/silver/` - Outcome event standardization, eligibility, and scoring transformations.
- `sql/gold/` - Dimensional model and dispatch facts.
- `orchestration/` - Composer DAG and minimal Python dispatch logic.
- `dq/` - Layer-specific DQ checkpoints: Bronze DQ, Silver DQ, and Gold DQ.
- `mock_data/` - Short CSV dataset for interview demonstrations.
- `docs/` - Assumptions, risks, graphs, notes, example queries.

## Demo flow
The walkthrough demonstrates:
1. patient eligibility and universe checks
2. deterministic ranking by tier and score
3. weekly and cumulative pacing logic
4. VIP displacement and backfill behavior

## Core Decisions
1. **20% threshold interpretation**: the prompt is ambiguous, so we state it explicitly. The 20% threshold is a cumulative weekly cap: 200/400/600/800/1,000 cumulative sends, reaching the full pool by week 5. Tier-first prioritization applies within each weekly batch. If stakeholders intended prioritization only after week 5, the same model holds because ranking is independent of pacing; `dim_campaign_week` is the only config change needed.
2. **VIP displacement**: if a patient appears in the VIP arrival feed, that patient is treated as VIP for campaign ranking and can displace unsent non-VIP candidates before dispatch finalization. This is not a promotion from HIGH to VIP; it is a source-of-truth VIP status being honored in the unified patient universe and the Gold ranking step. Implemented end to end in the consolidated Silver and Gold layers: `sql/silver/01_silver.sql` combines the latest intake state with the latest VIP status, and the Gold dispatch logic in `sql/gold/01_gold.sql` re-ranks VIP records ahead of lower-priority unsent High rows.
3. **Backfill at send time**: when a selected patient is suppressed or fails eligibility, that suppression counts as a vacancy, not as a permanent loss. The next-ranked eligible patient is inserted immediately to refill the slot and preserve weekly throughput. Dispatch outcomes are merged in the Gold dispatch layer in `sql/gold/01_gold.sql`, with PLANNED rows moved to SENT/SUPPRESSED/FAILED and backfilled patients inserted directly.
4. **Layer-specific DQ gates**: Bronze DQ validates raw input quality before Silver runs, Silver DQ validates curated outcome events, patient-universe, and score logic before Gold uses them, and Gold DQ validates final dispatch integrity, pacing, and backfill behavior before the outbound send. The Gold DQ gate is the final pre-send check before the vendor API POST.
5. **Re-run safety**: selection counts PLANNED + SENT reservations, not just SENT facts, so a pipeline re-run before dispatch cannot double-book weekly or cumulative capacity. Suppressed patients do not reserve capacity, which keeps backfill behavior deterministic and prevents underfilled weeks caused by late opt-outs or send-time filtering.
6. **Gold dimensional model**: stable business KPI layer for outreach and appointment outcomes.

## Pilot Success Criteria
- Produce 1,000 target patient text messages by end of week 5 unless constrained by eligibility suppressions.
- Maintain auditable and deterministic ranking and selection logic.
- Provide daily and weekly reporting for outreach, engagement, and scheduling outcomes.
- Demonstrate compliance-aware handling of sensitive healthcare data.

## Final takeaway
The architecture prioritizes safe, explainable, and auditable execution. The pipeline is not optimized for cleverness; it is optimized for clarity, control, data quality, and operational trust.