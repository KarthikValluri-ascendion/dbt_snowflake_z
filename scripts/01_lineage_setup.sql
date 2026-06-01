-- =============================================================================
-- 01_lineage_setup.sql
-- Run this ONCE in Snowflake to create the lineage schema, tables, and views.
-- After this, every `dbt run` keeps lineage up to date automatically via the
-- on-run-end macro (macros/load_lineage.sql). No external script required.
-- =============================================================================

USE DATABASE ZOOM_AI_POC;
USE ROLE    ZOOM_AI_POC_ROLE;
USE WAREHOUSE WH_ZOOM_AI_POC;

-- ── Schema ────────────────────────────────────────────────────────────────────
CREATE SCHEMA IF NOT EXISTS ZOOM_AI_POC.DBT_LINEAGE
    COMMENT = 'dbt manifest lineage — nodes, edges, and recursive views';

USE SCHEMA ZOOM_AI_POC.DBT_LINEAGE;

-- ── Tables ────────────────────────────────────────────────────────────────────

-- One row per dbt model or source table
CREATE OR REPLACE TABLE NODES (
    NODE_ID         VARCHAR     NOT NULL  COMMENT 'dbt unique_id (e.g. model.dbt_zoom_project.brz_phone_history)',
    NODE_NAME       VARCHAR     NOT NULL  COMMENT 'Short model name (e.g. brz_phone_history)',
    NODE_TYPE       VARCHAR     NOT NULL  COMMENT 'model | source | seed | snapshot',
    LAYER           VARCHAR               COMMENT 'bronze | silver | gold | raw',
    SCHEMA_NAME     VARCHAR               COMMENT 'Snowflake schema the object lands in',
    DATABASE_NAME   VARCHAR               COMMENT 'Snowflake database',
    FILE_PATH       VARCHAR               COMMENT 'Relative path to the .sql file',
    DESCRIPTION     VARCHAR               COMMENT 'Description from yml file',
    RUN_AT          TIMESTAMP_NTZ         COMMENT 'dbt invocation start time (run_started_at)',
    RUN_BY          VARCHAR               COMMENT 'Snowflake user from the dbt profile (target.user) that ran the load',
    LOADED_AT       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    PRIMARY KEY (NODE_ID)
)
COMMENT = 'All dbt nodes (models + sources) parsed from manifest.json';

-- One row per dependency relationship (parent → child)
CREATE OR REPLACE TABLE EDGES (
    PARENT_NODE_ID  VARCHAR NOT NULL  COMMENT 'The upstream dependency',
    CHILD_NODE_ID   VARCHAR NOT NULL  COMMENT 'The model that depends on parent',
    PARENT_NAME     VARCHAR NOT NULL,
    CHILD_NAME      VARCHAR NOT NULL,
    RUN_AT          TIMESTAMP_NTZ     COMMENT 'dbt invocation start time (run_started_at)',
    RUN_BY          VARCHAR           COMMENT 'Snowflake user from the dbt profile (target.user) that ran the load',
    LOADED_AT       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    PRIMARY KEY (PARENT_NODE_ID, CHILD_NODE_ID)
)
COMMENT = 'All dependency edges parsed from manifest.json parent_map';


-- ── Views ─────────────────────────────────────────────────────────────────────

-- VW_UPSTREAM: given any model, find ALL its ancestors recursively
-- Usage: SELECT * FROM VW_UPSTREAM WHERE START_MODEL = 'gld_aggregate' ORDER BY DEPTH;
CREATE OR REPLACE VIEW VW_UPSTREAM AS
WITH RECURSIVE upstream AS (

    -- Base: direct parents of every model
    SELECT
        e.child_node_id                                  AS start_node_id,
        e.child_name                                     AS start_model,
        e.parent_node_id                                 AS ancestor_node_id,
        e.parent_name                                    AS ancestor_name,
        n.node_type                                      AS ancestor_type,
        n.layer                                          AS ancestor_layer,
        n.schema_name                                    AS ancestor_schema,
        n.database_name                                  AS ancestor_database,
        n.run_at                                         AS ancestor_run_at,
        n.run_by                                         AS ancestor_run_by,
        1                                                AS depth,
        e.child_name || ' → ' || e.parent_name          AS lineage_path

    FROM EDGES e
    JOIN NODES n ON n.node_id = e.parent_node_id

    UNION ALL

    -- Recurse: walk further up the DAG
    SELECT
        u.start_node_id,
        u.start_model,
        e.parent_node_id,
        e.parent_name,
        n.node_type,
        n.layer,
        n.schema_name,
        n.database_name,
        n.run_at,
        n.run_by,
        u.depth + 1,
        u.lineage_path || ' → ' || e.parent_name

    FROM upstream u
    JOIN EDGES e  ON e.child_node_id  = u.ancestor_node_id
    JOIN NODES n  ON n.node_id        = e.parent_node_id
    WHERE u.depth < 10  -- safety cap for deep DAGs

)
SELECT * FROM upstream;


-- VW_DOWNSTREAM: given any model/source, find ALL its descendants recursively
-- Usage: SELECT * FROM VW_DOWNSTREAM WHERE START_MODEL = 'phone_history' ORDER BY DEPTH;
CREATE OR REPLACE VIEW VW_DOWNSTREAM AS
WITH RECURSIVE downstream AS (

    -- Base: direct children of every model
    SELECT
        e.parent_node_id                                 AS start_node_id,
        e.parent_name                                    AS start_model,
        e.child_node_id                                  AS descendant_node_id,
        e.child_name                                     AS descendant_name,
        n.node_type                                      AS descendant_type,
        n.layer                                          AS descendant_layer,
        n.schema_name                                    AS descendant_schema,
        n.run_at                                         AS descendant_run_at,
        n.run_by                                         AS descendant_run_by,
        1                                                AS depth,
        e.parent_name || ' → ' || e.child_name          AS lineage_path

    FROM EDGES e
    JOIN NODES n ON n.node_id = e.child_node_id

    UNION ALL

    -- Recurse: walk further down the DAG
    SELECT
        d.start_node_id,
        d.start_model,
        e.child_node_id,
        e.child_name,
        n.node_type,
        n.layer,
        n.schema_name,
        n.run_at,
        n.run_by,
        d.depth + 1,
        d.lineage_path || ' → ' || e.child_name

    FROM downstream d
    JOIN EDGES e  ON e.parent_node_id = d.descendant_node_id
    JOIN NODES n  ON n.node_id        = e.child_node_id
    WHERE d.depth < 10

)
SELECT * FROM downstream;


-- VW_LINEAGE_SUMMARY: flat, human-readable view of every direct edge
-- Great for a quick overview of the full DAG in one query
CREATE OR REPLACE VIEW VW_LINEAGE_SUMMARY AS
SELECT
    p.layer         AS from_layer,
    p.node_name     AS from_model,
    p.node_type     AS from_type,
    p.schema_name   AS from_schema,
    '→'             AS direction,
    c.layer         AS to_layer,
    c.node_name     AS to_model,
    c.node_type     AS to_type,
    c.schema_name   AS to_schema,
    c.run_at        AS to_run_at,
    c.run_by        AS to_run_by
FROM EDGES e
JOIN NODES p ON p.node_id = e.parent_node_id
JOIN NODES c ON c.node_id = e.child_node_id
ORDER BY
    CASE p.layer WHEN 'raw' THEN 1 WHEN 'bronze' THEN 2 WHEN 'silver' THEN 3 WHEN 'gold' THEN 4 ELSE 5 END,
    p.node_name;
