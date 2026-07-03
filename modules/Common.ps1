<#PSScriptInfo

.VERSION 1.0.2

.GUID a0c76a45-5021-47b3-98a4-626b744a5f58

.AUTHOR
https://www.linkedin.com/in/profesorkaz/; Sebastian Zamorano
https://www.linkedin.com/in/mrnabster; Nabil Senoussaoui

.COMPANYNAME
ClaudIA - Cloud Activity, Usage & Data Intelligence Architecture

.COPYRIGHT
Copyright (c) ClaudIA contributors. All rights reserved.

.TAGS
ClaudIA PowerShell Automation Microsoft365 Azure Purview

.PROJECTURI
https://github.com/MH-Demos/ClaudIA

.DESCRIPTION
Common script

.RELEASENOTES
Version 1.0.2 adds partial deployment result status support.

#>

# Common.ps1 is now a FACADE: the shared kernel lives in the three part files
# below. Callers keep dot-sourcing this file exactly as before. Function
# placement: Core = pure helpers, Config = config/state, Azure = az/Graph/KV.
. (Join-Path $PSScriptRoot 'Common.Core.ps1')
. (Join-Path $PSScriptRoot 'Common.Config.ps1')
. (Join-Path $PSScriptRoot 'Common.Azure.ps1')

# Suppress az CLI WARNING chatter on stderr for every consumer of this facade.
# Under $ErrorActionPreference='Stop' (installer/modules), PowerShell 5.1 turns
# any redirected native stderr line into a TERMINATING error, so benign az
# warnings ('command group experimental', 'output includes credentials') killed
# real runs. Errors still surface normally.
if (-not $env:AZURE_CORE_ONLY_SHOW_ERRORS) { $env:AZURE_CORE_ONLY_SHOW_ERRORS = 'true' }
