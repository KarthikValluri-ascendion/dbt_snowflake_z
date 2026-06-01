# Run Manifest — Demo_Trail_1

**Skill:** gold-parallel-pipeline (Grandfather orchestration)
**Created:** 2026-06-01

## Inputs

| Input | Value |
|-------|-------|
| Jira ticket | `Demo_Trail_1` |
| Existing gold table | `gld_aggregate` (`models/gold/gld_aggregate.sql`) |
| New pre-computed raw table | `RAW.PRECOMPUTED_ACCOUNT_DAILY_USAGE` |
| Raw table source resolution | source `ZOOM_AI_POC`, schema `RAW`, database via `{{ env_var('SNOWFLAKE_DATABASE','ZOOM_AI_POC') }}` (currently `ZOOM_AI_POC_V2` per `.dbt-env`) |
| Parallel suffix | `_p` → new gold `gld_aggregate_p`, recon `gld_aggregate_recon_p` |

## Resolved environment

| Key | Value |
|-----|-------|
| `$DBT_ROOT` | `/Users/rohanmodi/01_Work/Code/Github/dbt_snowflake_z` |
| dbt interpreter | `$DBT_ROOT/.venv/bin/dbt` (present) |
| Snowflake creds | Set in `.dbt-env` (key-pair auth) — warehouse profiling/build available when sourced |
| Graphviz `dot` | **Not installed** → static PNG/SVG skipped; Mermaid (`.md`/`.mmd`) + `.dot` source produced. Zero-install image route: paste `.mmd` into https://mermaid.live |

## Decisions

- Parallel = **additive**. Do not edit `gld_aggregate.sql` or any silver feeder.
- One Father track (stages are sequential). No Uncle (no independent second effort requested).
- Gated stages: after each, summarize and pause for go/no-go.
