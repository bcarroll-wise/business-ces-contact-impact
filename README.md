# Business CES & Support Contact Impact on Follow-On Transactions

Investigates whether support contact rate during KYC onboarding is a valid proxy for user experience, and quantifies the relationship between CES (Customer Effort Score), support contacts, and follow-on transaction behaviour for business customers.

## Headline

**Contact rate is confounded by intent: contacted users report worse experience (CES 5.46 vs 5.67) but make 30% more follow-on transfers. CES isolates the true friction signal that contact rate cannot.**

## Key findings

| Outcome | Signal? | Notes |
|---------|---------|-------|
| CES → follow-on transfer count | +8.0% per point *** | NegBin model, n=9,409 |
| CES → follow-on transfer value | +9.4% per point *** | Gamma GLM, n=9,034 |
| KYC contact → transfer count | +30.4% *** | Intent confound — not a bad-experience signal |
| CES × Contact interaction | ns (p=0.44) | CES slope is the same regardless of contact status |
| Contact → conversion rate | Higher conversion for contacted | χ² significant — again, intent dominates |
| Contact → time to 2nd transfer | Contacted users slower | Hesitancy signal visible in timing, masked in volume |

## Method

- **Data**: 11,920 business profiles who received the Business Onboarding Verification Drop-Off CES survey (Dec 2024+), matched to KYC support contacts and post-survey transaction history
- **Design**: Balanced cohorts (5,960 contacted / 5,960 not contacted, random-sampled)
- **Models**: Negative Binomial (count), Gamma GLM with log-link (value), interaction terms
- **Controls**: Platform (Web vs Mobile Web), contact status. Winsorised at p95.

## Important caveats

1. Observational — contact status is not randomly assigned; users who contact support differ in intent and complexity
2. CES is measured at a single point during onboarding drop-off; does not capture full longitudinal experience
3. Sample is limited to users who received and responded to the drop-off survey (selection bias)
4. No controls for business size, industry, or country (these may confound both contact propensity and transaction volume)
5. Follow-on window is unbounded — later analysis should cap at 30/60/90 days

## Implication

Contact rate conflates intent with experience and cannot serve as a standalone proxy for user friction. A direct experience measure (CES) is required to isolate the friction signal. The CES=7 convergence in time-to-2nd-transfer shows that when experience is excellent, contact history ceases to matter — confirming CES captures actionable friction that operational metrics miss.

## Repo layout

| File | Purpose |
|------|---------|
| `CES and Contacts and Follow On transaction.ipynb` | Full analysis notebook |
| `business_ces_contact_impact.sql` | Primary data extraction query (Snowflake) |
| `business_contacts_ces_transactions.sql` | Cohort-building query with balanced sampling |
| `Visualisations/` | Exported chart PNGs |
| `index.html` | Branded HTML readout (GitHub Pages) |
| `requirements.txt` | Python dependencies |

## Run

```bash
pip install -r requirements.txt
jupyter notebook "CES and Contacts and Follow On transaction.ipynb"
```

## Notes

- Data CSV excluded from repo (113MB, contains profile IDs). Query from Snowflake using the included SQL files.
- `wise_colours` is a local utility module not included — charts will not re-render without it. Pre-exported PNGs are provided.
- Data sourced from `ANALYTICS_DB.KAFKA.feedback_updated`, `RPT_CS_DATA.CORE_CS_PRODUCT__ALL_CASES_SUMMARY`, and `ANALYTICS_DB.RPT_CORE_ANALYTICS.money_movement_core`.
