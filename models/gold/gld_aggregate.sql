-- =============================================================================
-- MODEL: gld_aggregate  (Gold layer, materialized as TABLE)
-- SOURCE: slv_consolidated_usage, slv_monthly_metrics
-- PURPOSE: Top-level regional and segment aggregate for dashboards/reporting.
--          One row per (date, region, segment, is_licensed).
--
-- NOTE ON REGION & SEGMENT:
--   The source data does not currently carry region or segment attributes.
--   This model uses placeholder logic (NTILE bucketing and a static region
--   list) so the pipeline runs end-to-end.
--   When a proper account-dimension / segment table is available, replace
--   the placeholder CTEs below with a join to that table.
-- =============================================================================

with consolidated as (

    select * from {{ ref('slv_consolidated_usage') }}

),

monthly as (

    select * from {{ ref('slv_monthly_metrics') }}
    where window = 'R28'

),

-- ── Placeholder region assignment ────────────────────────────────────────────
-- Assigns a region by hashing the account_id until a real dimension exists.
-- Replace this CTE with: left join dim_account on account_id
account_region as (

    select distinct
        account_id,
        case mod(hash(account_id), 4)
            when 0 then 'NAMER'
            when 1 then 'APAC'
            when 2 then 'EMEA'
            else        'LATAM'
        end             as region,
        -- Segment encoded as numeric bucket (1–5)
        mod(abs(hash(account_id)), 5) + 1 as segment,
        -- Licensed flag alternates for demo purposes
        (mod(hash(account_id), 2) = 0)    as is_licensed

    from consolidated

),

-- ── Join usage to region dimension ───────────────────────────────────────────
enriched_usage as (

    select
        c.report_date               as date,
        ar.region,
        ar.segment,
        ar.is_licensed,
        c.account_id,
        c.active_users,
        c.phone_usage

    from consolidated c
    inner join account_region ar
        on c.account_id = ar.account_id
    where c.window = 'R28'

),

-- ── Pull 16+ day active users from monthly metrics ───────────────────────────
with_16plus as (

    select
        eu.*,
        coalesce(m.users_active_16plus_days, 0) as users_active_16plus_days

    from enriched_usage eu
    left join monthly m
        on  eu.account_id = m.account_id
        and eu.date       = m.report_date

),

-- ── Roll up to region + segment grain ────────────────────────────────────────
aggregated as (

    select
        date,
        region,
        segment,
        is_licensed,
        count(distinct account_id)         as active_accounts,
        sum(active_users)                  as active_users,
        round(sum(phone_usage), 2)         as phone_usage,
        sum(users_active_16plus_days)      as users_active_16plus_days

    from with_16plus
    group by 1, 2, 3, 4

)

select * from aggregated
