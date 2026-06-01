{% macro load_lineage_to_snowflake() %}

  {% if execute %}

    {%- set ns = namespace(node_rows=[], edge_rows=[]) -%}

    {# Run metadata stamped on every row: a single consistent invocation time for
       the whole run, and the Snowflake user from the dbt profile. #}
    {%- set run_at = run_started_at.strftime("%Y-%m-%d %H:%M:%S") -%}
    {%- set run_by = (target.user or "") | replace("'", "''") -%}

    {%- for node_id, node in graph["nodes"].items() -%}
      {%- if node["resource_type"] in ("model", "seed", "snapshot") -%}

        {%- set fqn      = node["fqn"] -%}
        {%- set layer    = fqn[1] if fqn | length > 1 else "unknown" -%}
        {%- set desc     = (node.get("description") or "") | replace("'", "''") | truncate(2000, False, "") -%}
        {%- set filepath = (node.get("original_file_path") or "") | replace("\\", "/") | replace("'", "''") -%}
        {%- set schema   = (node.get("schema")   or "") | replace("'", "''") -%}
        {%- set database = (node.get("database") or "") | replace("'", "''") -%}

        {%- do ns.node_rows.append(
              "('" ~ node_id               ~ "','"
                   ~ node["name"]          ~ "','"
                   ~ node["resource_type"] ~ "','"
                   ~ layer                 ~ "','"
                   ~ schema                ~ "','"
                   ~ database              ~ "','"
                   ~ filepath              ~ "','"
                   ~ desc                  ~ "','"
                   ~ run_at                ~ "','"
                   ~ run_by                ~ "')"
        ) -%}

        {%- for parent_id in node["depends_on"]["nodes"] -%}
          {%- if not parent_id.startswith("test.") -%}
            {%- set parent = graph["nodes"].get(parent_id) or graph["sources"].get(parent_id) -%}
            {%- if parent -%}
              {%- set pname = parent["name"] | replace("'", "''") -%}
              {%- set cname = node["name"]   | replace("'", "''") -%}
              {%- do ns.edge_rows.append(
                    "('" ~ parent_id ~ "','"
                         ~ node_id   ~ "','"
                         ~ pname     ~ "','"
                         ~ cname     ~ "','"
                         ~ run_at    ~ "','"
                         ~ run_by    ~ "')"
              ) -%}
            {%- endif -%}
          {%- endif -%}
        {%- endfor -%}

      {%- endif -%}
    {%- endfor -%}

    {%- for node_id, node in graph["sources"].items() -%}
      {%- set desc     = (node.get("description") or "") | replace("'", "''") | truncate(2000, False, "") -%}
      {%- set schema   = (node.get("schema")      or "") | replace("'", "''") -%}
      {%- set database = (node.get("database")    or "") | replace("'", "''") -%}

      {%- do ns.node_rows.append(
            "('" ~ node_id       ~ "','"
                 ~ node["name"]  ~ "','source','raw','"
                 ~ schema        ~ "','"
                 ~ database      ~ "','','"
                 ~ desc          ~ "','"
                 ~ run_at        ~ "','"
                 ~ run_by        ~ "')"
      ) -%}
    {%- endfor -%}

    {% do run_query("TRUNCATE TABLE ZOOM_AI_POC.DBT_LINEAGE.NODES") %}
    {% do run_query("TRUNCATE TABLE ZOOM_AI_POC.DBT_LINEAGE.EDGES") %}

    {%- if ns.node_rows | length > 0 -%}
      {%- set node_sql -%}
        INSERT INTO ZOOM_AI_POC.DBT_LINEAGE.NODES
          (NODE_ID, NODE_NAME, NODE_TYPE, LAYER, SCHEMA_NAME, DATABASE_NAME, FILE_PATH, DESCRIPTION, RUN_AT, RUN_BY)
        VALUES {{ ns.node_rows | join(", ") }}
      {%- endset -%}
      {% do run_query(node_sql) %}
    {%- endif -%}

    {%- if ns.edge_rows | length > 0 -%}
      {%- set edge_sql -%}
        INSERT INTO ZOOM_AI_POC.DBT_LINEAGE.EDGES
          (PARENT_NODE_ID, CHILD_NODE_ID, PARENT_NAME, CHILD_NAME, RUN_AT, RUN_BY)
        VALUES {{ ns.edge_rows | join(", ") }}
      {%- endset -%}
      {% do run_query(edge_sql) %}
    {%- endif -%}

    {{ log(
        "Lineage refreshed - nodes: " ~ ns.node_rows | length
        ~ ", edges: " ~ ns.edge_rows | length,
        info=True
    ) }}

    {# ── Load COMPILED SQL for column lineage ──────────────────────────────────
       NOTE: we read from `results` (the executed nodes), NOT from `graph`.
       The `graph` Jinja variable only carries raw (un-compiled) Jinja code in
       on-run-end, which sqlglot cannot parse. `results[i].node.compiled_code`
       is the fully-resolved SQL with real table names. #}
    {# Upsert (not truncate) so a selective `dbt run --select x` refreshes only the
       models in THIS run and leaves every other model's SQL intact — keeping the
       column lineage complete after partial runs. We delete just the models being
       (re)built, then re-insert them with fresh SQL + run metadata. #}
    {%- set ns2 = namespace(model_count=0, del_names=[]) -%}
    {%- if results is defined and results -%}

      {%- for res in results -%}
        {%- if res.node.resource_type == "model" -%}
          {%- set compiled = res.node.compiled_code or res.node.compiled_sql or "" -%}
          {%- if compiled | trim | length > 0 -%}
            {%- do ns2.del_names.append("'" ~ res.node.name ~ "'") -%}
          {%- endif -%}
        {%- endif -%}
      {%- endfor -%}

      {%- if ns2.del_names | length > 0 -%}
        {% do adapter.execute(
            "DELETE FROM ZOOM_AI_POC.DBT_LINEAGE.MODEL_SQL WHERE MODEL_NAME IN ("
            ~ ns2.del_names | join(", ") ~ ")",
            auto_begin=False, fetch=False) %}
      {%- endif -%}

      {%- for res in results -%}
        {%- set node = res.node -%}
        {%- if node.resource_type == "model" -%}
          {%- set fqn      = node.fqn -%}
          {%- set layer    = fqn[1] if fqn | length > 1 else "unknown" -%}
          {%- set compiled = node.compiled_code or node.compiled_sql or "" -%}
          {%- set sql_text = compiled | replace("\\", "\\\\") | replace("'", "''") -%}
          {%- set filepath = (node.original_file_path or "") | replace("\\", "/") | replace("'", "''") -%}
          {%- if sql_text | trim | length > 0 -%}
            {%- set insert_sql -%}
INSERT INTO ZOOM_AI_POC.DBT_LINEAGE.MODEL_SQL (MODEL_NAME, LAYER, RAW_SQL, FILE_PATH, RUN_AT, RUN_BY)
VALUES ('{{ node.name }}', '{{ layer }}', '{{ sql_text }}', '{{ filepath }}', '{{ run_at }}', '{{ run_by }}')
            {%- endset -%}
            {% do adapter.execute(insert_sql, auto_begin=False, fetch=False) %}
            {%- set ns2.model_count = ns2.model_count + 1 -%}
          {%- endif -%}
        {%- endif -%}
      {%- endfor -%}
    {%- endif -%}

    {{ log("Compiled SQL loaded for " ~ ns2.model_count ~ " models.", info=True) }}

    {# ── Parse column lineage via Snowflake stored procedure ──────────────── #}
    {% do adapter.execute("CALL ZOOM_AI_POC.DBT_LINEAGE.LOAD_COLUMN_LINEAGE()", auto_begin=False, fetch=False) %}

    {{ log("Column lineage refreshed.", info=True) }}

  {% endif %}

{% endmacro %}
