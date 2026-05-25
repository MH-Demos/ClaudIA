const { test, expect } = require('@playwright/test');

const displayName = process.env.BROWSER_AGENT_DISPLAY_NAME || 'Priya Sharma';
const officeUrl = process.env.BROWSER_AGENT_OFFICE_URL || 'https://www.office.com/';
const owaUrl = process.env.BROWSER_AGENT_OWA_URL || 'https://outlook.office.com/mail/';

test('Office Web session opens as the persona', async ({ page }) => {
  await page.goto(`${officeUrl}?auth=2`, { waitUntil: 'domcontentloaded' });
  await page.waitForFunction(() => {
    const text = document.body?.innerText || '';
    const href = location.href.toLowerCase();
    const onLogin = href.includes('login.microsoftonline.com') || /sign in|enter password|password|next/i.test(text);
    const inM365 = href.includes('office.com') || href.includes('microsoft365.com') || href.includes('cloud.microsoft');
    const appText = /app launcher|word|excel|powerpoint|outlook|onedrive|my content|create|copilot|new chat|meetings|priya/i.test(text);
    return inM365 && appText && !onLogin;
  }, { timeout: 60000 });

  const body = await page.locator('body').innerText();
  if (!body.toLowerCase().includes(displayName.toLowerCase().split(' ')[0])) {
    test.info().annotations.push({
      type: 'note',
      description: `The page loaded, but visible text did not clearly show ${displayName}. Verify account menu manually if this is the first run.`
    });
  }
});

test('OWA session opens for browser-agent mail scenarios', async ({ page }) => {
  await page.goto(owaUrl, { waitUntil: 'domcontentloaded' });
  await page.waitForFunction(() => {
    const text = document.body?.innerText || '';
    const href = location.href.toLowerCase();
    const onLogin = href.includes('login.microsoftonline.com') || /sign in|enter password|password|next/i.test(text);
    const inOwa = href.includes('outlook.office.com');
    const mailText = /outlook|mail|inbox|sent items|new mail|bandeja|correo/i.test(text);
    return inOwa && mailText && !onLogin;
  }, { timeout: 60000 });
});
