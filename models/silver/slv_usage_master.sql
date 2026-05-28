-- =============================================================================
-- MODEL: slv_usage_master  (Silver layer, materialized as TABLE)
-- SOURCE: slv_combined_channels, slv_acct_first_active, slv_user_first_active
-- PURPOSE: Daily per-user usage metrics enriched with first-active dates.
--          One row per (date, user_id, account_id).
-- =============================================================================

with combined as (

    select * from {{ ref('slv_combined_channels') }}

),

acct_fa as (

    select * from {{ ref('slv_acct_first_active') }}

),

user_fa as (

    select * from {{ ref('slv_user_first_active') }}

),

-- Aggregate raw interactions to one row per user per day
daily_user_agg as (

    select
        start_date                                                    as date,
        user_id,
        account_id,

        -- Phone sessions = rows that came from the phone source table
        sum(case when modality = 'Phone' then 1 else 0 end)          as phone_sessions,

        -- Inbound phone minutes
        sum(
            case
                when modality = 'Phone' and direction = 'INBOUND'
                then duration_sec / 60.0
                else 0
            end
        )                                                             as inbound_phone_mins,

        -- Chat sessions
        sum(case when modality = 'Chat' then 1 else 0 end)           as chat_sessions,

        -- Sessions that met SLA
        sum(case when sla_achieved = true then 1 else 0 end)         as sla_achieved_sessions

    from combined
    group by 1, 2, 3

),

enriched as (

    select
        d.date,
        d.user_id,
        d.account_id,
        a.account_first_active,
        u.user_first_active,
        d.phone_sessions,
        round(d.inbound_phone_mins, 2)  as inbound_phone_mins,
        d.chat_sessions,
        d.sla_achieved_sessions

    from daily_user_agg d
    left join acct_fa a
        on d.account_id = a.account_id
    left join user_fa u
        on d.user_id    = u.user_id
        and d.account_id = u.account_id

)

select * from enriched
