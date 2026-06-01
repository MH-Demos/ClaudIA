# Learn ClaudIA From Scratch

This page is for people who are new to AI, Microsoft 365, Azure, cloud security, or workplace technology.

You do not need to understand every Microsoft security product before reading the ClaudIA repository. ClaudIA can be used as a learning portal: first to understand the concepts, then to explore a live demo, and only later to deploy the full lab.

## The Short Version

ClaudIA creates a fictional company inside a Microsoft 365 lab tenant.

That fictional company has synthetic employees. They send emails, create files, use Teams, work with AI, share information, make mistakes, and create security signals.

ClaudIA then helps you see the story behind that activity:

- Who did something?
- What file, message, prompt, or service was involved?
- Was the activity normal, risky, or suspicious?
- Which security tool can detect or explain it?
- How does AI change the risk?

## Before You Touch The Installer

If you are just starting, do not begin with deployment.

Start with the learning path:

1. Read this page.
2. Open the public Activity Story Map at https://activitymap.mhdemos.com. This is a live reference portal and the URL may change between publications.
3. Read [personas.md](personas.md) to understand the fictional employees.
4. Read [glossary.md](glossary.md) when you find a term you do not know.
5. Read [../Storyline/profiles.md](../Storyline/profiles.md) to connect people and scenarios.
6. Read [../How to Start.md](../How%20to%20Start.md) only when you are ready to deploy a lab.

## Core Ideas

### 1. A tenant is the cloud space where a company works

A Microsoft 365 tenant is like a company's cloud workplace. It can contain users, mailboxes, Teams, SharePoint sites, files, policies, apps, and security settings.

ClaudIA should run only in a lab tenant, not in a real production tenant.

### 2. A persona is a fictional employee

ClaudIA uses fictional employees such as Alexander, Ana, Devon, Priya, Diego, Laura, and others.

Each persona has:

- A role.
- A manager.
- A department.
- A workload focus.
- A reason to exist in the story.

For example, Devon Reyes is used to generate controlled risky or suspicious behavior so learners can understand how security investigations work.

### 3. Activity is what users do

Activity can be simple:

- Create a file.
- Send an email.
- Upload a document.
- Share a link.
- Ask an AI assistant to summarize something.
- Open a web app.

Security tools become more useful when there is realistic activity to analyze.

### 4. Telemetry is the record left behind

Telemetry is the trail of events created when users and systems do things.

In ClaudIA, activity can be stored in Azure Data Explorer so it can be queried, visualized, and explained.

### 5. AI needs context

An AI assistant does not work in isolation. It responds based on the prompt, available data, permissions, conversation context, and sometimes previous memory or session state.

In workplace AI, this matters because AI may summarize, reason over, or expose information that users already have access to.

A key lesson is:

> AI does not magically create governance. It inherits the data, permissions, and context around it.

### 6. Security is about understanding behavior, data, and access together

A file is not risky only because it exists.

Risk depends on questions such as:

- Who owns it?
- Who can access it?
- Does it contain sensitive information?
- Was it shared externally?
- Was it copied into an AI prompt?
- Was it downloaded from an unusual location?
- Was the user allowed to do that?

ClaudIA helps connect these questions visually.

## What The Main Technologies Do

| Concept | Simple explanation |
| --- | --- |
| Microsoft 365 | The cloud workplace: email, files, Teams, SharePoint, OneDrive, and collaboration. |
| Azure | The cloud platform where ClaudIA runs automation, storage, APIs, AI, and telemetry components. |
| Microsoft Entra ID | The identity system that contains users, groups, app registrations, and sign-in context. |
| Microsoft Purview | A Microsoft platform for data security, compliance, labels, DLP, and governance. |
| Microsoft Defender | A Microsoft security platform for detecting and investigating threats. |
| MDCA | Microsoft Defender for Cloud Apps; helps understand and govern cloud app usage. |
| Azure OpenAI | A service used by ClaudIA to generate synthetic business content for the lab. |
| Azure AI Foundry | A platform used to represent or run AI model scenarios, including external AI-style patterns. |
| Azure Key Vault | A secure place to store secrets such as passwords, tokens, and client secrets. |
| Azure Automation | Runs scheduled scripts and runbooks so ClaudIA can generate activity automatically. |
| Azure Data Explorer | Stores and queries activity telemetry using KQL. |
| Playwright | Browser automation used by BrowserAgents to simulate web-based activity. |
| Activity Story Map | The visual portal that shows personas, services, relationships, and activity. |

