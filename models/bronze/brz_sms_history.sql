-- =============================================================================
-- MODEL: brz_sms_history  (Bronze layer, materialized as VIEW)
-- SOURCE TABLE: ZCC_DB.RAW.SMS_HISTORY
-- =============================================================================

with source as (

    select * from {{ source('ZOOM_AI_POC', 'sms_history') }}

),

renamed as (

    select
        record_id,
        account_id,
        agent_hash_id,
        engagement_id,
        upper(trim(channel))              as channel,
        cast(start_time as timestamp_ntz) as start_time,
        cast(start_time as date)          as start_date,
        cast(duration_sec as float)       as duration_sec,
        round(duration_sec / 60.0, 2)     as duration_min,
        upper(trim(direction))            as direction,
        initcap(trim(final_outcome))      as final_outcome,
        cast(sla_achieved as boolean)     as sla_achieved,
        'SMS_HISTORY'                     as source_table

    from source

)

select * from renamed
