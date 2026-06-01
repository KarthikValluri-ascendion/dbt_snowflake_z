# gld_aggregate — upstream lineage (gold → source)

## Upstream lineage (by layer)

**SOURCE** (6)
- `ZOOM_AI_POC.account_dim`
- `ZOOM_AI_POC.chat_history`
- `ZOOM_AI_POC.email_history`
- `ZOOM_AI_POC.phone_history`
- `ZOOM_AI_POC.sms_history`
- `ZOOM_AI_POC.video_history`

**BRONZE** (6)
- `brz_account_dim`
- `brz_chat_history`
- `brz_email_history`
- `brz_phone_history`
- `brz_sms_history`
- `brz_video_history`

**SILVER** (4)
- `slv_combined_channels`
- `slv_consolidated_usage`
- `slv_monthly_metrics`
- `slv_user_active_days`

**GOLD** (1)
- `gld_aggregate`  ← TARGET

## Model-level flow

```mermaid
flowchart LR
  classDef source fill:#d9d9d9,stroke:#333,color:#000;
  classDef bronze fill:#cd7f32,stroke:#333,color:#000;
  classDef silver fill:#c0c0c0,stroke:#333,color:#000;
  classDef gold fill:#ffd700,stroke:#333,color:#000;
  classDef other fill:#ffffff,stroke:#333,color:#000;
  subgraph SOURCE
    direction TB
    source_dbt_zoom_project_ZOOM_AI_POC_account_dim["ZOOM_AI_POC.account_dim"]:::source
    source_dbt_zoom_project_ZOOM_AI_POC_chat_history["ZOOM_AI_POC.chat_history"]:::source
    source_dbt_zoom_project_ZOOM_AI_POC_email_history["ZOOM_AI_POC.email_history"]:::source
    source_dbt_zoom_project_ZOOM_AI_POC_phone_history["ZOOM_AI_POC.phone_history"]:::source
    source_dbt_zoom_project_ZOOM_AI_POC_sms_history["ZOOM_AI_POC.sms_history"]:::source
    source_dbt_zoom_project_ZOOM_AI_POC_video_history["ZOOM_AI_POC.video_history"]:::source
  end
  subgraph BRONZE
    direction TB
    model_dbt_zoom_project_brz_account_dim["brz_account_dim"]:::bronze
    model_dbt_zoom_project_brz_chat_history["brz_chat_history"]:::bronze
    model_dbt_zoom_project_brz_email_history["brz_email_history"]:::bronze
    model_dbt_zoom_project_brz_phone_history["brz_phone_history"]:::bronze
    model_dbt_zoom_project_brz_sms_history["brz_sms_history"]:::bronze
    model_dbt_zoom_project_brz_video_history["brz_video_history"]:::bronze
  end
  subgraph SILVER
    direction TB
    model_dbt_zoom_project_slv_combined_channels["slv_combined_channels"]:::silver
    model_dbt_zoom_project_slv_consolidated_usage["slv_consolidated_usage"]:::silver
    model_dbt_zoom_project_slv_monthly_metrics["slv_monthly_metrics"]:::silver
    model_dbt_zoom_project_slv_user_active_days["slv_user_active_days"]:::silver
  end
  subgraph GOLD
    direction TB
    model_dbt_zoom_project_gld_aggregate["gld_aggregate"]:::gold
  end
  model_dbt_zoom_project_brz_account_dim --> model_dbt_zoom_project_gld_aggregate
  model_dbt_zoom_project_brz_chat_history --> model_dbt_zoom_project_slv_combined_channels
  model_dbt_zoom_project_brz_email_history --> model_dbt_zoom_project_slv_combined_channels
  model_dbt_zoom_project_brz_phone_history --> model_dbt_zoom_project_slv_combined_channels
  model_dbt_zoom_project_brz_sms_history --> model_dbt_zoom_project_slv_combined_channels
  model_dbt_zoom_project_brz_video_history --> model_dbt_zoom_project_slv_combined_channels
  model_dbt_zoom_project_slv_combined_channels --> model_dbt_zoom_project_slv_consolidated_usage
  model_dbt_zoom_project_slv_combined_channels --> model_dbt_zoom_project_slv_monthly_metrics
  model_dbt_zoom_project_slv_combined_channels --> model_dbt_zoom_project_slv_user_active_days
  model_dbt_zoom_project_slv_consolidated_usage --> model_dbt_zoom_project_gld_aggregate
  model_dbt_zoom_project_slv_monthly_metrics --> model_dbt_zoom_project_gld_aggregate
  model_dbt_zoom_project_slv_user_active_days --> model_dbt_zoom_project_slv_monthly_metrics
  source_dbt_zoom_project_ZOOM_AI_POC_account_dim --> model_dbt_zoom_project_brz_account_dim
  source_dbt_zoom_project_ZOOM_AI_POC_chat_history --> model_dbt_zoom_project_brz_chat_history
  source_dbt_zoom_project_ZOOM_AI_POC_email_history --> model_dbt_zoom_project_brz_email_history
  source_dbt_zoom_project_ZOOM_AI_POC_phone_history --> model_dbt_zoom_project_brz_phone_history
  source_dbt_zoom_project_ZOOM_AI_POC_sms_history --> model_dbt_zoom_project_brz_sms_history
  source_dbt_zoom_project_ZOOM_AI_POC_video_history --> model_dbt_zoom_project_brz_video_history
```

> This Mermaid diagram renders in GitHub, GitLab, VS Code, and PR review with
> zero dependencies. For a static image: a `lineage_*.png` is written when
> Graphviz `dot` is installed, **or** paste `lineage_*.mmd` into
> https://mermaid.live and export PNG/SVG (no local install needed).