## What You Should Learn First

### Stage 1: Understand the story

Goal: understand what ClaudIA is trying to show.

Read:

- [personas.md](personas.md)
- [branding.md](branding.md)
- [glossary.md](glossary.md)

Explore:

- https://activitymap.mhdemos.com

This is the current public reference deployment. Future publications may use a different URL.

Questions to answer:

- Who are the personas?
- Why does Devon exist?
- What is the difference between ClaudIA and MH Demos?
- What does the Activity Story Map show?

### Stage 2: Understand the cloud workplace

Goal: understand the Microsoft 365 environment that ClaudIA simulates.

Learn these terms:

- Tenant.
- User.
- Group.
- Mailbox.
- SharePoint site.
- OneDrive.
- Teams.
- License.
- Permission.

Questions to answer:

- Why does each persona need an account?
- Why do personas need licenses?
- Why does access matter for AI?

### Stage 3: Understand AI context and risk

Goal: understand why AI is not just a chatbot.

Learn these terms:

- Prompt.
- Response.
- Context.
- Memory.
- Session.
- Grounding.
- Oversharing.
- Shadow AI.

Questions to answer:

- What can happen when a user gives sensitive data to AI?
- Why does previous context change the answer?
- Why does AI governance depend on data governance?

### Stage 4: Understand security signals

Goal: understand how normal work becomes something security teams can investigate.

Learn these terms:

- DLP.
- Sensitivity label.
- Insider Risk.
- Audit log.
- Telemetry.
- Detection.
- Investigation.
- Exfiltration.

Questions to answer:

- What makes an activity risky?
- How can a security tool detect risky activity?
- What is the difference between a mistake and malicious behavior?

### Stage 5: Understand the architecture

Goal: understand how ClaudIA runs.

Learn these terms:

- Azure Automation.
- Runbook.
- Managed identity.
- RBAC.
- Key Vault.
- ADX.
- Azure Function.
- Static website.
- Browser automation.

Questions to answer:

- Which component creates activity?
- Which component stores secrets?
- Which component stores telemetry?
- Which component shows the visual portal?

### Stage 6: Deploy only when ready

Goal: build your own lab after you understand the basics.

Read:

- [../DISCLAIMER.md](../DISCLAIMER.md)
- [security.md](security.md)
- [../If Your Tenant Is Completely New.md](../If%20Your%20Tenant%20Is%20Completely%20New.md)
- [../How to Start.md](../How%20to%20Start.md)

Do not deploy ClaudIA in a production tenant.

## Beginner Learning Exercises

### Exercise 1: Follow one persona

Pick one persona, such as Priya Sharma or Devon Reyes.

Try to answer:

- What is their role?
- Who is their manager?
- What kind of activity do they generate?
- Which security topic do they help explain?

### Exercise 2: Follow one file

In the Activity Story Map, look for a file or activity event.

Try to answer:

- Who created it?
- Which service was used?
- Was AI involved?
- Was the activity normal or risky?
- What tool could help investigate it?

### Exercise 3: Explain one risk in plain language

Choose one concept, such as DLP or Shadow AI.

Explain it in one sentence.

Example:

> DLP helps detect or prevent sensitive information from being shared in unsafe ways.

### Exercise 4: Draw the architecture

Draw a simple diagram with these boxes:

```text
Personas -> Microsoft 365 activity -> ADX telemetry -> Activity Story Map
                    |
                    v
             Purview / Defender signals
```

Then add:

- Key Vault for secrets.
- Azure Automation for scheduled activity.
- Azure OpenAI for synthetic content.
- BrowserAgents for web activity.

## What ClaudIA Is Not

ClaudIA is not:

- A production security product.
- A real company.
- A replacement for Microsoft Purview or Defender.
- A hacking tool.
- A place to store real data.
- A shortcut around learning cloud fundamentals.

ClaudIA is a learning and simulation platform that helps you understand how workplace activity, AI, data, identity, and security tools connect.

## Recommended Next Pages

| Page | Why read it |
| --- | --- |
| [glossary.md](glossary.md) | Learn the basic vocabulary. |
| [personas.md](personas.md) | Understand the fictional employees. |
| [branding.md](branding.md) | Understand ClaudIA vs. MH Demos. |
| [security.md](security.md) | Understand the security model and risks. |
| [../How to Start.md](../How%20to%20Start.md) | Deploy only after you understand the basics. |
