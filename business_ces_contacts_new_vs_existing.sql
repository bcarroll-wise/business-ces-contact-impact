-- Business CES + Contacts: new vs existing user, matched-cohort, transaction-level.
-- One row per (profile, post-survey transfer). Profiles that never transacted post
-- survey are kept with NULL transaction fields so conversion stays computable.
--
-- TIMELINE THIS QUERY ENCODES
--   New user:      verification_start -> [contact?] -> survey -> transactions
--   Existing user: transactions -> verification_start -> [contact?] -> survey -> transactions
--
-- Definitions (agreed):
--   * Population: business profiles who took the onboarding-verification drop-off
--     CES survey AFTER a verification attempt. "verification_start" = the LATEST
--     verification row at/before the survey (the re-verification episode being
--     rated), NOT the profile's first-ever verification.
--   * Contacted cohort: had a KYC chat contact (business, tier-1 = kyc) strictly
--     BETWEEN verification_start AND survey. Matched 1:1 against a reproducible
--     RANDOM(42) sample of respondents with no such contact.
--   * IS_EXISTING_USER: had >=1 successful money movement BEFORE verification_start.
--     (~31% of respondents on the latest-pre-survey anchor.)
--   * Post-survey transactions: every successful transfer on/after the survey date,
--     kept for everyone regardless of pre-verification activity.
WITH ces_responses AS (
    SELECT message:profileId::int AS profile_id,
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
-- Survey must come after a verification attempt; anchor on the latest
-- verification at/before the survey (the episode being rated).
verification_episode AS (
    SELECT c.profile_id,
        c.user_id,
        c.ces_score,
        c.ces_comment,
        c.survey_ts,
        c.survey_date,
        c.platform,
        MAX(v.DATE_CREATED) AS verification_start_ts
    FROM ces_responses c
        INNER JOIN FX.BUSINESS_AUTOMATED_VERIFICATION v ON v.PROFILE_ID = c.profile_id
        AND v.DATE_CREATED <= c.survey_ts
    GROUP BY c.profile_id, c.user_id, c.ces_score, c.ces_comment,
        c.survey_ts, c.survey_date, c.platform
),
-- KYC chat contacts strictly within the verification window (start .. survey).
kyc_contacts_in_window AS (
    SELECT e.profile_id,
        COUNT(*) AS kyc_contact_count,
        MIN(cs.CASE__CREATION_TS) AS first_kyc_contact_ts,
        MAX(cs.CASE__CREATION_TS) AS last_kyc_contact_ts
    FROM verification_episode e
        INNER JOIN RPT_CS_DATA.CORE_CS_PRODUCT__ALL_CASES_SUMMARY cs ON cs.CASE__PROFILE_ID = e.profile_id::varchar
        AND cs.CASE__CREATION_TS >= e.verification_start_ts
        AND cs.CASE__CREATION_TS < e.survey_ts
    WHERE cs.CASE__FIRST_CONTACT_CHANNEL = 'chat'
        AND cs.CASE__PROFILE_TYPE = 'BUSINESS'
        AND cs.CONTACT__UNIFIED_ATTRIBUTION_TIER_ONE = 'kyc'
    GROUP BY e.profile_id
),
contacted_cohort AS (
    SELECT profile_id FROM kyc_contacts_in_window
),
-- Equal-n reproducible sample of respondents with no in-window KYC contact.
not_contacted_cohort AS (
    SELECT e.profile_id
    FROM verification_episode e
        LEFT JOIN contacted_cohort cc ON cc.profile_id = e.profile_id
    WHERE cc.profile_id IS NULL
    QUALIFY ROW_NUMBER() OVER (ORDER BY RANDOM(42)) <= (SELECT COUNT(*) FROM contacted_cohort)
),
-- Cohort with all per-profile attributes resolved (small: ~2x contacted count).
cohort AS (
    SELECT e.profile_id,
        e.user_id,
        e.ces_score,
        e.ces_comment,
        e.survey_ts,
        e.survey_date,
        e.platform,
        e.verification_start_ts,
        CASE WHEN cc.profile_id IS NOT NULL THEN 1 ELSE 0 END AS had_kyc_contact,
        COALESCE(kc.kyc_contact_count, 0) AS kyc_contact_count,
        kc.first_kyc_contact_ts,
        kc.last_kyc_contact_ts
    FROM verification_episode e
        INNER JOIN (
            SELECT profile_id FROM contacted_cohort
            UNION ALL
            SELECT profile_id FROM not_contacted_cohort
        ) s ON s.profile_id = e.profile_id
        LEFT JOIN contacted_cohort cc ON cc.profile_id = e.profile_id
        LEFT JOIN kyc_contacts_in_window kc ON kc.profile_id = e.profile_id
),
-- Existing user = any successful money movement BEFORE verification_start.
-- Joined to the small cohort only, so this is cheap.
pre_verification_activity AS (
    SELECT co.profile_id,
        COUNT(*) AS pre_verif_txn_count
    FROM cohort co
        INNER JOIN ANALYTICS_DB.RPT_CORE_ANALYTICS.money_movement_core mm ON mm.PROFILE_ID = co.profile_id
        AND mm.ACTION_CREATED_AT_TIMESTAMP < co.verification_start_ts
    WHERE mm.IS_SUCCESSFUL_MONEY_MOVEMENT = TRUE
        AND mm.AGGREGATION_TYPE NOT ILIKE '%duplicate%'
    GROUP BY co.profile_id
),
-- Post-survey transactions, one row per transfer (deduplicated). Cohort only.
post_survey_transactions AS (
    SELECT co.profile_id,
        mm.TRANSFER_ID,
        mm.ACTION_CREATED_AT_TIMESTAMP::DATE AS transaction_date,
        mm.INVOICE_AMOUNT_GBP
    FROM cohort co
        INNER JOIN ANALYTICS_DB.RPT_CORE_ANALYTICS.money_movement_core mm ON mm.PROFILE_ID = co.profile_id
        AND mm.ACTION_CREATED_AT_TIMESTAMP::DATE >= co.survey_date
    WHERE mm.IS_SUCCESSFUL_MONEY_MOVEMENT = TRUE
        AND mm.AGGREGATION_TYPE NOT ILIKE '%duplicate%'
    QUALIFY ROW_NUMBER() OVER (PARTITION BY co.profile_id, mm.TRANSFER_ID ORDER BY mm.ACTION_CREATED_AT_TIMESTAMP) = 1
)
SELECT co.profile_id AS PROFILE_ID,
    co.had_kyc_contact AS HAD_KYC_CONTACT,
    co.ces_score AS CES_SCORE,
    co.ces_comment AS CES_COMMENT,
    co.survey_date AS SURVEY_DATE,
    co.platform AS PLATFORM,
    co.verification_start_ts AS VERIFICATION_START_TS,
    co.kyc_contact_count AS KYC_CONTACT_COUNT,
    co.first_kyc_contact_ts AS FIRST_KYC_CONTACT_TS,
    co.last_kyc_contact_ts AS LAST_KYC_CONTACT_TS,
    -- New vs existing (pre-verification money movement, latest-pre-survey anchor)
    CASE WHEN pv.pre_verif_txn_count > 0 THEN 1 ELSE 0 END AS IS_EXISTING_USER,
    COALESCE(pv.pre_verif_txn_count, 0) AS PRE_VERIF_TXN_COUNT,
    -- Transaction-level fields (NULL for profiles that never transacted post survey)
    pst.TRANSFER_ID,
    pst.transaction_date AS TRANSACTION_DATE,
    pst.INVOICE_AMOUNT_GBP
FROM cohort co
    LEFT JOIN pre_verification_activity pv ON pv.profile_id = co.profile_id
    LEFT JOIN post_survey_transactions pst ON pst.profile_id = co.profile_id
ORDER BY co.profile_id,
    pst.transaction_date;
