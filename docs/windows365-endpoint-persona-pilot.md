# Windows 365 Endpoint Persona Pilot

This pilot adds a user-attributed endpoint execution layer to the lab. The cloud
runbooks still orchestrate broad activity, but endpoint actions must run from a
real Windows session when the demo needs Activity Explorer to show the simulated
employee instead of `SHAREPOINT\system`.

## Target Pilot User

- User: Priya Sharma
- Persona id: `priya.sharma`
- Device type: Windows 365 Cloud PC
- Goal: generate Activity Explorer events where the actor is Priya and the device
  is her Cloud PC.

## Why This Is Needed

Microsoft Graph `assignSensitivityLabel` applies labels through the SharePoint /
OneDrive service pipeline. Activity Explorer can therefore show
`SHAREPOINT\system` for those label events. That path is still useful for seeding
files, but it is not the right source for high-fidelity user screenshots.

For user-attributed Activity Explorer events, generate activity from:

- Office apps or Office for the web signed in as the user.
- Endpoint DLP on an onboarded Windows 10/11 or supported virtual device.
- Browser actions in Edge, or Chrome/Firefox with the Purview extension where required.
- Outlook/Exchange user activity for mail scenarios.

## Admin Validation

Before running the endpoint persona script, validate these items:

1. Priya has a Windows 365 Cloud PC provisioned and assigned.
2. The Cloud PC is visible in Microsoft Intune.
3. The Cloud PC is onboarded for Microsoft Purview / Microsoft Defender for Endpoint.
4. Endpoint DLP is enabled and the device appears under Purview device onboarding.
5. Priya is in scope for the relevant DLP policies.
6. The policy includes audit or enforcement actions for:
   - File read
   - File created or modified
   - Copy to clipboard
   - Copy to network share
   - Print
   - Access by unallowed app
   - Browser paste or upload, if that scenario is being tested
7. Microsoft 365 Apps are installed and Priya can open Word and Excel.
8. Sensitivity labels are published to Priya if the scenario requires manual label
   apply/change/remove actions.

## Device Validation Commands

Run these commands inside Priya's Cloud PC.

```powershell
whoami
hostname
dsregcmd /status
Get-Service Sense
```

Expected result:

- `whoami` reflects Priya's signed-in context or the expected local account context.
- `dsregcmd /status` shows the device joined/registered correctly.
- `Get-Service Sense` exists and is running.

If `Sense` is missing or stopped, do not expect Endpoint DLP events yet.

## Run the First Endpoint Activity Test

Copy the repo or at least this script to Priya's Cloud PC:

```powershell
tools\Invoke-EndpointPersonaActivity.ps1
```

From the repo root inside Priya's Cloud PC, run:

```powershell
.\tools\Invoke-EndpointPersonaActivity.ps1 -Persona priya.sharma -Department "Data Science"
```

This creates local DOCX/XLSX files with synthetic sensitive data and copies
sensitive text to the clipboard.

If OneDrive for Business is signed in and syncing, test OneDrive file activity:

```powershell
.\tools\Invoke-EndpointPersonaActivity.ps1 -Persona priya.sharma -Department "Data Science" -CopyToOneDrive
```

If a network share exists, test copy-to-network-share:

```powershell
.\tools\Invoke-EndpointPersonaActivity.ps1 `
  -Persona priya.sharma `
  -Department "Data Science" `
  -NetworkSharePath "\\server\share\PurviewLab"
```

For browser paste and print scenarios:

```powershell
.\tools\Invoke-EndpointPersonaActivity.ps1 `
  -Persona priya.sharma `
  -Department "Data Science" `
  -OpenBrowserPasteTest `
  -OpenManualPrintTest
