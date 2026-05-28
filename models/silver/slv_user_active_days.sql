-- =============================================================================
-- MODEL: slv_user_active_days  (Silver layer, materialized as TABLE)
-- SOURCE: slv_combined_channels
-- PURPOSE: For each account on each report date, bucket users by how many
--          days they were active in the last-7 and last-28 day windows.
--          Produces engagement-depth metrics used in daily/weekly/monthly
--          metrics models.
-- =============================================================================

with combined as (

    select * from {{ ref('slv_combined_channels') }}

),

-- Distinct active day per user per account
user_day as (

    select distinct
        start_date   as active_date,
        user_id,
        account_id
    from combined

),

-- Spine: every (report_date, user, account) pair
report_spine as (

    select distinct
        start_date   as report_date,
        user_id,
        account_id
    from combined

),

-- Count how many distinct days each user was active in each window
user_window_counts as (

    select
        s.report_date,
        s.user_id,
        s.account_id,

        count(distinct
            case
                when d.active_date
                     between dateadd(day, -6, s.report_date) and s.report_date
                then d.active_date
            end
        )   as active_days_l7,

        count(distinct
            case
                when d.active_date
                     between dateadd(day, -27, s.report_date) and s.report_date
                then d.active_date
            end
        )   as active_days_l28

    from report_spine s
    left join user_day d
        on  s.user_id    = d.user_id
        and s.account_id = d.account_id
        and d.active_date between dateadd(day, -27, s.report_date) and s.report_date

    group by 1, 2, 3

),

-- Bucket users and roll up to account level
account_buckets as (

    select
        report_date,
        account_id,

        -- Users who were active exactly 1 day in last 7
        sum(case when active_days_l7 = 1               then 1 else 0 end) as active_1_day_l7,

        -- Users active 4–7 days in last 7
        sum(case when active_days_l7 between 4 and 7   then 1 else 0 end) as active_4_7_days_l7,

        -- Users who were active exactly 1 day in last 28
        sum(case when active_days_l28 = 1              then 1 else 0 end) as active_1_day_l28,

        -- Users active 16 or more days in last 28
        sum(case when active_days_l28 >= 16            then 1 else 0 end) as active_16plus_days_l28

    from user_window_counts
    group by 1, 2

)

select * from account_buckets
