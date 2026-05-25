FROM mcr.microsoft.com/playwright:v1.60.0-noble

WORKDIR /app

COPY BrowserAgents/package*.json ./BrowserAgents/
WORKDIR /app/BrowserAgents
RUN npm ci

WORKDIR /app
COPY config ./config
COPY synthetic-m365-purview-pack ./synthetic-m365-purview-pack
COPY BrowserAgents ./BrowserAgents

WORKDIR /app/BrowserAgents
ENV CI=true
ENV BROWSER_AGENT_SEND_EMAIL=true
ENV BROWSER_AGENT_INCLUDE_SENSITIVE=true
ENV BROWSER_AGENT_EXTERNAL_RECIPIENT=demo.recipient@example.com

CMD ["node", "scripts/run-scheduled.js"]
