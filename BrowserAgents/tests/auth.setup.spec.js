const { test, expect } = require('@playwright/test');
const fs = require('fs');
const path = require('path');

const upn = process.env.BROWSER_AGENT_UPN || 'priya.sharma@contoso.example';
const password = process.env.BROWSER_AGENT_PASSWORD || '';
const storageState = process.env.BROWSER_AGENT_STORAGE_STATE || '.auth/priya.sharma.json';
const officeUrl = process.env.BROWSER_AGENT_OFFICE_URL || 'https://www.office.com/';
const owaUrl = process.env.BROWSER_AGENT_OWA_URL || 'https://outlook.office.com/mail/';

test.use({ storageState: { cookies: [], origins: [] } });

test('capture Microsoft 365 browser session for persona', async ({ page }) => {
  test.setTimeout(10 * 60 * 1000);

  await page.goto(`${officeUrl}?auth=2`, { waitUntil: 'domcontentloaded' });

  const emailInput = page.locator('input[type="email"], input[name="loginfmt"], input[name="Email"], input[type="text"]').first();
  await emailInput.waitFor({ state: 'visible', timeout: 120000 }).catch(() => null);
  if (await emailInput.isVisible().catch(() => false)) {
    await emailInput.click();
    await emailInput.fill(upn);
    const nextButton = page.locator('input[type="submit"], button[type="submit"], button:has-text("Next")').first();
    if (await nextButton.isVisible().catch(() => false)) {
      await nextButton.click();
    } else {
      await page.keyboard.press('Enter');
    }
  }

  const passwordInput = page.locator('input[type="password"], input[name="passwd"], input[name="Password"]').first();
  await passwordInput.waitFor({ state: 'visible', timeout: 120000 }).catch(() => null);
  if (await passwordInput.isVisible().catch(() => false) && password) {
    await passwordInput.fill(password);
    const signInButton = page.locator('input[type="submit"], button[type="submit"], button:has-text("Sign in")').first();
    if (await signInButton.isVisible().catch(() => false)) {
      await signInButton.click();
    } else {
      await page.keyboard.press('Enter');
    }
  }

  const staySignedInButton = page.locator('input[type="submit"], button[type="submit"], button:has-text("Yes"), input[value="Yes"], input[value="Sí"]').first();
  await staySignedInButton.waitFor({ state: 'visible', timeout: 30000 }).catch(() => null);
  if (await staySignedInButton.isVisible().catch(() => false)) {
    await staySignedInButton.click();
  }

  await page.waitForFunction(() => {
    const text = document.body?.innerText || '';
    const href = location.href.toLowerCase();
    const onLogin = href.includes('login.microsoftonline.com') || /sign in|enter password|password|next/i.test(text);
    const inM365 = href.includes('office.com') || href.includes('microsoft365.com') || href.includes('cloud.microsoft') || href.includes('outlook.office.com');
    const appText = /app launcher|word|excel|powerpoint|outlook|onedrive|my content|create|copilot|new chat|meetings|priya/i.test(text);
    return inM365 && appText && !onLogin;
  }, { timeout: 10 * 60 * 1000 });

  await page.goto(owaUrl, { waitUntil: 'domcontentloaded' });
  await page.waitForFunction(() => {
    const text = document.body?.innerText || '';
    const href = location.href.toLowerCase();
    const onLogin = href.includes('login.microsoftonline.com') || /sign in|enter password|password|next/i.test(text);
    const inOwa = href.includes('outlook.office.com');
    const mailText = /outlook|mail|inbox|sent items|new mail|bandeja|correo/i.test(text);
    return inOwa && mailText && !onLogin;
  }, { timeout: 5 * 60 * 1000 });

  fs.mkdirSync(path.dirname(storageState), { recursive: true });
  await page.context().storageState({ path: storageState });
  await expect(page).toHaveURL(/office|microsoft|live|sharepoint|outlook/i);
});
