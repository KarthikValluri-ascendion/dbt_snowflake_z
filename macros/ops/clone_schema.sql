{#
  Zero-copy clone a whole schema (instant, storage-free) for backups before a rebuild.
  Usage:
    dbt run-operation clone_schema --args '{src: ZOOM_AI_POC.SILVER, dest: ZOOM_AI_POC.SILVER_BAK_20260601}'
#}
{% macro clone_schema(src, dest) %}
    {% do run_query("create schema if not exists " ~ dest ~ " clone " ~ src) %}
    {% do log("✅ cloned " ~ src ~ " -> " ~ dest, info=true) %}
{% endmacro %}
