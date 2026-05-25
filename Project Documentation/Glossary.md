# Glossary

- ADX: Azure Data Explorer. The active telemetry backend for this lab.
- Activity Story Map: the lab web page that displays ADX events as a graph and narrative timeline.
- Agent: a Microsoft 365 user used by the runbook to generate synthetic activity.
- Automation Account: the Azure resource that hosts and runs `Invoke-AgentRunbook`.
- Automation variable: a configuration value stored in Azure Automation. In this architecture it must not contain plaintext passwords or client secrets.
- DSPM for AI: Data Security Posture Management for AI/Copilot scenarios.
- Effective config: the merged configuration produced from `agents.json` and `Installation_definitions.json`.
- Expansion pack: the addition of new characters/agents through `tools/Add-StorylineAgents.ps1`.
- IPPS: Security & Compliance PowerShell session used for Purview.
- IRM: Insider Risk Management.
- Key Vault: the secret store for the application secret and agent passwords.
- ROPC: Resource Owner Password Credentials. The flow used by the runbook to act as each agent; it requires password authentication and MFA exclusion.
- SIT: Microsoft Purview Sensitive Information Type.
- Storyline: the profiles, storyboard, and scenarios that give narrative meaning to the generated activity.
- Wave: an agent grouping used for demo sequencing or expansion.

