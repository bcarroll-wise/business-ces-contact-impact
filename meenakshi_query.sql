WITH kyc_contacts AS (
    SELECT cs.CASE__PROFILE_ID::int AS profile_id,
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
ces_responses AS (
    SELECT message :profileId::int AS profile_id,
        message :userId::int AS user_id,
        message :feedback.score::int AS ces_score,
        REPLACE(message :feedback.comment, '"', '') AS ces_comment,
        CAST(message :submittedDate AS TIMESTAMP) AS survey_ts,
        CAST(message :submittedDate AS DATE) AS survey_date,
        message :payload. "tw-client-platform"::varchar AS platform
    FROM ANALYTICS_DB.KAFKA.feedback_updated
    WHERE message :survey ILIKE '%BUSINESS_ONBOARDING_VERIFICATION_DROP_OFF_SURVEY%'
        AND message :submittedDate >= '2024-10-01'
        AND message :profileId::int != 0 QUALIFY ROW_NUMBER() OVER (
            PARTITION BY message :profileId::int
            ORDER BY message :submittedDate
        ) = 1
),
contact_summary AS (
    SELECT kc.profile_id,
        ces.survey_ts,
        COUNT(*) AS kyc_contact_count,
        MIN(kc.CASE__CREATION_TS) AS first_kyc_contact_ts,
        MAX(kc.CASE__CREATION_TS) AS last_kyc_contact_ts
    FROM kyc_contacts kc
        INNER JOIN ces_responses ces ON kc.profile_id = ces.profile_id
    WHERE kc.CASE__CREATION_TS < ces.survey_ts
    GROUP BY kc.profile_id,
        ces.survey_ts
),
verification_start AS (
    SELECT PROFILE_ID AS profile_id,
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
    group by 1
),
-- Cohort 2: CES respondents who did NOT have a KYC contact (sampled to match cohort 1 size)
not_contacted_cohort AS (
    SELECT ces.profile_id
    FROM ces_responses ces
        left join contacted_cohort c on c.profile_id = ces.profile_id
    where c.profile_id is null
),
-- Combined sample
sample_profiles AS (
    SELECT profile_id,
        1 AS had_kyc_contact
    FROM contacted_cohort
    UNION ALL
    SELECT profile_id,
        0 AS had_kyc_contact
    FROM not_contacted_cohort
),
-- Follow-on transactions (one row per transfer)
transactions AS (
    SELECT mm.PROFILE_ID AS profile_id,
        count(distinct mm.TRANSFER_ID) as tot_transfers,
        min(mm.ACTION_CREATED_AT_TIMESTAMP)::DATE AS first_transaction_date,
        sum(mm.INVOICE_AMOUNT_GBP) as tot_vol
    FROM ANALYTICS_DB.RPT_CORE_ANALYTICS.money_movement_core mm
    WHERE mm.IS_SUCCESSFUL_MONEY_MOVEMENT = TRUE
        AND mm.ACTION_CREATED_AT_TIMESTAMP >= '2024-10-01'
        and mm.AGGREGATION_TYPE not ilike '%duplicate%'
    group by 1
)
SELECT case
        when sp.had_kyc_contact = 0 then 'no kyc contact'
        else 'has kyc contact'
    end has_kyc_contact,
    case
        when ces.ces_score > 5 then '>5'
        else '<=5'
    end as ces_score,
    sum(t.tot_transfers) / count(distinct sp.profile_id) as trans_per_profile_post_contact,
    sum(t.tot_vol) / count(distinct sp.profile_id) as trans_vol_per_profile_post_contact
FROM sample_profiles sp
    INNER JOIN ces_responses ces ON sp.profile_id = ces.profile_id --  LEFT JOIN contact_summary cs ON sp.profile_id = cs.profile_id
    LEFT JOIN transactions t ON sp.profile_id = t.profile_id
    AND t.first_transaction_date >= ces.survey_date
group BY has_kyc_contact,
    2;