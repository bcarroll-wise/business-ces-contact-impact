# Business CES & Support Contact Impact on Follow-On Transactions

Investigates whether support contact rate during KYC onboarding is a valid proxy for user experience, and quantifies the relationship between CES (Customer Effort Score), KYC support contacts, and follow-on transaction behaviour for business customers.

## Headline

**Contact rate is confounded by intent/need: contacted users report worse experience (CES 5.16 vs 5.74) yet make markedly more follow-on transfers and convert at a higher rate. CES isolates the friction signal that contact rate cannot.**

## Key findings

| Outcome | Signal? | Notes |
|---------|---------|-------|
| CES → follow-on transfer count | +7.5% per point *** | NegBin model |
| CES → follow-on transfer value | +12.5% per point *** | Gamma GLM (log-link) |
| KYC contact → transfer count | +66% *** | Intent confound — not a bad-experience signal |
| CES × Contact interaction | ns (p=0.91) | CES slope is the same regardless of contact status |
| Contact × tenure interaction (volume) | ns (p=0.36) | Effect holds for new and existing users alike |
| Tenure (existing vs new) → volume | +22% *** | Existing users transact more overall (baseline shift) |
| Contact → conversion | New users +17pp; existing already near ceiling | Odds ratios magnified by ceiling; same intent confound |
| Contact → time to 2nd transfer | Contacted users slightly slower | Hesitancy signal visible in timing, masked in volume |
| Contact → CES (mediation) | −0.66 points *** | CES detects the attitudinal hit; controlling for it *increases* the contact-volume link, confirming the intent confound |
| Contact + controls → CES variance | R²=0.029 | Contact is a small *component* of CES; experience is dominated by other drivers (same ~3% as evidence analysis) |

## Method

- **Data**: Business profiles who received the Business Onboarding Verification Drop-Off CES survey, matched to KYC support contacts and post-survey transaction history
- **Cohort**: Matched design — contacted (KYC chat contact between verification start and survey) vs an equal-n random-sampled not-contacted group (~2,900 profiles total)
- **New vs existing**: profiles flagged existing if they had successful money movement before their (latest pre-survey) verification start
- **Models**: Negative Binomial (count), Gamma GLM with log-link (value), logistic (conversion), interaction terms
- **Controls**: Platform (Web vs Mobile Web), CES, contact status, tenure. Winsorised at p95.

## Important caveats

1. Observational — contact status is not randomly assigned; users who contact support differ in intent and complexity
2. CES is measured at a single point during onboarding drop-off; does not capture full longitudinal experience
3. Sample is limited to users who received and responded to the drop-off survey (selection bias)
4. Conversion is defined as any successful money movement on/after the survey over an unbounded window — a generous bar; existing users sit near a conversion ceiling, which inflates contact odds ratios
5. Existing-user sub-cells are small; tenure interaction estimates have wide confidence intervals

## Implication

Contact rate conflates intent/need with experience and cannot serve as a standalone proxy for user friction. A direct experience measure (CES) is required to isolate the friction signal. Contact's positive association with volume and conversion holds for genuinely new users too, confirming the pattern is an intent confound rather than contact being beneficial.

## Repo layout

| File | Purpose |
|------|---------|
| `CES and Contacts and Follow On transaction.ipynb` | Full analysis notebook |
| `business_ces_contacts_new_vs_existing.sql` | Primary data extraction query (Snowflake) — matched cohort, new/existing flag |
| `meenakshi_query.sql` | Stakeholder counter-analysis query, retained for the audience-difference comparison |
| `Visualisations/` | Exported chart PNGs |
| `index.html` | Branded HTML readout (GitHub Pages) |
| `requirements.txt` | Python dependencies |

## Run

```bash
pip install -r requirements.txt
jupyter notebook "CES and Contacts and Follow On transaction.ipynb"
```

## Notes

- Data CSV excluded from repo (contains profile IDs). Query from Snowflake using the included SQL file.
- `wise_colours` is a local utility module not included — charts will not re-render without it. Pre-exported PNGs are provided.
- Data sourced from `ANALYTICS_DB.KAFKA.feedback_updated`, `RPT_CS_DATA.CORE_CS_PRODUCT__ALL_CASES_SUMMARY`, `FX.BUSINESS_AUTOMATED_VERIFICATION`, and `ANALYTICS_DB.RPT_CORE_ANALYTICS.money_movement_core`.
