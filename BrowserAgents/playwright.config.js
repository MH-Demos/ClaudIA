const { defineConfig, devices } = require('@playwright/test');
require('dotenv').config();

const storageState = process.env.BROWSER_AGENT_STORAGE_STATE || '.auth/priya.sharma.json';

module.exports = defineConfig({
  testDir: './tests',
  workers: 1,
  timeout: 120000,
  expect: { timeout: 15000 },
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
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] }
    }
  ]
});
