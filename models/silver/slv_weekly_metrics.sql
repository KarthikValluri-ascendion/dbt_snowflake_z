-- =============================================================================
-- MODEL: slv_weekly_metrics  (Silver layer, materialized as TABLE)
-- SOURCE: slv_combined_channels, slv_user_active_days
-- PURPOSE: Account-level weekly-perspective metrics with R7 and R28 windows.
--          Key difference from daily_metrics: reports users_active_4_7_days
--          instead of users_active_1_day.
-- =============================================================================

with combined as (

    select * from {{ ref('slv_combined_channels') }}

),

user_active as (

    select * from {{ ref('slv_user_active_days') }}

),

report_dates as (

    select distinct start_date as report_date, account_id
    from combined

),

r7 as (

    select
        rd.report_date,
        'R7'            as window,
        rd.account_id,
        true            as is_active_account,
        count(distinct c.user_id)                              as active_users,
        round(
            sum(case when c.modality = 'Chat'
                     then c.duration_sec / 60.0 else 0 end), 2
        )                                                      as chat_usage

    from report_dates rd
    left join combined c
        on  rd.account_id = c.account_id
        and c.start_date between dateadd(day, -6, rd.report_date)
                              and rd.report_date
    group by 1, 2, 3, 4

),

r28 as (

    select
        rd.report_date,
        'R28'           as window,
        rd.account_id,
        true            as is_active_account,
        count(distinct c.user_id)                              as active_users,
        round(
            sum(case when c.modality = 'Chat'
                     then c.duration_sec / 60.0 else 0 end), 2
        )                                                      as chat_usage

    from report_dates rd
    left join combined c
        on  rd.account_id = c.account_id
        and c.start_date between dateadd(day, -27, rd.report_date)
                              and rd.report_date
    group by 1, 2, 3, 4

),

all_windows as (

    select * from r7
    union all
    select * from r28

),

final as (

    select
        a.report_date,
        a.window,
        a.account_id,
        a.is_active_account,
        a.active_users,
        a.chat_usage,
        coalesce(u.active_4_7_days_l7, 0) as users_active_4_7_days

    from all_windows a
    left join user_active u
        on  a.account_id  = u.account_id
        and a.report_date = u.report_date

)

select * from final
