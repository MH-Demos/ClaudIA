const { test, expect } = require('@playwright/test');
const { getPersonaContext } = require('../lib/personaContext');
const { createTelemetryClient } = require('../lib/adxTelemetry');
const { buildEmailScenario } = require('../lib/contentPack');

const owaUrl = process.env.BROWSER_AGENT_OWA_URL || 'https://outlook.office.com/mail/inbox';
const sendEmail = /^true$/i.test(process.env.BROWSER_AGENT_SEND_EMAIL || '');
const includeSensitive = !/^false$/i.test(
  process.env.BROWSER_AGENT_EMAIL_INCLUDE_SENSITIVE || process.env.BROWSER_AGENT_INCLUDE_SENSITIVE || 'true'
);
const labelName = process.env.BROWSER_AGENT_EMAIL_LABEL || '';

function splitRecipients(value) {
  return String(value || '')
    .split(',')
    .map((item) => item.trim())
    .filter(Boolean);
}

function hashText(value) {
  let hash = 0;
  for (let i = 0; i < value.length; i += 1) {
    hash = ((hash << 5) - hash) + value.charCodeAt(i);
    hash |= 0;
  }
  return Math.abs(hash);
}

function chooseRecipient() {
  const fallback = process.env.BROWSER_AGENT_UPN || 'priya.sharma@contoso.example';
  const recipients = splitRecipients(process.env.BROWSER_AGENT_EMAIL_RECIPIENT || fallback);
  if (recipients.length <= 1) return recipients[0] || fallback;
  const seed = [
    process.env.BROWSER_AGENT_PERSONA || process.env.BROWSER_AGENT_UPN || '',
    new Date().toISOString().slice(0, 10)
  ].join(':');
  return recipients[hashText(seed) % recipients.length];
}

const recipient = chooseRecipient();

