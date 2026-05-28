-- =============================================================================
-- MODEL: slv_user_first_active  (Silver layer, materialized as TABLE)
-- SOURCE: slv_combined_channels
-- PURPOSE: Derive each user's very first active date within their account.
--          Used to enrich slv_usage_master.
-- =============================================================================

with combined as (

    select * from {{ ref('slv_combined_channels') }}

),

first_active as (

    select
        user_id,
        account_id,
        min(start_date)               as user_first_active,
        current_timestamp()           as refresh_timestamp
    from combined
    group by user_id, account_id

)

select * from first_active
