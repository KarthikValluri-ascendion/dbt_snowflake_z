-- =============================================================================
-- 02_column_lineage_setup.sql  --  Run ONCE in Snowflake after 01_lineage_setup.sql
--   (re-run it whenever you change the procedure or the view)
--
-- Column-level lineage is parsed by a Python stored procedure that uses
-- sqlglot's lineage engine. It needs two things, both now provided automatically
-- on every `dbt run`:
--   1. COMPILED model SQL  -> loaded into MODEL_SQL by the on-run-end macro
--                             (macros/load_lineage.sql), read from dbt `results`.
--   2. A column SCHEMA     -> read LIVE from INFORMATION_SCHEMA.COLUMNS inside the
--                             procedure, so SELECT * / unqualified columns resolve.
-- No catalog.json / `dbt docs generate` / wrapper script required.
-- =============================================================================

USE DATABASE ZOOM_AI_POC;
USE ROLE    ZOOM_AI_POC_ROLE;
USE WAREHOUSE WH_ZOOM_AI_POC;
USE SCHEMA  DBT_LINEAGE;

CREATE OR REPLACE TABLE MODEL_SQL (
    MODEL_NAME  VARCHAR NOT NULL,
    LAYER       VARCHAR,
    RAW_SQL     VARCHAR,           -- holds COMPILED SQL (name kept for compatibility)
    FILE_PATH   VARCHAR,
    RUN_AT      TIMESTAMP_NTZ,     -- dbt invocation start time (run_started_at)
    RUN_BY      VARCHAR,           -- Snowflake user from the dbt profile (target.user)
    LOADED_AT   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE COLUMN_LINEAGE (
    MODEL_NAME     VARCHAR,
    LAYER          VARCHAR,
    OUTPUT_COLUMN  VARCHAR,
    EXPRESSION     VARCHAR,
    SOURCE_MODEL   VARCHAR,
    SOURCE_COLUMN  VARCHAR,
    FILE_PATH      VARCHAR,
    RUN_AT         TIMESTAMP_NTZ,     -- dbt invocation start time (run_started_at)
    RUN_BY         VARCHAR,           -- Snowflake user from the dbt profile (target.user)
    LOADED_AT      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE PROCEDURE LOAD_COLUMN_LINEAGE()
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('sqlglot', 'snowflake-snowpark-python')
HANDLER = 'main'
EXECUTE AS OWNER
AS $$
import sqlglot


def main(session):
    # Lazy import so the procedure always CREATES even if this sqlglot build
    # lacks the lineage module — we then report it instead of failing silently.
    ver = getattr(sqlglot, "__version__", "unknown")
    try:
        from sqlglot import exp
        from sqlglot.lineage import lineage
    except Exception as e:
        return f"IMPORT_ERROR sqlglot={ver}: {str(e)[:300]}"

    # ── node-name (UPPER) -> original-case name, for clean output labels ──────
    name_map = {}
    for n in session.sql(
        "SELECT NODE_NAME FROM ZOOM_AI_POC.DBT_LINEAGE.NODES"
    ).collect():
        name_map[n["NODE_NAME"].upper()] = n["NODE_NAME"]
    known = set(name_map.keys())

    # ── live column schema  {DB: {SCHEMA: {TABLE: {COL: TYPE}}}}  ─────────────
    #    plus each relation's own output columns (owncols), straight from the
    #    objects dbt just built. This is what lets sqlglot expand SELECT *.
    schema, owncols = {}, {}
    for r in session.sql(
        """
        SELECT TABLE_CATALOG, TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, DATA_TYPE,
               ORDINAL_POSITION
        FROM   ZOOM_AI_POC.INFORMATION_SCHEMA.COLUMNS
        WHERE  TABLE_SCHEMA <> 'DBT_LINEAGE'
        ORDER  BY TABLE_SCHEMA, TABLE_NAME, ORDINAL_POSITION
        """
    ).collect():
        db = (r["TABLE_CATALOG"] or "").upper()
        sc = (r["TABLE_SCHEMA"] or "").upper()
        t  = (r["TABLE_NAME"]   or "").upper()
        c  = (r["COLUMN_NAME"]  or "").upper()
        schema.setdefault(db, {}).setdefault(sc, {}).setdefault(t, {})[c] = r["DATA_TYPE"] or "VARCHAR"
        owncols.setdefault(t, []).append(c)

    # ── most meaningful transformation expression for an output column ────────
    #    The dbt idiom `select * from final_cte` makes the OUTERMOST projection a
    #    bare column passthrough, so root.expression hides the real calc (COUNT,
    #    CASE, arithmetic, …) that lives one node deeper. Walk the lineage tree
    #    breadth-first from the output and return the first projection that is an
    #    actual transformation rather than a plain column / star. Fall back to the
    #    closest column reference when the lineage is a genuine 1:1 passthrough.
    from collections import deque

    # Nodes that are NOT a real transformation: bare columns, stars, and the
    # FROM-clause relation/subquery references that `select * from cte` produces.
    # Treating these as trivial keeps the walk going to the true calc (or, for a
    # genuine passthrough, falls back to the closest column instead of a table name).
    TRIVIAL = (exp.Column, exp.Star, exp.Table, exp.Select, exp.Subquery)

    def _sql(node):
        # comments=False strips inline SQL comments that would otherwise leak
        # into the expression text (e.g. the SEGMENT bucket comment).
        return node.sql(dialect="snowflake", comments=False)

    def best_expression(root_node, default):
        dq, seen_e, fallback = deque([root_node]), set(), None
        while dq:
            nd = dq.popleft()
            if id(nd) in seen_e:
                continue
            seen_e.add(id(nd))
            e = nd.expression
            if e is not None:
                inner = e.this if isinstance(e, exp.Alias) else e
                if isinstance(inner, TRIVIAL):
                    if fallback is None and isinstance(inner, (exp.Column, exp.Star)):
                        fallback = _sql(inner)
                else:
                    return _sql(inner)
            for d in nd.downstream:
                dq.append(d)
        return fallback if fallback is not None else default

    # ── parse each model's compiled SQL, one row per (column, source column) ──
    rows = []
    models = session.sql(
        """
        SELECT MODEL_NAME, LAYER, RAW_SQL, FILE_PATH, RUN_AT, RUN_BY
        FROM   ZOOM_AI_POC.DBT_LINEAGE.MODEL_SQL
        WHERE  RAW_SQL IS NOT NULL AND LENGTH(TRIM(RAW_SQL)) > 0
        """
    ).collect()

    for m in models:
        name   = m["MODEL_NAME"]
        layer  = m["LAYER"]
        sql    = m["RAW_SQL"]
        fp     = m["FILE_PATH"] or ""
        run_at = m["RUN_AT"]   # carried through from MODEL_SQL so each column row
        run_by = m["RUN_BY"]   # records when / by whom that model was last built

        for col in owncols.get(name.upper(), []):
            try:
                root = lineage(col, sql, schema=schema, dialect="snowflake")
                expr = best_expression(root, col)

                leaves, stack, seen = set(), [root], set()
                while stack:
                    nd = stack.pop()
                    if id(nd) in seen:
                        continue
                    seen.add(id(nd))
                    if not nd.downstream:
                        # table: prefer the resolved Table source; else the
                        # second-to-last dotted part of the qualified name
                        tname = None
                        if isinstance(nd.source, exp.Table):
                            tname = nd.source.name
                        parts = str(nd.name).split(".")
                        if tname is None and len(parts) >= 2:
                            tname = parts[-2]
                        scol = parts[-1]
                        if tname and tname.upper() in known:
                            leaves.add((tname.upper(), scol.upper()))
                    else:
                        stack.extend(nd.downstream)

                if not leaves:
                    # literal / constant -> no upstream column
                    rows.append([name, layer, col, expr, None, None, fp, run_at, run_by])
                for st, scol in sorted(leaves):
                    rows.append([name, layer, col, expr,
                                 name_map.get(st, st), scol, fp, run_at, run_by])
            except Exception as e:
                rows.append([name, layer, col,
                             "LINEAGE_ERROR: " + str(e)[:300], None, None, fp, run_at, run_by])

    session.sql("TRUNCATE TABLE ZOOM_AI_POC.DBT_LINEAGE.COLUMN_LINEAGE").collect()
    if rows:
        session.create_dataframe(
            rows,
            schema=["MODEL_NAME", "LAYER", "OUTPUT_COLUMN", "EXPRESSION",
                    "SOURCE_MODEL", "SOURCE_COLUMN", "FILE_PATH", "RUN_AT", "RUN_BY"],
        ).write.mode("append").save_as_table(
            "ZOOM_AI_POC.DBT_LINEAGE.COLUMN_LINEAGE", column_order="name"
        )

    # ── diagnostics in the return value ───────────────────────────────────────
    schema_tables = sum(len(tbls) for db in schema.values() for tbls in db.values())
    n_resolved = sum(1 for r in rows if r[4] and r[5] != "*")
    n_star     = sum(1 for r in rows if r[5] == "*")
    n_null     = sum(1 for r in rows if r[4] is None)
    return (f"NEWPROC sqlglot={ver}; schema_tables={schema_tables}; "
            f"models={len(models)}; rows={len(rows)}; "
            f"resolved={n_resolved}; star_unexpanded={n_star}; no_source={n_null}")
$$;

-- =============================================================================
-- VW_COLUMN_LINEAGE — the gold -> silver -> bronze -> raw column pivot.
--   This is the table you asked for:
--   Gold Table | Gold Column | Silver Table | Silver Column | Expression | dbt file
-- Now that SOURCE_MODEL / SOURCE_COLUMN are accurate (renames, derivations and
-- multi-source columns all resolved), the layered joins populate correctly.
-- =============================================================================
--   It walks DOWN the column graph (any number of silver hops) and captures the
--   first silver model, the bronze model, and the raw source it reaches.
CREATE OR REPLACE VIEW VW_COLUMN_LINEAGE AS
WITH RECURSIVE walk AS (

    -- anchor: one row per gold column, positioned to step into its source
    SELECT
        g.model_name    AS gold_table,
        g.output_column AS gold_column,
        g.expression    AS gold_expression,
        g.file_path     AS gold_dbt_file,
        g.run_at        AS gold_run_at,
        g.run_by        AS gold_run_by,
        g.source_model  AS src_model,
        g.source_column AS src_column,
        CAST(NULL AS VARCHAR) AS silver_table,
        CAST(NULL AS VARCHAR) AS silver_column,
        CAST(NULL AS VARCHAR) AS silver_expression,
        CAST(NULL AS VARCHAR) AS silver_dbt_file,
        CAST(NULL AS VARCHAR) AS bronze_table,
        CAST(NULL AS VARCHAR) AS bronze_column,
        CAST(NULL AS VARCHAR) AS bronze_expression,
        CAST(NULL AS VARCHAR) AS bronze_dbt_file,
        CAST(NULL AS VARCHAR) AS raw_table,
        CAST(NULL AS VARCHAR) AS raw_column,
        1 AS depth
    FROM COLUMN_LINEAGE g
    WHERE g.layer = 'gold'
      AND g.output_column NOT IN ('*', 'PARSE_ERROR')

    UNION ALL

    -- step to the current node's source, capturing layers as we pass them
    SELECT
        w.gold_table, w.gold_column, w.gold_expression, w.gold_dbt_file,
        w.gold_run_at, w.gold_run_by,
        c.source_model, c.source_column,
        COALESCE(w.silver_table,      CASE WHEN c.layer = 'silver' THEN c.model_name    END),
        COALESCE(w.silver_column,     CASE WHEN c.layer = 'silver' THEN c.output_column END),
        COALESCE(w.silver_expression, CASE WHEN c.layer = 'silver' THEN c.expression    END),
        COALESCE(w.silver_dbt_file,   CASE WHEN c.layer = 'silver' THEN c.file_path     END),
        COALESCE(w.bronze_table,      CASE WHEN c.layer = 'bronze' THEN c.model_name    END),
        COALESCE(w.bronze_column,     CASE WHEN c.layer = 'bronze' THEN c.output_column END),
        COALESCE(w.bronze_expression, CASE WHEN c.layer = 'bronze' THEN c.expression    END),
        COALESCE(w.bronze_dbt_file,   CASE WHEN c.layer = 'bronze' THEN c.file_path     END),
        COALESCE(w.raw_table,         CASE WHEN c.layer = 'bronze' THEN c.source_model  END),
        COALESCE(w.raw_column,        CASE WHEN c.layer = 'bronze' THEN c.source_column END),
        w.depth + 1
    FROM walk w
    JOIN COLUMN_LINEAGE c
      ON c.model_name    = w.src_model
     AND c.output_column = w.src_column
    WHERE w.src_model IS NOT NULL
      AND w.depth < 10
)
-- keep only terminal rows (their source has no further column row = raw / literal)
SELECT
    gold_table, gold_column, gold_expression, gold_dbt_file,
    gold_run_at, gold_run_by,
    silver_table, silver_column, silver_expression, silver_dbt_file,
    bronze_table, bronze_column, bronze_expression, bronze_dbt_file,
    raw_table, raw_column
FROM walk w
WHERE NOT EXISTS (
    SELECT 1 FROM COLUMN_LINEAGE c2
    WHERE c2.model_name    = w.src_model
      AND c2.output_column = w.src_column
)
ORDER BY gold_table, gold_column, silver_table, bronze_table;

-- =============================================================================
-- VW_COLUMN_LINEAGE_PATH — generic recursive walk for ANY depth (not just 4
-- fixed layers). Start at any column and follow it down to its raw source(s).
--   SELECT * FROM VW_COLUMN_LINEAGE_PATH
--   WHERE start_model = 'gld_aggregate' AND start_column = 'PHONE_USAGE'
--   ORDER BY depth;
-- =============================================================================
CREATE OR REPLACE VIEW VW_COLUMN_LINEAGE_PATH AS
WITH RECURSIVE walk AS (

    SELECT
        model_name      AS start_model,
        output_column   AS start_column,
        model_name,
        output_column,
        expression,
        source_model,
        source_column,
        layer,
        file_path,
        run_at,
        run_by,
        1               AS depth,
        model_name || '.' || output_column AS path
    FROM COLUMN_LINEAGE
    WHERE layer = 'gold'
      AND output_column NOT IN ('*', 'PARSE_ERROR')

    UNION ALL

    SELECT
        w.start_model,
        w.start_column,
        c.model_name,
        c.output_column,
        c.expression,
        c.source_model,
        c.source_column,
        c.layer,
        c.file_path,
        c.run_at,
        c.run_by,
        w.depth + 1,
        w.path || ' -> ' || c.model_name || '.' || c.output_column
    FROM walk w
    JOIN COLUMN_LINEAGE c
      ON c.model_name = w.source_model
     AND c.output_column = w.source_column
    WHERE w.source_model IS NOT NULL
      AND w.depth < 10

)
SELECT * FROM walk;
