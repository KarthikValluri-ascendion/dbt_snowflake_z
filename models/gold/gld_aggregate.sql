-- =============================================================================
-- MODEL: gld_aggregate  (Gold layer, materialized as TABLE)
-- SOURCE: slv_consolidated_usage, slv_monthly_metrics
-- PURPOSE: Top-level regional and segment aggregate for dashboards/reporting.
--          One row per (date, region, segment, is_licensed).
--
-- NOTE ON REGION & SEGMENT:
--   region / segment / is_licensed now come from the REAL account dimension
--   (brz_account_dim, sourced from RAW.ACCOUNT_DIM) via a LEFT JOIN.
--   For backward compatibility with environments where the dimension is absent
--   (e.g. V1 / ZOOM_AI_POC, which has no ACCOUNT_DIM), each attribute falls
--   back via COALESCE to the original hash-based placeholder expression.
--   => V2 (dim present)  : real region / segment / is_licensed.
--   => V1 (dim absent)   : identical-to-before hash placeholders.
-- =============================================================================

with consolidated as (

    select * from {{ ref('slv_consolidated_usage') }}

),

monthly as (

    select * from {{ ref('slv_monthly_metrics') }}
    where window = 'R28'

),

-- ── Real account dimension ───────────────────────────────────────────────────
account_dim as (

    select
        account_id,
        region,
        segment,
        is_licensed
    from {{ ref('brz_account_dim') }}

),

-- ── Join usage to the real dimension, with hash-placeholder fallback ─────────
-- COALESCE keeps V1 output identical to the previous hash logic when the
-- dimension produces no matching row (LEFT JOIN -> nulls -> fallback fires).
enriched_usage as (

    select
        c.report_date               as date,
        coalesce(d.region,
            case mod(hash(c.account_id), 4)
                when 0 then 'NAMER'
                when 1 then 'APAC'
                when 2 then 'EMEA'
                else        'LATAM'
            end)                                       as region,
        coalesce(d.segment,
            mod(abs(hash(c.account_id)), 5) + 1)       as segment,
        coalesce(d.is_licensed,
            (mod(hash(c.account_id), 2) = 0))          as is_licensed,
        c.account_id,
        c.active_users,
        c.phone_usage

    from consolidated c
    left join account_dim d
        on c.account_id = d.account_id
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
