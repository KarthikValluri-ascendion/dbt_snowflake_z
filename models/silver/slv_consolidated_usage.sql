-- =============================================================================
-- MODEL: slv_consolidated_usage  (Silver layer, materialized as TABLE)
-- SOURCE: slv_combined_channels
-- PURPOSE: Consolidated cross-product phone usage across all rolling windows
--          (R1 / R7 / R28) per account per day.
--          product_name is a placeholder; join to a product-catalog table
--          when one becomes available.
-- =============================================================================

with combined as (

    select * from {{ ref('slv_combined_channels') }}

),

report_dates as (

    select distinct start_date as report_date, account_id
    from combined

),

r1 as (

    select
        rd.report_date,
        'ZCC Platform'  as product_name,
        'R1'            as window,
        rd.account_id,
        (count(distinct c.user_id) > 0)                        as is_active_account,
        count(distinct c.user_id)                              as active_users,
        round(
            sum(case when c.modality = 'Phone'
                     then c.duration_sec / 60.0 else 0 end), 2
        )                                                      as phone_usage

    from report_dates rd
    left join combined c
        on  rd.account_id = c.account_id
        and c.start_date = rd.report_date
    group by 1, 2, 3, 4

),

r7 as (

    select
        rd.report_date,
        'ZCC Platform'  as product_name,
        'R7'            as window,
        rd.account_id,
        (count(distinct c.user_id) > 0)                        as is_active_account,
        count(distinct c.user_id)                              as active_users,
        round(
            sum(case when c.modality = 'Phone'
                     then c.duration_sec / 60.0 else 0 end), 2
        )                                                      as phone_usage

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
        'ZCC Platform'  as product_name,
        'R28'           as window,
        rd.account_id,
        (count(distinct c.user_id) > 0)                        as is_active_account,
        count(distinct c.user_id)                              as active_users,
        round(
            sum(case when c.modality = 'Phone'
                     then c.duration_sec / 60.0 else 0 end), 2
        )                                                      as phone_usage

    from report_dates rd
    left join combined c
        on  rd.account_id = c.account_id
        and c.start_date between dateadd(day, -27, rd.report_date)
                              and rd.report_date
    group by 1, 2, 3, 4

)

select * from r1
union all
select * from r7
union all
select * from r28
