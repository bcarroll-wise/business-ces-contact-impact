WITH kyc_contacts AS (
    SELECT
        cs.CASE__PROFILE_ID::int AS profile_id,
        cs.CASE__CREATION_TS,
        cs.CASE__ID,
        cs.CONTACT__UNIFIED_ATTRIBUTION_TIER_THREE,
        cs.CASE__CONTAINS_VIRTUAL_AGENT
    FROM RPT_CS_DATA.CORE_CS_PRODUCT__ALL_CASES_SUMMARY cs
    WHERE cs.CASE__FIRST_CONTACT_CHANNEL = 'chat'
        AND cs.CASE__PROFILE_TYPE = 'BUSINESS'
        AND cs.CONTACT__UNIFIED_ATTRIBUTION_TIER_ONE = 'kyc'
        AND cs.CASE__CREATION_TS >= '2024-10-01'
),
contact_summary AS (
    SELECT
        kc.profile_id,
        ces.survey_ts,
        COUNT(*) AS kyc_contact_count,
        MIN(kc.CASE__CREATION_TS) AS first_kyc_contact_ts,
        MAX(kc.CASE__CREATION_TS) AS last_kyc_contact_ts
    FROM kyc_contacts kc
        INNER JOIN ces_responses ces ON kc.profile_id = ces.profile_id
    WHERE kc.CASE__CREATION_TS < ces.survey_ts
    GROUP BY kc.profile_id, ces.survey_ts
),
ces_responses AS (
    SELECT
        message:profileId::int AS profile_id,
        message:userId::int AS user_id,
        message:feedback.score::int AS ces_score,
        REPLACE(message:feedback.comment, '"', '') AS ces_comment,
        CAST(message:submittedDate AS TIMESTAMP) AS survey_ts,
        CAST(message:submittedDate AS DATE) AS survey_date,
        message:payload."tw-client-platform"::varchar AS platform
    FROM ANALYTICS_DB.KAFKA.feedback_updated
    WHERE message:survey ILIKE '%BUSINESS_ONBOARDING_VERIFICATION_DROP_OFF_SURVEY%'
        AND message:submittedDate >= '2024-10-01'
        AND message:profileId::int != 0
    QUALIFY ROW_NUMBER() OVER (PARTITION BY message:profileId::int ORDER BY message:submittedDate) = 1
),
verification_start AS (
    SELECT
        PROFILE_ID AS profile_id,
        MIN(DATE_CREATED) AS verification_start_ts
    FROM FX.BUSINESS_AUTOMATED_VERIFICATION
    GROUP BY PROFILE_ID
),
-- Cohort 1: CES respondents who HAD a KYC contact (all of them)
contacted_cohort AS (
    SELECT ces.profile_id
    FROM ces_responses ces
        INNER JOIN contact_summary cs ON ces.profile_id = cs.profile_id
        INNER JOIN verification_start vs ON ces.profile_id = vs.profile_id
),
-- Cohort 2: CES respondents who did NOT have a KYC contact (sampled to match cohort 1 size)
not_contacted_cohort AS (
    SELECT ces.profile_id
    FROM ces_responses ces
        INNER JOIN verification_start vs ON ces.profile_id = vs.profile_id
    WHERE NOT EXISTS (SELECT 1 FROM contact_summary cs WHERE cs.profile_id = ces.profile_id)
    QUALIFY ROW_NUMBER() OVER (ORDER BY RANDOM(42)) <= (SELECT COUNT(*) FROM contacted_cohort)
),
-- Combined sample
sample_profiles AS (
    SELECT profile_id, 1 AS had_kyc_contact FROM contacted_cohort
    UNION ALL
    SELECT profile_id, 0 AS had_kyc_contact FROM not_contacted_cohort
),
-- Follow-on transactions (one row per transfer)
transactions AS (
    SELECT
        mm.PROFILE_ID AS profile_id,
        mm.TRANSFER_ID,
        mm.ACTION_CREATED_AT_TIMESTAMP::DATE AS transaction_date,
        mm.INVOICE_AMOUNT_GBP
    FROM ANALYTICS_DB.RPT_CORE_ANALYTICS.money_movement_core mm
    WHERE mm.IS_SUCCESSFUL_MONEY_MOVEMENT = TRUE
        AND mm.ACTION_CREATED_AT_TIMESTAMP >= '2024-10-01'
    QUALIFY ROW_NUMBER() OVER (PARTITION BY mm.PROFILE_ID, mm.TRANSFER_ID ORDER BY mm.ACTION_CREATED_AT_TIMESTAMP) = 1
)
SELECT
    sp.profile_id,
    sp.had_kyc_contact,
    -- CES
    ces.ces_score,
    ces.ces_comment,
    ces.survey_date,
    ces.platform,
    -- Verification
    vs.verification_start_ts,
    -- Contact detail
    cs.kyc_contact_count,
    cs.first_kyc_contact_ts,
    cs.last_kyc_contact_ts,
    -- Transactions post-survey
    t.TRANSFER_ID,
    t.transaction_date,
    t.INVOICE_AMOUNT_GBP
FROM sample_profiles sp
    INNER JOIN ces_responses ces ON sp.profile_id = ces.profile_id
    INNER JOIN verification_start vs ON sp.profile_id = vs.profile_id
    LEFT JOIN contact_summary cs ON sp.profile_id = cs.profile_id
    LEFT JOIN transactions t ON sp.profile_id = t.profile_id
        AND t.transaction_date >= ces.survey_date
ORDER BY sp.profile_id, t.transaction_date
