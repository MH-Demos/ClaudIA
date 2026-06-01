const { TeamsActivityHandler, TurnContext } = require('botbuilder');
const { executeCommand } = require('./commands');

function getUserKeys(context) {
  const from = context.activity.from || {};
  return [
    from.aadObjectId,
    from.userPrincipalName,
    from.name,
    from.id
  ]
    .filter(Boolean)
    .map((value) => String(value).toLowerCase());
}

function isAllowed(context, config) {
  if (!config.allowedUsers || config.allowedUsers.length === 0) {
    return true;
  }

  const keys = getUserKeys(context);
  return keys.some((key) => config.allowedUsers.includes(key));
}

class ClaudiaBot extends TeamsActivityHandler {
  constructor(config) {
    super();
    this.config = config;

    this.onMembersAdded(async (context, next) => {
      const membersAdded = context.activity.membersAdded || [];
      for (const member of membersAdded) {
        if (member.id !== context.activity.recipient.id) {
          await context.sendActivity([
            'Hola, soy ClaudIA.',
            'Puedo validar estado, listar ayuda y forzar actividades del laboratorio desde Teams.',
            'Escribe `help` para empezar.'
          ].join('\n'));
        }
      }
      await next();
    });

    this.onMessage(async (context, next) => {
      if (!isAllowed(context, this.config)) {
        await context.sendActivity('No tienes permisos para ejecutar comandos de ClaudIA.');
        await next();
        return;
      }

      await context.sendActivity({ type: 'typing' });
      const text = TurnContext.removeRecipientMention(context.activity) || context.activity.text || '';

      try {
        const response = await executeCommand(this.config, text);
        await context.sendActivity(response);
      } catch (error) {
        await context.sendActivity(`No pude ejecutar el comando: ${error.message}`);
      }

      await next();
    });
  }
}

module.exports = {
  ClaudiaBot
};
