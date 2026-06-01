-- =============================================================================
-- OPERATION MACRO: build_precomputed_account_daily_usage
-- Builds the SIMULATED pre-computed landed table
--   <db>.RAW.PRECOMPUTED_ACCOUNT_DAILY_USAGE
-- at grain (report_date, account_id) for the R28 window, by selecting from the
-- already-built SILVER layer joined to the real RAW.ACCOUNT_DIM.
--
-- This is a STANDALONE landed table (not a dbt model) for a later
-- "parallel gold" exercise. Run after silver/gold are built:
--   dbt run-operation build_precomputed_account_daily_usage
-- It honours the target database from the active connection (env-driven), so
-- run it with the V2 env overrides exported.
-- =============================================================================
{% macro build_precomputed_account_daily_usage() %}

    {% set db = target.database %}
    {% set tbl = db ~ '.RAW.PRECOMPUTED_ACCOUNT_DAILY_USAGE' %}

    {% set sql %}
        create or replace table {{ tbl }} as
        with consolidated as (
            select report_date, account_id, active_users, phone_usage
            from {{ db }}.SILVER.SLV_CONSOLIDATED_USAGE
            where window = 'R28'
        ),
        monthly as (
            select report_date, account_id, users_active_16plus_days
            from {{ db }}.SILVER.SLV_MONTHLY_METRICS
            where window = 'R28'
        ),
        dim as (
            select account_id, region, segment, is_licensed
            from {{ db }}.BRONZE.BRZ_ACCOUNT_DIM
        )
        select
            c.report_date                              as report_date,
            c.account_id                               as account_id,
            c.active_users                             as active_users,
            round(c.phone_usage, 2)                    as phone_usage_min,
            coalesce(m.users_active_16plus_days, 0)    as users_active_16plus_days,
            d.region                                   as region,
            d.segment                                  as segment,
            d.is_licensed                              as is_licensed,
            current_timestamp()                        as _loaded_at
        from consolidated c
        left join monthly m
            on  c.account_id  = m.account_id
            and c.report_date = m.report_date
        left join dim d
            on c.account_id = d.account_id
    {% endset %}

    {% do run_query(sql) %}
    {{ log("Built " ~ tbl, info=True) }}

{% endmacro %}
