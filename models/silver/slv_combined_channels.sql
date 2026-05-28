-- =============================================================================
-- MODEL: slv_combined_channels  (Silver layer, materialized as TABLE)
-- SOURCE: All 5 bronze views  →  brz_phone/sms/chat/email/video_history
-- PURPOSE: Union all channel interactions into one unified table.
--          Renames agent_hash_id → user_id, final_outcome → engagement_status,
--          and derives modality from the source table name.
-- =============================================================================

with phone as (

    select
        start_date,
        agent_hash_id   as user_id,
        engagement_id,
        account_id,
        channel,
        duration_sec,
        direction,
        'Phone'         as modality,
        final_outcome   as engagement_status,
        sla_achieved,
        source_table
    from {{ ref('brz_phone_history') }}

),

sms as (

    select
        start_date,
        agent_hash_id   as user_id,
        engagement_id,
        account_id,
        channel,
        duration_sec,
        direction,
        'SMS'           as modality,
        final_outcome   as engagement_status,
        sla_achieved,
        source_table
    from {{ ref('brz_sms_history') }}

),

chat as (

    select
        start_date,
        agent_hash_id   as user_id,
        engagement_id,
        account_id,
        channel,
        duration_sec,
        direction,
        'Chat'          as modality,
        final_outcome   as engagement_status,
        sla_achieved,
        source_table
    from {{ ref('brz_chat_history') }}

),

email as (

    select
        start_date,
        agent_hash_id   as user_id,
        engagement_id,
        account_id,
        channel,
        duration_sec,
        direction,
        'Email'         as modality,
        final_outcome   as engagement_status,
        sla_achieved,
        source_table
    from {{ ref('brz_email_history') }}

),

video as (

    select
        start_date,
        agent_hash_id   as user_id,
        engagement_id,
        account_id,
        channel,
        duration_sec,
        direction,
        'Video'         as modality,
        final_outcome   as engagement_status,
        sla_achieved,
        source_table
    from {{ ref('brz_video_history') }}

),

combined as (

    select * from phone
    union all
    select * from sms
    union all
    select * from chat
    union all
    select * from email
    union all
    select * from video

)

select * from combined
