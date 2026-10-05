# Assumptions and Risk/Impact Matrix

## Assumptions
1. API input delivers patient identifiers, contactability fields, risk tier, and required consent flags.
2. Initial pool starts at 1,000 targetable patients across High and VIP tiers.
3. New VIP arrivals may be introduced during weeks 1-5.
4. Weekly pacing checkpoints are cumulative: 20%, 40%, 60%, 80%, 100%.
5. Messaging vendor and scheduling systems return delivery and appointment outcomes at least daily.
6. Pilot allows near-daily batch orchestration rather than strict real-time processing.

## Risk and Impact Table
| Assumption | Risk if False | Business Impact | Mitigation |
|---|---|---|---|
| API payload includes required eligibility fields | Incomplete eligibility evaluation | Compliance and outreach quality issues | Apply schema validation and reject invalid payloads |
| VIP arrivals remain moderate | Late surge displaces too many High-risk patients | Perceived fairness and campaign instability | Reserve configurable weekly slots for High-risk floor |
| Outcome events arrive daily | Reporting lag and weak optimization feedback | Slower campaign tuning | Add late-arriving data reconciliation window |
| Suppression logic is current | Ineligible outreach attempts | Compliance and patient trust risk | Recheck suppression at dispatch execution time |
| Cumulative pacing is implemented correctly | Under-send or over-send across 5 weeks | Pilot objective miss or call center overload | Enforce dual guardrails: weekly cap + cumulative threshold |
| Contact data quality is sufficient | High bounce or undelivered rates | Lower scheduling conversion | Add pre-send phone validity checks and monitor deliverability |

## Why This Matters
This pilot succeeds only if it balances two goals simultaneously:
- Maximize outreach impact for highest-risk patients.
- Maintain controlled operational load and compliance integrity.
