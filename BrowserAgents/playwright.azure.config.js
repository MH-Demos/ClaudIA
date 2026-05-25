const { defineConfig, devices } = require('@playwright/test');
const { createAzurePlaywrightConfig, ServiceAuth } = require('@azure/playwright');
const { DefaultAzureCredential } = require('@azure/identity');
require('dotenv').config();

const storageState = process.env.BROWSER_AGENT_STORAGE_STATE || '.auth/priya.sharma.json';
const serviceUrl = process.env.PLAYWRIGHT_SERVICE_URL;

if (!serviceUrl) {
  throw new Error('PLAYWRIGHT_SERVICE_URL is required. Copy .env.sample to .env and verify the workspace URL.');
}

const config = defineConfig({
  testDir: './tests',
  workers: 1,
  timeout: 180000,
  expect: { timeout: 20000 },
  reporter: [['list'], ['html', { open: 'never' }]],
  use: {
    baseURL: process.env.BROWSER_AGENT_OFFICE_URL || 'https://www.office.com/',
    storageState,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure'
  },
  projects: [
    {
      name: 'azure-chromium',
      use: { ...devices['Desktop Chrome'] }
    }
  ]
});

module.exports = defineConfig(config, createAzurePlaywrightConfig(config, {
  serviceAuthType: ServiceAuth.ENTRA_ID,
  credential: new DefaultAzureCredential()
}));
