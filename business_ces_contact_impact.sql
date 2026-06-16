WITH ces_all AS (
    SELECT DISTINCT message :profileId::int AS profile_id,
        message :userId::int AS user_id,
        message :feedback.score::int AS ces_score,
        replace(message :feedback.comment, '"', '') AS ces_comment,
        CAST(message :submittedDate AS TIMESTAMP) AS survey_ts,
        CAST(message :submittedDate AS DATE) AS survey_date,
        message :payload. "tw-client-platform"::varchar AS platform
    FROM ANALYTICS_DB.KAFKA.feedback_updated
    WHERE message :survey ILIKE '%BUSINESS_ONBOARDING_VERIFICATION_DROP_OFF_SURVEY%'
        AND message :submittedDate >= '2024-12-01'
        AND message :profileId::int != 0
),
verification_start AS (
    SELECT PROFILE_ID AS profile_id,
        MIN(DATE_CREATED) AS verification_start_ts
    FROM FX.BUSINESS_AUTOMATED_VERIFICATION
    GROUP BY PROFILE_ID
),
ces_deduped AS (
    SELECT c.*,
        vs.verification_start_ts
    FROM ces_all c
        INNER JOIN verification_start vs ON c.profile_id = vs.profile_id
    WHERE c.survey_ts >= vs.verification_start_ts
    QUALIFY ROW_NUMBER() OVER (PARTITION BY c.profile_id ORDER BY c.survey_ts) = 1
),
ces_profiles AS (
    SELECT *
    FROM ces_deduped
    QUALIFY ROW_NUMBER() OVER (ORDER BY RANDOM(42)) <= 20000
),
business_attrs AS (
    SELECT BUSINESS_USER_PROFILE_ID AS profile_id,
        COMPANY_TYPE,
        FIRST_LEVEL_CATEGORY,
        INDUSTRY_CATEGORY
    FROM ANALYTICS_DB.PROFILE.business_profile_extension
    QUALIFY ROW_NUMBER() OVER (PARTITION BY BUSINESS_USER_PROFILE_ID ORDER BY BUSINESS_USER_PROFILE_ID) = 1
),
-- KYC support contacts between verification start and survey date
kyc_contacts_before_survey AS (
    SELECT c.profile_id,
        c.user_id,
        c.survey_date,
        COUNT(*) AS kyc_contact_count,
        MAX(cs.CASE__CREATION_TS) AS last_kyc_contact_ts,
        DATEDIFF(
            'day',
            MAX(cs.CASE__CREATION_TS),
            c.survey_ts
        ) AS days_since_last_contact
    FROM ces_profiles c
        INNER JOIN RPT_CS_DATA.CORE_CS_PRODUCT__ALL_CASES_SUMMARY cs ON cs.CASE__PROFILE_ID = c.profile_id::varchar
        AND cs.CASE__CREATION_TS < c.survey_ts
        AND cs.CASE__CREATION_TS >= c.verification_start_ts
    WHERE cs.CASE__FIRST_CONTACT_CHANNEL = 'chat'
        AND cs.CASE__PROFILE_TYPE = 'business'
        AND cs.CONTACT__UNIFIED_ATTRIBUTION_TIER_ONE = 'kyc'
    GROUP BY c.profile_id,
        c.user_id,
        c.survey_date,
        c.survey_ts
),
-- Failed checks from automated verification BEFORE survey date
-- FAILED_CHECKS column contains array like "[BUSINESS_DIRECTORS_CHECK, BUSINESS_SHAREHOLDERS_CHECK]"
-- Each row = one verification attempt; we count how many times each check type appears as failed
check_failures_before_survey AS (
    SELECT c.profile_id,
        c.user_id,
        c.survey_date,
        COUNT(*) AS auto_verification_attempts,
        SUM(CASE WHEN bav.STATE = 'SUCCESS' THEN 1 ELSE 0 END) AS auto_verification_successes,
        SUM(CASE WHEN bav.STATE != 'SUCCESS' THEN 1 ELSE 0 END) AS auto_verification_failures,
        -- Count failures per check type (each row where that check appears in FAILED_CHECKS)
        SUM(CASE WHEN bav.FAILED_CHECKS ILIKE '%BUSINESS_EXISTENCE_CHECK%' THEN 1 ELSE 0 END) AS existence_check_failure_count,
        SUM(CASE WHEN bav.FAILED_CHECKS ILIKE '%BUSINESS_DIRECTORS_CHECK%' THEN 1 ELSE 0 END) AS directors_check_failure_count,
        SUM(CASE WHEN bav.FAILED_CHECKS ILIKE '%BUSINESS_SHAREHOLDERS_CHECK%' THEN 1 ELSE 0 END) AS shareholders_check_failure_count,
        SUM(CASE WHEN bav.FAILED_CHECKS ILIKE '%BUSINESS_ACTIVITIES_CHECK%' THEN 1 ELSE 0 END) AS activities_check_failure_count,
        SUM(CASE WHEN bav.FAILED_CHECKS ILIKE '%BUSINESS_NAME_SUSPICIOUS%' THEN 1 ELSE 0 END) AS name_suspicious_failure_count,
        SUM(CASE WHEN bav.FAILED_CHECKS ILIKE '%PERSONAL_VERIFICATION_CHECK%' THEN 1 ELSE 0 END) AS personal_verification_failure_count,
        SUM(CASE WHEN bav.FAILED_CHECKS ILIKE '%BUSINESS_AUTH_REP_CHECK%' THEN 1 ELSE 0 END) AS auth_rep_failure_count,
        MAX(bav.STATE) AS latest_auto_verification_state
    FROM ces_profiles c
        INNER JOIN FX.BUSINESS_AUTOMATED_VERIFICATION bav ON bav.PROFILE_ID = c.profile_id
        AND bav.DATE_CREATED < c.survey_ts
        AND bav.DATE_CREATED >= c.verification_start_ts
    GROUP BY c.profile_id, c.user_id, c.survey_date
),
-- First transaction after survey date per profile+survey response
first_transaction AS (
    SELECT c.profile_id,
        c.user_id,
        c.survey_date,
        MIN(mm.ACTION_CREATED_AT_TIMESTAMP) AS first_transaction_date,
        MIN_BY(
            mm.INVOICE_AMOUNT_GBP,
            mm.ACTION_CREATED_AT_TIMESTAMP
        ) AS first_transaction_gbp,
        MIN_BY(
            mm.PROFILE_COUNTRY_CODE_AT_MONEY_MOVEMENT,
            mm.ACTION_CREATED_AT_TIMESTAMP
        ) AS country_code
    FROM ANALYTICS_DB.RPT_CORE_ANALYTICS.money_movement_core mm
        INNER JOIN ces_profiles c ON mm.PROFILE_ID = c.profile_id
    WHERE mm.ACTION_CREATED_AT_TIMESTAMP >= c.survey_date
        AND mm.IS_SUCCESSFUL_MONEY_MOVEMENT = TRUE
    GROUP BY c.profile_id,
        c.user_id,
        c.survey_date
),
-- All transactions from survey date onward (deduplicated by transfer ID)
all_transactions AS (
    SELECT c.profile_id,
        c.user_id,
        c.survey_date,
        mm.ACTION_CREATED_AT_TIMESTAMP::DATE AS transaction_date,
        mm.INVOICE_AMOUNT_GBP
    FROM ANALYTICS_DB.RPT_CORE_ANALYTICS.money_movement_core mm
        INNER JOIN ces_profiles c ON mm.PROFILE_ID = c.profile_id
    WHERE mm.ACTION_CREATED_AT_TIMESTAMP >= c.survey_date
        AND mm.IS_SUCCESSFUL_MONEY_MOVEMENT = TRUE
    QUALIFY ROW_NUMBER() OVER (PARTITION BY c.profile_id, mm.TRANSFER_ID ORDER BY mm.ACTION_CREATED_AT_TIMESTAMP) = 1
)
SELECT c.profile_id,
    c.user_id,
    c.ces_score,
    c.ces_comment,
    c.survey_date,
    c.platform,
    ft.country_code,
    ba.company_type,
    ba.first_level_category,
    ba.industry_category,
    -- Support contact metrics
    CASE
        WHEN kc.kyc_contact_count IS NOT NULL THEN 1
        ELSE 0
    END AS had_kyc_contact_before_survey,
    COALESCE(kc.kyc_contact_count, 0) AS kyc_contact_count_before_survey,
    kc.days_since_last_contact AS days_since_last_kyc_contact,
    -- Automated verification metrics
    COALESCE(cf.auto_verification_attempts, 0) AS auto_verification_attempts,
    COALESCE(cf.auto_verification_successes, 0) AS auto_verification_successes,
    COALESCE(cf.auto_verification_failures, 0) AS auto_verification_failures,
    cf.latest_auto_verification_state,
    -- Per-check-type failure counts (from FAILED_CHECKS column)
    COALESCE(cf.existence_check_failure_count, 0) AS existence_check_failure_count,
    COALESCE(cf.directors_check_failure_count, 0) AS directors_check_failure_count,
    COALESCE(cf.shareholders_check_failure_count, 0) AS shareholders_check_failure_count,
    COALESCE(cf.activities_check_failure_count, 0) AS activities_check_failure_count,
    COALESCE(cf.name_suspicious_failure_count, 0) AS name_suspicious_failure_count,
    COALESCE(cf.personal_verification_failure_count, 0) AS personal_verification_failure_count,
    COALESCE(cf.auth_rep_failure_count, 0) AS auth_rep_failure_count,
    -- Total check failures across all types
    COALESCE(cf.existence_check_failure_count, 0)
        + COALESCE(cf.directors_check_failure_count, 0)
        + COALESCE(cf.shareholders_check_failure_count, 0)
        + COALESCE(cf.activities_check_failure_count, 0)
        + COALESCE(cf.name_suspicious_failure_count, 0)
        + COALESCE(cf.personal_verification_failure_count, 0)
        + COALESCE(cf.auth_rep_failure_count, 0) AS total_check_failure_count,
    -- Transaction metrics
    ft.first_transaction_date,
    ft.first_transaction_gbp,
    at.transaction_date,
    at.INVOICE_AMOUNT_GBP
FROM ces_profiles c
    LEFT JOIN business_attrs ba ON c.profile_id = ba.profile_id
    LEFT JOIN kyc_contacts_before_survey kc ON c.profile_id = kc.profile_id
    AND c.user_id = kc.user_id
    AND c.survey_date = kc.survey_date
    LEFT JOIN check_failures_before_survey cf ON c.profile_id = cf.profile_id
    AND c.user_id = cf.user_id
    AND c.survey_date = cf.survey_date
    LEFT JOIN first_transaction ft ON c.profile_id = ft.profile_id
    AND c.user_id = ft.user_id
    AND c.survey_date = ft.survey_date
    LEFT JOIN all_transactions at ON c.profile_id = at.profile_id
    AND c.user_id = at.user_id
    AND c.survey_date = at.survey_date
ORDER BY c.profile_id,
    c.survey_date,
    at.transaction_date