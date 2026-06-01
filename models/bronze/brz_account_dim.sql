-- =============================================================================
-- MODEL: brz_account_dim  (Bronze layer, materialized as VIEW)
-- SOURCE TABLE: <target_db>.RAW.ACCOUNT_DIM
-- PURPOSE: Lightly clean the raw account dimension – enforce types, normalise
--          region casing, add a source tag.  One row per account_id.
--
-- BACKWARD COMPATIBILITY:
--   The ACCOUNT_DIM raw table only exists in enriched environments (V2).
--   In V1 (ZOOM_AI_POC) it is absent, so we must not hard-reference a missing
--   object or the V1 build breaks. We probe for the relation at parse/compile
--   time: when present we read it; when absent we emit a correctly-typed EMPTY
--   result. Downstream gld_aggregate LEFT JOINs this view and COALESCEs to its
--   hash placeholders, so an empty dim yields identical-to-before V1 output.
-- =============================================================================

{% set dim_source = source('ZOOM_AI_POC', 'account_dim') %}
{% set dim_relation = adapter.get_relation(
        database=dim_source.database,
        schema=dim_source.schema,
        identifier=dim_source.identifier) %}

{% if dim_relation is not none %}

with source as (

    select * from {{ dim_source }}

),

renamed as (

    select
        account_id                        as account_id,
        account_name                      as account_name,
        upper(trim(region))               as region,
        cast(segment as integer)          as segment,
        cast(is_licensed as boolean)      as is_licensed,
        'ACCOUNT_DIM'                     as source_table

    from source

)

select * from renamed

{% else %}

-- ACCOUNT_DIM not present in this environment (e.g. V1). Emit an empty,
-- correctly-typed shell so refs and the gold LEFT JOIN still compile.
select
    cast(null as varchar)   as account_id,
    cast(null as varchar)   as account_name,
    cast(null as varchar)   as region,
    cast(null as integer)   as segment,
    cast(null as boolean)   as is_licensed,
    cast(null as varchar)   as source_table
where false

{% endif %}
