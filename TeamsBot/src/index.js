require('dotenv').config();

const express = require('express');
const { CloudAdapter, ConfigurationBotFrameworkAuthentication } = require('botbuilder');
const { getConfig } = require('./config');
const { ClaudiaBot } = require('./claudiaBot');

const config = getConfig();

const botFrameworkAuthentication = new ConfigurationBotFrameworkAuthentication(process.env);
const adapter = new CloudAdapter(botFrameworkAuthentication);

adapter.onTurnError = async (context, error) => {
  console.error('[onTurnError]', error);
  await context.sendActivity('ClaudIA tuvo un error procesando la solicitud.');
};

const bot = new ClaudiaBot(config);
const server = express();
server.use(express.json());

server.get('/healthz', async (_req, res) => {
  res.json({
    status: 'ok',
    bot: 'ClaudIA',
    repoRoot: config.repoRoot,
    botConfigPath: config.botConfigPath,
    configPath: config.commandConfigPath,
    installationDefinitionsPath: config.installationDefinitionsPath,
    subscriptionId: config.subscriptionId
  });
});

server.post('/api/messages', async (req, res) => {
  await adapter.process(req, res, async (context) => {
    await bot.run(context);
  });
});

server.listen(config.port, () => {
  console.log(`ClaudIA listening on http://localhost:${config.port}`);
  console.log(`Messaging endpoint: http://localhost:${config.port}/api/messages`);
});