```

Then manually:

1. Paste the clipboard content into the browser text field.
2. In Word, print the opened document to Microsoft Print to PDF.

## Activity Explorer Validation

Wait 10-30 minutes, then check Activity Explorer with filters:

- User: Priya Sharma / `priya.sharma@...`
- Device name: Priya's Cloud PC name
- Location: Device
- Activity types:
  - File created
  - File modified
  - File read
  - File copied to clipboard
  - File copied to network share
  - File printed
  - Pasted to browser
  - Label applied / Label changed / Label removed, if manually performed in Office

If events do not appear:

1. Verify the device is listed in Purview device onboarding.
2. Verify Endpoint DLP policy sync status.
3. Confirm Priya and the device are in policy scope.
4. Confirm the file contains a SIT or sensitivity label targeted by the policy.
5. Confirm the app/action is supported by Endpoint DLP.
6. Give Activity Explorer more time; endpoint activity is not always immediate.

## Recommended Demo Model

Use both layers together:

| Layer | Purpose | Actor in Activity Explorer |
| --- | --- | --- |
| Azure Automation runbook | High-volume background activity, SharePoint files, mail, Teams, ADX storyline | Often service or API-attributed |
| Windows 365 endpoint persona | High-fidelity Activity Explorer screenshots | Signed-in user and Cloud PC |

Start with Priya. Once the pipeline is reliable, repeat with Ana and Laura.

## Edge Persona Browser Model

Microsoft Edge is the preferred browser for browser-based Purview demos. Endpoint
DLP can work natively with Edge for browser/domain restrictions, while Chrome and
Firefox require the Microsoft Purview extension on Windows.

The Edge model is useful for:

- Uploading sensitive files to restricted cloud service domains.
- Pasting sensitive content into browser sites.
- Printing web pages or sensitive files opened in the browser.
- Saving web pages locally.
- Copying content from browser pages.
- Testing allowed versus unallowed browser or service-domain behavior.

Run this from Priya's Cloud PC:

```powershell
.\tools\Invoke-EdgePersonaActivity.ps1 -Persona priya.sharma -Department "Data Science"
```

To open a specific upload target:

```powershell
.\tools\Invoke-EdgePersonaActivity.ps1 `
  -Persona priya.sharma `
  -Department "Data Science" `
  -UploadUrl "https://your-upload-target.example"
```

To use an existing Edge profile directory:

```powershell
.\tools\Invoke-EdgePersonaActivity.ps1 `
  -Persona priya.sharma `
  -EdgeProfileDirectory "Default" `
  -UploadUrl "https://your-upload-target.example"
```

To create an isolated demo profile:

```powershell
.\tools\Invoke-EdgePersonaActivity.ps1 `
  -Persona priya.sharma `
  -UseIsolatedProfile `
  -ProfileName "Priya-Purview-Demo"
```

Important attribution note:

Multiple Edge profiles can help simulate different web identities, but Endpoint
DLP device activity is still rooted in the signed-in Windows session and device.
For clean Activity Explorer screenshots per persona, prefer one Cloud PC or one
Windows sign-in context per persona. Use multiple Edge profiles for Priya's own
work contexts, not as a replacement for separate users when actor attribution is
critical.

Recommended first browser actions:

1. Open Edge through `Invoke-EdgePersonaActivity.ps1`.
2. Paste the clipboard content into the local test page.
3. Upload the generated CSV to a domain listed in a Purview sensitive service
   domain group.
4. Print the local test page to Microsoft Print to PDF.
5. Save the local test page as a local file.
6. Wait 10-30 minutes and check Activity Explorer for Priya and the Cloud PC.

For browser scenarios, verify Purview settings:

- Endpoint DLP settings include service domains or sensitive service domain groups.
- The DLP policy includes device location.
- The policy action audits or restricts browser upload, paste, print, or save.
- Edge is supported natively. Chrome/Firefox require the Purview browser extension.

## References

- Activity Explorer: https://learn.microsoft.com/en-us/purview/data-classification-activity-explorer
- Endpoint DLP getting started: https://learn.microsoft.com/en-us/purview/endpoint-dlp-getting-started
- Onboard Windows devices into Microsoft 365: https://learn.microsoft.com/en-au/purview/device-onboarding-overview
- Onboard Windows devices using a local script: https://learn.microsoft.com/en-us/purview/device-onboarding-script
- Learn about the Microsoft Purview extension for Chrome: https://learn.microsoft.com/en-us/purview/dlp-chrome-learn-about
- Configure Endpoint DLP settings: https://learn.microsoft.com/en-au/purview/dlp-configure-endpoint-settings
- Windows 365 Enterprise overview: https://learn.microsoft.com/en-us/windows-365/enterprise/overview
- Windows 365 requirements: https://learn.microsoft.com/windows-365/enterprise/requirements
