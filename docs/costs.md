# Detailed Cost Breakdown

## Azure OpenAI — Model Pricing and Tokenization

The agents use Azure OpenAI for AI-generated PII content. Cost depends on the model, token volume, and run frequency.

### Model Comparison

| Model | Input (per 1M tokens) | Output (per 1M tokens) | Context Window | Best for | Config value |
| --- | --- | --- | --- | --- | --- |
| **GPT-4o** (default) | $2.50 | $10.00 | 128K | Realistic cross-dept content, best French, diverse formats | `"openAiModel": "gpt-4o"` |
| GPT-4o-mini | $0.15 | $0.60 | 128K | Budget mode, sufficient for basic SIT-precise PII | `"openAiModel": "gpt-4o-mini"` |
| **GPT-4.1-mini** | $0.40 | $1.60 | 1M | Long-form documents, multi-page reports | `"openAiModel": "gpt-4.1-mini"` |
| **GPT-4.1** | $2.00 | $8.00 | 1M | Maximum quality, complex legal/financial content | `"openAiModel": "gpt-4.1"` |
| **gpt-image-1** (optional) | $0.04/image (Standard) | - | - | Badge scans, org charts, document images | `"openAiImageModel": "gpt-image-1"` |

### Tokenization per Run (10 agents, 1 burst, GPT-4o with upgraded tokens)

| Activity | Avg Input Tokens | Avg Output Tokens | Count/Run | Total Tokens/Run |
| --- | --- | --- | --- | --- |
| File generation (system + user prompt) | ~500 | ~1,500 | 55 files | ~110K |
| Scanned images (PNG, no AI) | 0 | 0 | 3 images | 0 |
| Email generation | ~400 | ~800 | 25 emails | ~30K |
| Email thread generation | ~600 | ~1,200 | 7 msgs | ~13K |
| Copilot search query generation | ~300 | ~200 | 15 queries | ~8K |
| **Total per run** | | | | **~161K tokens** |

### Monthly Cost by Model and Schedule

| Model | 1x/day | 3x/day (default) | 5x/day |
| --- | --- | --- | --- |
| GPT-4o-mini | ~$0.10 | ~$0.30 | ~$0.50 |
| **GPT-4o** (default) | **~$1.60** | **~$4.80** | **~$8.00** |
| GPT-4.1-mini | ~$0.26 | ~$0.77 | ~$1.30 |
| GPT-4.1 | ~$1.30 | ~$3.90 | ~$6.50 |
| DALL-E 3 (5 images/run) | ~$6 | ~$18 | ~$30 |

> Calculation: tokens/run x runs/day x 30 days x price/token. DALL-E priced per image.

### TPM (Tokens Per Minute) Capacity

The `openAiTpm` config controls the provisioned throughput:

| TPM | Use case | Max concurrent agents | Config |
| --- | --- | --- | --- |
| 10 | Budget mode, 1 run/day | 1 | `"openAiTpm": 10` |
| **30** (default) | **Standard, 3 runs/day, GPT-4o** | **1-2** | **`"openAiTpm": 30`** |
| 60 | Heavy use, parallel runs, long content | 2-3 | `"openAiTpm": 60` |
| 120 | Cross-department, large files, image generation | 3+ | `"openAiTpm": 120` |

> TPM does not affect monthly cost — you only pay for tokens consumed. Higher TPM avoids throttling (HTTP 429) during burst mode.

## Azure Resources

| Resource | SKU | Monthly Cost | Calculation |
| --- | --- | --- | --- |
| Azure OpenAI `oai-claudia-lab` | GPT-4o | ~$5 | See model table above (3x/day default with GPT-4o) |
| Azure Automation `aa-claudia-lab` | Basic | ~$2 | $0.002/min. 3 runs/day x ~20 min/run x 30 days = ~1800 min/mo |
| Azure Data Explorer `adx-claudia-lab` | Dev(No SLA) / Basic | usage-based | Primary telemetry backend for runbook, BrowserAgents, workbook, and Activity Story Map. |
| Azure Monitor Workbook | Free | $0 | No cost for workbook queries |
| **Total Azure** | | **~$7/month** | With GPT-4o 3x/day |

## Optional Azure Resources

| Resource | SKU | Monthly Cost | When needed |
| --- | --- | --- | --- |
| Fabric F2 capacity | F2 | ~$262 | Only if `fabricEnabled: true`. Pause when not demoing. |
| Key Vault Premium | Premium | ~$1 | If using KV instead of Automation variables |
| OneLake storage | Pay-as-you-go | ~$0.02 | ~1 MB/month of CSV/JSON/XML files in lakehouse |
| DALL-E 3 deployment | Standard | ~$18 | 5 images/run x 3 runs/day (optional) |
| **Total with all options** | | **~$284/month** | |

## Cost by Deployment Step

| Step | Resources Created | Monthly Cost Impact |
| --- | --- | --- |
| 0-3 | Users, licenses, app registration | $0 (uses existing M365 pool) |
| 4 | Azure OpenAI + Automation + LA + Sentinel | ~$3 |
| 4a | Teams team + SharePoint site | $0 (M365 infra, no Azure cost) |
| 4b | Sensitivity labels + policy | $0 (M365 compliance, no Azure cost) |
| 4c | Fabric F2 + workspace + lakehouse | ~$262 (optional, pausable) |
| 5 | Runbook + schedules | $0 (included in AA cost) |
| 6 | DLP + IRM policies | $0 (M365 compliance) |
| 7 | Workbook | $0 |

## M365 Licenses (from existing pool)

| License | Count | Monthly Cost | Notes |
| --- | --- | --- | --- |
| M365 E5 | 10 agents | $0 extra | Uses existing license pool |
| Copilot M365 | 5 agents (Wave 2) | $0 extra | Optional, uses existing pool |
| Teams Enterprise | 10 agents | $0 extra | Usually bundled |

## Cost Optimization Tips

1. **Reduce agent count**: Edit `agents.json` to deploy 5 agents instead of 10
2. **Reduce schedule frequency**: Change from 3x/day to 1x/day
3. **Disable Fabric**: Set `fabricEnabled: false` in config (saves $262/mo)
4. **Pause Fabric**: When not demoing, pause the F2 capacity in Azure Portal
5. **Use Free Automation tier**: If total run time < 500 min/month (5 agents x 1 run/day)

## Cost by Scenario

| Scenario | Agents | Schedules | Fabric | Model | Monthly Azure Cost |
| --- | --- | --- | --- | --- | --- |
| Budget (demo-only) | 5 (Wave 1) | 1x/day | No | GPT-4o-mini | ~$2 |
| Minimal | 5 (Wave 1) | 1x/day | No | GPT-4o | ~$4 |
| **Standard (recommended)** | **10 (both waves)** | **3x/day** | **No** | **GPT-4o** | **~$7** |
| Full (with Fabric) | 10 + Emma datasets | 3x/day | Yes (F2) | GPT-4o | ~$270 |
| Full + images | 10 + scans + DALL-E | 3x/day | Yes | GPT-4o | ~$288 |

## Comparison with Alternatives

| Approach | Monthly Cost | Agents | Content Quality | Identity |
| --- | --- | --- | --- | --- |
| **This solution** | ~$7 | 10 | AI-generated + scanned images, unique | Real user (ROPC) |
| Manual file creation | $0 | 0 | Human effort | Human |
| Power Automate Premium | ~$150 | 5 | Template-based | Service account |
| Azure Logic Apps + AOAI | ~$50 | 5 | AI-generated | App identity |
| Copilot Studio only | ~$200/mo standalone | 5 | Interactive only | User-triggered |