function escapeRegExp(value) {
  return String(value).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

async function waitForOwa(page) {
  await page.goto(owaUrl, { waitUntil: 'domcontentloaded' });
  await dismissBlockingDialogs(page).catch(() => null);
  if (!page.url().toLowerCase().includes('/mail') || page.url().toLowerCase().includes('/bookings')) {
    await page.goto('https://outlook.office.com/mail/inbox', { waitUntil: 'domcontentloaded' });
    await dismissBlockingDialogs(page).catch(() => null);
  }
  await page.waitForFunction(() => {
    const text = document.body?.innerText || '';
    const href = location.href.toLowerCase();
    const onLogin = href.includes('login.microsoftonline.com') || /sign in|enter password|password|next/i.test(text);
    const inOwa = (href.includes('outlook.office.com') || href.includes('outlook.cloud.microsoft')) && href.includes('/mail') && !href.includes('/bookings');
    const mailText = /mail|inbox|sent items|new mail|new message|bandeja|correo nuevo/i.test(text);
    return inOwa && mailText && !onLogin;
  }, { timeout: 90000 });
  await dismissBlockingDialogs(page).catch(() => null);
}

async function dismissBlockingDialogs(page) {
  const buttons = [
    /continue/i,
    /next/i,
    /accept/i,
    /ok/i,
    /got it/i,
    /not now/i,
    /skip/i,
    /dismiss/i,
    /continuar/i,
    /aceptar/i,
    /descartar/i
  ];
  for (let pass = 0; pass < 4; pass += 1) {
    let clicked = false;
    for (const name of buttons) {
      const button = page.getByRole('button', { name }).first();
      if (await button.isVisible().catch(() => false)) {
        await button.click();
        await page.waitForTimeout(1000);
        clicked = true;
        break;
      }
    }
    if (!clicked) break;
  }
}

async function resolveRecipient(page, recipientAddress) {
  const recipientPattern = new RegExp(escapeRegExp(recipientAddress), 'i');
  const recipientOption = page.getByRole('option', { name: recipientPattern }).first();
  if (await recipientOption.isVisible().catch(() => false)) {
    await recipientOption.click();
    await page.waitForTimeout(1000);
  }

  const confirmationButtons = [
    /use this address/i,
    /add recipient/i,
    /add/i,
    /usar esta direcci[oó]n/i,
    /agregar destinatario/i,
    /agregar/i
  ];

  for (const name of confirmationButtons) {
    const button = page.getByRole('button', { name }).last();
    if (await button.isVisible().catch(() => false)) {
      await button.click({ timeout: 10000 }).catch(async () => {
        await button.click({ force: true, timeout: 10000 }).catch(() => null);
      });
      await page.waitForTimeout(1000);
      break;
    }
  }

  await page.keyboard.press('Tab').catch(() => null);
}

async function handleSendPrompts(page) {
  const confirmButtons = [
    /send anyway/i,
    /^send$/i,
    /send now/i,
    /continue/i,
    /^yes$/i,
    /^ok$/i,
    /enviar de todos modos/i,
    /^enviar$/i,
    /continuar/i,
    /^si$/i,
    /^s[ií]$/i
  ];

  for (let pass = 0; pass < 8; pass += 1) {
    await page.waitForTimeout(1500);
    let clicked = false;
    for (const name of confirmButtons) {
      const button = page.getByRole('button', { name }).last();
      if (await button.isVisible().catch(() => false)) {
        await button.click({ timeout: 10000 }).catch(async () => button.click({ force: true, timeout: 10000 }));
        clicked = true;
        break;
      }
    }
    if (!clicked) {
      const text = await page.locator('body').innerText().catch(() => '');
      if (!/getting this ready|policy tip|schedule send|send this email|external sharing|sensitive data/i.test(text)) {
        break;
      }
    }
  }
}

async function clickSendButton(page) {
  const candidates = [
    page.getByRole('button', { name: /^send$/i }).last(),
    page.getByRole('button', { name: /^enviar$/i }).last(),
    page.locator('button[aria-label*="Send" i]:visible, button[title*="Send" i]:visible').last(),
    page.locator('button[aria-label*="Enviar" i]:visible, button[title*="Enviar" i]:visible').last()
  ];

  for (const button of candidates) {
    if (await button.isVisible().catch(() => false)) {
      await button.click({ timeout: 10000 }).catch(async () => button.click({ force: true, timeout: 10000 }));
      return true;
    }
  }

  return false;
}

async function hasVisibleSendButton(page) {
  const candidates = [
    page.getByRole('button', { name: /^send$/i }).last(),
    page.getByRole('button', { name: /^enviar$/i }).last(),
    page.locator('button[aria-label*="Send" i]:visible, button[title*="Send" i]:visible').last(),
    page.locator('button[aria-label*="Enviar" i]:visible, button[title*="Enviar" i]:visible').last()
  ];

  for (const button of candidates) {
    if (await button.isVisible().catch(() => false)) {
      return true;
    }
  }

  return false;
}

async function attemptSendFromCurrentCompose(page) {
  for (let pass = 0; pass < 3; pass += 1) {
    await dismissBlockingDialogs(page);
    const clicked = await clickSendButton(page);
    if (!clicked) {
      await page.keyboard.press('Control+Enter');
    }
    await handleSendPrompts(page);
    await page.waitForTimeout(4000);
    if (!(await hasVisibleSendButton(page))) {
      break;
    }
  }

  const body = page.locator('body');
  await expect(body).not.toContainText(/Getting this ready/i, { timeout: 45000 });
}

async function reopenDraftAndSend(page, subject, recipient) {
  await page.goto('https://outlook.office.com/mail/drafts', { waitUntil: 'domcontentloaded' });
  await dismissBlockingDialogs(page);
  await page.waitForTimeout(5000);

  const draftBySubject = page.getByText(subject, { exact: false }).first();
  const draftByRecipient = page.getByText(recipient, { exact: false }).first();
  if (await draftBySubject.isVisible().catch(() => false)) {
    await draftBySubject.dblclick().catch(async () => draftBySubject.click());
  } else if (await draftByRecipient.isVisible().catch(() => false)) {
    await draftByRecipient.dblclick().catch(async () => draftByRecipient.click());
  } else {
    return false;
  }

  await page.waitForTimeout(3000);
  await page.keyboard.press('Enter').catch(() => null);
  await page.waitForTimeout(3000);
  await dismissBlockingDialogs(page);
  const bodyBox = page.locator('[aria-label*="Message body"], [aria-label*="Cuerpo"], div[contenteditable="true"]').last();
  await bodyBox.waitFor({ state: 'visible', timeout: 30000 }).catch(() => null);
  await attemptSendFromCurrentCompose(page);
  return true;
}

async function assertMessageInSentItems(page, subject, recipient) {
  await page.goto('https://outlook.office.com/mail/sentitems', { waitUntil: 'domcontentloaded' });
  await dismissBlockingDialogs(page);
  await page.waitForTimeout(8000);

  const body = page.locator('body');
  const sentText = await body.innerText({ timeout: 30000 });
  if (sentText.includes(subject) || sentText.toLowerCase().includes(recipient.toLowerCase())) {
    return;
  }

  const diagnostics = [];
  for (const folder of ['drafts', 'outbox']) {
    await page.goto(`https://outlook.office.com/mail/${folder}`, { waitUntil: 'domcontentloaded' });
    await dismissBlockingDialogs(page);
    await page.waitForTimeout(5000);
    const text = await body.innerText({ timeout: 30000 }).catch(() => '');
    const hit = text.includes(subject) || text.toLowerCase().includes(recipient.toLowerCase());
    diagnostics.push(`${folder}=${hit ? 'contains message' : 'no matching message'}`);
  }

  throw new Error(`Message was not found in Sent Items after send attempt. ${diagnostics.join('; ')}`);
}

async function assertMessageSentWithDraftRetry(page, subject, recipient) {
  await attemptSendFromCurrentCompose(page);
  try {
    await assertMessageInSentItems(page, subject, recipient);
    return;
  } catch (error) {
    if (!String(error.message || '').includes('drafts=contains message')) {
      throw error;
    }
  }

  const retried = await reopenDraftAndSend(page, subject, recipient);
  if (!retried) {
    throw new Error('Message was saved to Drafts after send attempt, but the draft could not be reopened for retry.');
  }

  await assertMessageInSentItems(page, subject, recipient);
}

test('OWA daily activity draft with sensitive business context', async ({ page }) => {
  test.setTimeout(300000);
  const ctx = getPersonaContext();
  const telemetry = createTelemetryClient();

  await waitForOwa(page);
  await telemetry.push('browser_session', 'OWA session opened', {
    Service: 'Outlook Web',
    Workload: 'Exchange Online',
    Action: 'OWAOpen',
    ScenarioId: ctx.scenarioId
  }).catch((error) => test.info().annotations.push({ type: 'adx-warning', description: error.message }));

  const newMail = page.getByRole('button', { name: /new mail|new message|nuevo correo|correo nuevo/i }).first();
  if (await newMail.isVisible().catch(() => false)) {
    await newMail.click();
  } else {
    await page.goto('https://outlook.office.com/mail/deeplink/compose', { waitUntil: 'domcontentloaded' });
  }
  await dismissBlockingDialogs(page);

  const toBox = page.locator('div[role="textbox"][aria-label*="To"], div[role="textbox"][aria-label*="Para"], div[aria-label*="To"][contenteditable="true"], div[aria-label*="Para"][contenteditable="true"], input[aria-label*="To"], input[aria-label*="Para"]').first();
  try {
    await toBox.waitFor({ state: 'visible', timeout: 30000 });
  } catch {
    await dismissBlockingDialogs(page);
    await page.goto('https://outlook.office.com/mail/deeplink/compose', { waitUntil: 'domcontentloaded' });
    await dismissBlockingDialogs(page);
    await toBox.waitFor({ state: 'visible', timeout: 30000 });
  }
  await toBox.click();
  await page.keyboard.type(recipient);
  await page.keyboard.press('Enter');
  await resolveRecipient(page, recipient);

  const emailScenario = buildEmailScenario(ctx, includeSensitive);
  const subject = emailScenario?.subject || `BrowserAgent ${ctx.region} - HR sales correlation review - ${ctx.stamp}`;
  const subjectBox = page.locator('input[aria-label*="Subject"], input[placeholder*="Subject"], input[aria-label*="Asunto"], input[placeholder*="Asunto"], [role="textbox"][aria-label*="Subject"], [role="textbox"][aria-label*="Asunto"]').first();
  await subjectBox.waitFor({ state: 'visible', timeout: 30000 });
  await subjectBox.click();
  await subjectBox.fill(subject).catch(async () => {
    await page.keyboard.type(subject);
  });

  const bodyText = emailScenario?.body || [
    `Hi,`,
    ``,
    `I am validating the daily browser workflow for ${ctx.displayName}.`,
    includeSensitive
      ? `Please review whether this combined data extract should stay in a restricted workspace.`
      : `Please confirm this external mail delivery validation reached the test mailbox.`,
    ``,
    includeSensitive ? ctx.sensitiveBrief : ctx.normalBrief,
    ``,
    `Regards,`,
    ctx.displayName
  ].join('\n');

  const bodyBox = page.locator('[aria-label*="Message body"], [aria-label*="Cuerpo"], div[contenteditable="true"]').last();
  await bodyBox.waitFor({ state: 'visible', timeout: 30000 });
  await dismissBlockingDialogs(page);
  await bodyBox.click();
  await bodyBox.fill(bodyText).catch(async () => {
    await page.keyboard.type(bodyText);
  });
  await dismissBlockingDialogs(page);

  if (labelName) {
    const labelButton = page.locator(`button:has-text("${labelName}"), [role="button"]:has-text("${labelName}")`).first();
    const noLabelButton = page.locator('button:has-text("No label"), [role="button"]:has-text("No label")').first();
    if (await noLabelButton.isVisible().catch(() => false)) {
      await noLabelButton.click();
      await page.getByText(labelName, { exact: false }).first().click();
    } else if (await labelButton.isVisible().catch(() => false)) {
      await labelButton.click();
    } else {
      test.info().annotations.push({
        type: 'warning',
        description: `Requested label '${labelName}' was not visible in OWA compose.`
      });
    }
  }
  await telemetry.push('email', `Email composed to ${recipient}`, {
    Service: 'Outlook Web',
    Workload: 'Exchange Online',
    Action: 'EmailComposed',
    TargetName: subject,
    ScenarioContentId: emailScenario?.id || '',
    BusinessScenario: emailScenario?.businessScenario || '',
    AttachmentName: emailScenario?.attachmentName || '',
    Recipient: recipient,
    RecipientDomain: recipient.split('@').pop() || '',
    ExternalRecipient: !recipient.toLowerCase().endsWith('@contoso.example'),
    SensitivityLabel: labelName || '',
    ContainsSensitiveData: includeSensitive,
    ScenarioId: ctx.scenarioId
  }).catch((error) => test.info().annotations.push({ type: 'adx-warning', description: error.message }));

  if (sendEmail) {
    await assertMessageSentWithDraftRetry(page, subject, recipient);
    await telemetry.push('email', `Email sent to ${recipient}`, {
      Service: 'Outlook Web',
      Workload: 'Exchange Online',
      Action: 'EmailSent',
      TargetName: subject,
      ScenarioContentId: emailScenario?.id || '',
      BusinessScenario: emailScenario?.businessScenario || '',
      AttachmentName: emailScenario?.attachmentName || '',
      Recipient: recipient,
      RecipientDomain: recipient.split('@').pop() || '',
      ExternalRecipient: !recipient.toLowerCase().endsWith('@contoso.example'),
      SensitivityLabel: labelName || '',
      ContainsSensitiveData: includeSensitive,
      Outcome: 'SentItemsVerified',
      ScenarioId: ctx.scenarioId
    }).catch((error) => test.info().annotations.push({ type: 'adx-warning', description: error.message }));
  } else {
    await telemetry.push('email', `Email draft saved for ${recipient}`, {
      Service: 'Outlook Web',
      Workload: 'Exchange Online',
      Action: 'EmailDrafted',
      TargetName: subject,
      ScenarioContentId: emailScenario?.id || '',
      BusinessScenario: emailScenario?.businessScenario || '',
      AttachmentName: emailScenario?.attachmentName || '',
      Recipient: recipient,
      RecipientDomain: recipient.split('@').pop() || '',
      ExternalRecipient: !recipient.toLowerCase().endsWith('@contoso.example'),
      SensitivityLabel: labelName || '',
      ContainsSensitiveData: includeSensitive,
      Outcome: 'DraftOnly',
      ScenarioId: ctx.scenarioId
    }).catch((error) => test.info().annotations.push({ type: 'adx-warning', description: error.message }));
    test.info().annotations.push({
      type: 'note',
      description: 'Draft composed but not sent. Set BROWSER_AGENT_SEND_EMAIL=true to send during scheduled runs.'
    });
  }
});
