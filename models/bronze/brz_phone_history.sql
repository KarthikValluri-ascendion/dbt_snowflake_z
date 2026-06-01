-- =============================================================================
-- MODEL: brz_phone_history  (Bronze layer, materialized as VIEW)
-- SOURCE TABLE: ZOOM_AI_POC.RAW.PHONE_HISTORY
-- PURPOSE: Lightly clean the raw phone table – enforce types, rename columns
--          to snake_case, add a source tag.  No business logic here.
-- =============================================================================

with source as (

    select * from {{ source('ZOOM_AI_POC', 'phone_history') }}

),

renamed as (

    select
        record_id                              as record_id,
        account_id                             as account_id,
        agent_hash_id                          as agent_hash_id,
        engagement_id                          as engagement_id,
        upper(trim(channel))                   as channel,
        cast(start_time as timestamp_ntz)      as start_time,
        cast(start_time as date)               as start_date,
        cast(duration_sec as float)            as duration_sec,
        round(duration_sec / 60.0, 2)          as duration_min,
        upper(trim(direction))                 as direction,
        initcap(trim(final_outcome))           as final_outcome,
        cast(sla_achieved as boolean)          as sla_achieved,
        'PHONE_HISTORY'                        as source_table

    from source

)

select * from renamed
