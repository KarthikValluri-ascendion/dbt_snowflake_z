-- =============================================================================
-- MODEL: slv_roll_29_day_usage  (Silver layer, materialized as TABLE)
-- SOURCE: slv_combined_channels
-- PURPOSE: For every user on every date they were active, compute rolling
--          7-day and 28-day activity window metrics.
--          Uses a self-join (date spine approach) to look back in time.
-- =============================================================================

with combined as (

    select * from {{ ref('slv_combined_channels') }}

),

-- One row per distinct (date, user, account) — the "report date" spine
report_dates as (

    select distinct
        start_date   as report_date,
        user_id,
        account_id
    from combined

),

-- Self-join: for each report date, pull all activity within look-back windows
rolling_activity as (

    select
        r.report_date,
        r.user_id,
        r.account_id,
        r.account_id   as is_paid_user,         -- placeholder; join to billing table for real value

        -- Distinct active days in the last 7 days (report_date inclusive)
        count(distinct
            case
                when c.start_date
                     between dateadd(day, -6, r.report_date) and r.report_date
                then c.start_date
            end
        )                                        as active_days_last_7,

        -- Distinct active days in the last 28 days
        count(distinct
            case
                when c.start_date
                     between dateadd(day, -27, r.report_date) and r.report_date
                then c.start_date
            end
        )                                        as active_days_last_28,

        -- Total chat duration (minutes) on the report date itself
        sum(
            case
                when c.start_date = r.report_date
                     and c.modality = 'Chat'
                then c.duration_sec / 60.0
                else 0
            end
        )                                        as daily_chat_usage,

        -- Total phone duration (minutes) in the last 7 days
        sum(
            case
                when c.start_date
                     between dateadd(day, -6, r.report_date) and r.report_date
                     and c.modality = 'Phone'
                then c.duration_sec / 60.0
                else 0
            end
        )                                        as weekly_phone_usage

    from report_dates r
    left join combined c
        on  r.user_id    = c.user_id
        and r.account_id = c.account_id
        and c.start_date between dateadd(day, -27, r.report_date) and r.report_date

    group by 1, 2, 3, 4

)

select
    report_date,
    user_id,
    account_id,
    is_paid_user,
    active_days_last_7,
    active_days_last_28,
    round(daily_chat_usage,  2)  as daily_chat_usage,
    round(weekly_phone_usage, 2) as weekly_phone_usage
from rolling_activity
