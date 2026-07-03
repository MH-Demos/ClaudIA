# =============================================================================
# AUTHENTICATION
# =============================================================================
function Get-ROPCToken {
    param([string]$Username, [string]$Password, [string]$TenantId, [string]$ClientId, [string]$ClientSecret)
    $Username = ConvertTo-AAPlainString $Username
    $Password = ConvertTo-AAPlainString $Password
    $TenantId = ConvertTo-AAPlainString $TenantId
    $ClientId = ConvertTo-AAPlainString $ClientId
    $ClientSecret = ConvertTo-AAPlainString $ClientSecret

    # Password grant still produces a delegated user token. .default consumes the
    # tenant-wide admin consent already granted to app-claudia-dataagent and avoids per-user
    # consent prompts that can happen with dynamic short scope names.
    $scopeAttempts = @(
        'https://graph.microsoft.com/.default',
        'openid offline_access Files.ReadWrite.All Sites.ReadWrite.All Mail.Send Chat.ReadWrite ChannelMessage.Send Team.ReadBasic.All Chat.Create User.Read'
    )
    $lastError = $null
    foreach ($scope in $scopeAttempts) {
        $body = @{
            grant_type    = 'password'
            client_id     = $ClientId
            client_secret = $ClientSecret
            username      = $Username
            password      = $Password
            scope         = $scope
        }
        $encodedBody = ($body.GetEnumerator() | ForEach-Object {
            '{0}={1}' -f [System.Net.WebUtility]::UrlEncode([string]$_.Key), [System.Net.WebUtility]::UrlEncode([string]$_.Value)
        }) -join '&'
        try {
            Write-Verbose "  [AUTH] Requesting ROPC token for $Username (client=$ClientId, scope=$scope, secretLength=$($ClientSecret.Length))"
            $resp = Invoke-RestMethod -Method POST `
                -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
                -ContentType 'application/x-www-form-urlencoded' -Body $encodedBody -ErrorAction Stop
            return $resp.access_token
        } catch {
            $lastError = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        }
    }
    throw "ROPC token request failed for $Username. $lastError"
}

function Get-OneLakeToken {
    param([string]$Username, [string]$Password, [string]$TenantId, [string]$ClientId, [string]$ClientSecret)
    # Separate ROPC token for OneLake (storage.azure.com audience)
    $Username = ConvertTo-AAPlainString $Username
    $Password = ConvertTo-AAPlainString $Password
    $TenantId = ConvertTo-AAPlainString $TenantId
    $ClientId = ConvertTo-AAPlainString $ClientId
    $ClientSecret = ConvertTo-AAPlainString $ClientSecret
    $body = @{
        grant_type    = 'password'
        client_id     = $ClientId
        client_secret = $ClientSecret
        username      = $Username
        password      = $Password
        scope         = 'https://storage.azure.com/.default'
    }
    $encodedBody = ($body.GetEnumerator() | ForEach-Object {
        '{0}={1}' -f [System.Net.WebUtility]::UrlEncode([string]$_.Key), [System.Net.WebUtility]::UrlEncode([string]$_.Value)
    }) -join '&'
    try {
        $resp = Invoke-RestMethod -Method POST `
            -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
            -ContentType 'application/x-www-form-urlencoded' -Body $encodedBody -ErrorAction Stop
        $resp.access_token
    } catch {
        $details = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        throw "OneLake token request failed for $Username. $details"
    }
}

function Write-OneLake {
    param([string]$Token, [string]$WorkspaceId, [string]$LakehouseId, [string]$Path, [byte[]]$Content)
    $baseUri = "https://onelake.dfs.fabric.microsoft.com/$WorkspaceId/$LakehouseId/Files/$Path"
    $headers = @{Authorization = "Bearer $Token"}
    # Step 1: Create file
    Invoke-RestMethod -Method PUT -Uri "$baseUri`?resource=file&overwrite=true" -Headers $headers -ContentType 'application/octet-stream' | Out-Null
    # Step 2: Append data
    Invoke-RestMethod -Method PATCH -Uri "$baseUri`?action=append&position=0" -Headers $headers -Body $Content -ContentType 'application/octet-stream' | Out-Null
    # Step 3: Flush
    Invoke-RestMethod -Method PATCH -Uri "$baseUri`?action=flush&position=$($Content.Length)" -Headers $headers | Out-Null
}

function ConvertTo-AASafeText {
    param([AllowNull()][string]$Text, [int]$MaxLength = 0)
    if ($null -eq $Text) { return '' }
    $clean = [regex]::Replace([string]$Text, '[\x00-\x08\x0B\x0C\x0E-\x1F]', ' ')
    # Azure OpenAI and Graph occasionally reject unpaired surrogate characters
    # produced by model output or copied source content.
    $clean = [regex]::Replace($clean, '[\uD800-\uDFFF]', '')
    if ($MaxLength -gt 0 -and $clean.Length -gt $MaxLength) {
        return $clean.Substring(0, $MaxLength)
    }
    return $clean
}

function ConvertTo-AAJsonBody {
    param([Parameter(Mandatory)]$Value, [int]$Depth = 20)
    $jsonParams = @{ Depth = $Depth; Compress = $true }
    if ((Get-Command ConvertTo-Json).Parameters.ContainsKey('EscapeHandling')) {
        $jsonParams.EscapeHandling = 'EscapeNonAscii'
    }
    $json = $Value | ConvertTo-Json @jsonParams
    return ,([System.Text.Encoding]::UTF8.GetBytes($json))
}

Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

function ConvertTo-AAXmlText {
    param([AllowNull()][string]$Text)
    return [System.Security.SecurityElement]::Escape((ConvertTo-AASafeText -Text $Text))
}

function Add-AAZipEntry {
    param(
        [System.IO.Compression.ZipArchive]$Archive,
        [string]$Name,
        [string]$Content
    )
    $entry = $Archive.CreateEntry($Name)
    $stream = $entry.Open()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Content)
        $stream.Write($bytes, 0, $bytes.Length)
    }
    finally {
        $stream.Dispose()
    }
}

function New-AADocxBytes {
    param([string]$Title, [string]$Content)
    $path = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "aa-$([guid]::NewGuid().ToString('N')).docx")
    try {
        $archive = [System.IO.Compression.ZipFile]::Open($path, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            Add-AAZipEntry -Archive $archive -Name '[Content_Types].xml' -Content '<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>'
            Add-AAZipEntry -Archive $archive -Name '_rels/.rels' -Content '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>'
            $paragraphs = [System.Collections.Generic.List[string]]::new()
            $paragraphs.Add("<w:p><w:r><w:t>$(ConvertTo-AAXmlText -Text $Title)</w:t></w:r></w:p>") | Out-Null
            foreach ($line in @($Content -split "`r?`n")) {
                $paragraphs.Add("<w:p><w:r><w:t>$(ConvertTo-AAXmlText -Text $line)</w:t></w:r></w:p>") | Out-Null
            }
            $documentXml = '<?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>' + ($paragraphs -join '') + '<w:sectPr/></w:body></w:document>'
            Add-AAZipEntry -Archive $archive -Name 'word/document.xml' -Content $documentXml
        }
        finally {
            $archive.Dispose()
        }
        return ,[System.IO.File]::ReadAllBytes($path)
    }
    finally {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

function New-AAXlsxBytes {
    param([string]$Title, [string]$Content)
    $path = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "aa-$([guid]::NewGuid().ToString('N')).xlsx")
    try {
        $archive = [System.IO.Compression.ZipFile]::Open($path, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            Add-AAZipEntry -Archive $archive -Name '[Content_Types].xml' -Content '<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>'
            Add-AAZipEntry -Archive $archive -Name '_rels/.rels' -Content '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>'
            Add-AAZipEntry -Archive $archive -Name 'xl/_rels/workbook.xml.rels' -Content '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>'
            Add-AAZipEntry -Archive $archive -Name 'xl/workbook.xml' -Content '<?xml version="1.0" encoding="UTF-8"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="AgentData" sheetId="1" r:id="rId1"/></sheets></workbook>'
            $rows = [System.Collections.Generic.List[string]]::new()
            $rowIndex = 1
            # Detect the dominant delimiter once: splitting on [,;] per line used
            # to break semicolon CSVs whose values contain commas (French decimals
            # like "45 000,00" or addresses), splitting SIT values apart and
            # weakening keyword-proximity detection.
            $delimiter = ';'
            $firstDataLine = @($Content -split "`r?`n" | Where-Object { $_ -match '\S' } | Select-Object -First 1)
            if (-not $firstDataLine -or ([string]$firstDataLine).IndexOf(';') -lt 0) { $delimiter = ',' }
            foreach ($line in @($Content -split "`r?`n" | Select-Object -First 80)) {
                $columns = @($line -split [regex]::Escape($delimiter) | Select-Object -First 12)
                if ($columns.Count -eq 0) { $columns = @($line) }
                $cells = [System.Collections.Generic.List[string]]::new()
                for ($i = 0; $i -lt $columns.Count; $i++) {
                    $colName = [char](65 + $i)
                    $cells.Add("<c r=`"$colName$rowIndex`" t=`"inlineStr`"><is><t>$(ConvertTo-AAXmlText -Text $columns[$i])</t></is></c>") | Out-Null
                }
                $rows.Add("<row r=`"$rowIndex`">$($cells -join '')</row>") | Out-Null
                $rowIndex++
            }
            if ($rows.Count -eq 0) {
                $rows.Add('<row r="1"><c r="A1" t="inlineStr"><is><t>Empty</t></is></c></row>') | Out-Null
            }
            $sheetXml = '<?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>' + ($rows -join '') + '</sheetData></worksheet>'
            Add-AAZipEntry -Archive $archive -Name 'xl/worksheets/sheet1.xml' -Content $sheetXml
        }
        finally {
            $archive.Dispose()
        }
        return ,[System.IO.File]::ReadAllBytes($path)
    }
    finally {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

function Test-AASensitivityLabelSupportedExtension {
    param([string]$Extension)
    return @('.docx','.xlsx','.pptx','.pdf') -contains ([string]$Extension).ToLowerInvariant()
}

function ConvertTo-AALabelFriendlyFile {
    param(
        [string]$Type,
        [string]$Extension,
        [string]$Content,
        [byte[]]$Bytes
    )
    $ext = ([string]$Extension).ToLowerInvariant()
    if (Test-AASensitivityLabelSupportedExtension -Extension $ext) {
        return @{ Ext = $ext; Bytes = $Bytes; Content = $Content; Converted = $false; OriginalExt = $ext }
    }

    $safeContent = if ([string]::IsNullOrWhiteSpace($Content)) {
        "Generated lab document for $Type.`nSSN social security number: 384-29-5187`nRouting number: 021000021`nAccount number: 492017388201"
    } else {
        $Content
    }

    if ($ext -eq '.csv') {
        return @{ Ext = '.xlsx'; Bytes = (New-AAXlsxBytes -Title $Type -Content $safeContent); Content = $safeContent; Converted = $true; OriginalExt = $ext }
    }

    return @{ Ext = '.docx'; Bytes = (New-AADocxBytes -Title $Type -Content $safeContent); Content = $safeContent; Converted = $true; OriginalExt = $ext }
}

function Invoke-Graph {
    param([string]$Token, [string]$Method = 'GET', [string]$Uri, $Body, [string]$ContentType = 'application/json')
    $headers = @{ Authorization = "Bearer $Token"; 'Content-Type' = $ContentType }
    $params  = @{ Method = $Method; Uri = $Uri; Headers = $headers; ContentType = $ContentType }
    if ($Body) {
        if ($Body -is [byte[]]) { $params.Body = $Body }
        elseif ($Body -is [string]) { $params.Body = [System.Text.Encoding]::UTF8.GetBytes($Body) }
        else { $params.Body = ConvertTo-AAJsonBody -Value $Body -Depth 20 }
    }
    $maxAttempts = 4
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            return Invoke-RestMethod @params
        } catch {
            $statusCode = 0
            try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { $statusCode = 0 }
            if ($statusCode -eq 429) {
                # Record throttling in script scope so the main loop can slow the
                # aggregate request rate (per-request retries alone keep hammering
                # Graph and cascade 429s into the next agents).
                $script:graphThrottle429Count++
                $script:graphLastThrottleAt = Get-Date
            }
            $retryable = $statusCode -in @(429, 502, 503, 504)
            if ($retryable -and $attempt -lt $maxAttempts) {
                $delay = [math]::Pow(2, $attempt)  # 2s, 4s, 8s
                $retryAfter = $null
                try { $retryAfter = $_.Exception.Response.Headers.GetValues('Retry-After') | Select-Object -First 1 } catch { $retryAfter = $null }
                $retryAfterSeconds = 0
                if ($retryAfter -and [int]::TryParse([string]$retryAfter, [ref]$retryAfterSeconds)) { $delay = [math]::Max($retryAfterSeconds, $delay) }
                Write-Verbose "  [GRAPH] $Method $Uri returned $statusCode - retry $attempt/$($maxAttempts - 1) in ${delay}s"
                Start-Sleep -Seconds $delay
                continue
            }
            $details = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
            throw "Graph $Method $Uri failed. $details"
        }
    }
}

function Get-GraphErrorDetails {
    param($ErrorRecord)
    if ($ErrorRecord.ErrorDetails.Message) { return $ErrorRecord.ErrorDetails.Message }
    return $ErrorRecord.Exception.Message
}

function Get-GraphContentBytes {
    param([string]$Token, [string]$Uri)
    $headers = @{ Authorization = "Bearer $Token" }
    try {
        $response = Invoke-WebRequest -Method GET -Uri $Uri -Headers $headers -ErrorAction Stop
        return $response.RawContentStream.ToArray()
    }
    catch {
        throw "Graph GET $Uri failed. $(Get-GraphErrorDetails -ErrorRecord $_)"
    }
}

function Push-FileOperationActivity {
    param(
        [string]$AgentUPN,
        [string]$AgentName,
        [string]$Department,
        [string]$Action,
        [string]$TargetName,
        [string]$TargetPath,
        [string]$TargetType = 'File',
        [string]$Outcome = 'Success',
        [string]$ErrorMessage = '',
        [hashtable]$ExtraProperties = @{}
    )

    $props = @{
        Service = 'SharePoint Online'
        Workload = 'SPO'
        Action = $Action
        TargetName = $TargetName
        TargetType = $TargetType
        TargetPath = $TargetPath
        Outcome = $Outcome
        ErrorMessage = $ErrorMessage
        ActivityExplorerComplexity = 'Low'
        ActivityExplorerTarget = $true
    }
    foreach ($key in $ExtraProperties.Keys) {
        if (-not [string]::IsNullOrWhiteSpace([string]$key)) { $props[$key] = $ExtraProperties[$key] }
    }

    Push-AgentActivity -AgentUPN $AgentUPN -AgentName $AgentName -Department $Department `
        -ActivityType 'activity_explorer' -Detail "$Action | $TargetPath" `
        -Properties $props
}

function Invoke-ActivityExplorerFileSignals {
    param(
        [string]$Token,
        [string]$SiteId,
        $Agent,
        [string]$AgentUPN,
        $SourceItem,
        [string]$SourceFileName,
        [string]$SourcePath,
        [string]$Folder,
        [byte[]]$SourceBytes,
        [string]$TimeStr
    )

    if (-not $SourceItem -or -not $SourceItem.id -or -not $SiteId) { return }
    if (-not (Test-ServiceRequested -Aliases @('spo','sharepoint','sharepoint online','files','fileops','activity explorer','activityexplorer','audit'))) { return }

    $sourceItemId = $SourceItem.id
    $targetType = if ($SourceFileName -like '*.png') { 'Image' } else { 'File' }

    try {
        Invoke-Graph -Token $Token -Uri "https://graph.microsoft.com/v1.0/sites/$SiteId/drive/items/$sourceItemId" | Out-Null
        Write-Output "    [$TimeStr] File read: $SourcePath"
        Push-FileOperationActivity -AgentUPN $AgentUPN -AgentName $Agent.Name -Department $Agent.Dept `
            -Action 'FileRead' -TargetName $SourceFileName -TargetPath $SourcePath -TargetType $targetType
        $script:totalFileOps++
    }
    catch {
        Push-FileOperationActivity -AgentUPN $AgentUPN -AgentName $Agent.Name -Department $Agent.Dept `
            -Action 'FileRead' -TargetName $SourceFileName -TargetPath $SourcePath -TargetType $targetType `
            -Outcome 'Failed' -ErrorMessage (Get-GraphErrorDetails -ErrorRecord $_)
    }

    try {
        $downloadBytes = Get-GraphContentBytes -Token $Token -Uri "https://graph.microsoft.com/v1.0/sites/$SiteId/drive/items/$sourceItemId/content"
        Write-Output "    [$TimeStr] File downloaded: $SourcePath ($($downloadBytes.Length) bytes)"
        Push-FileOperationActivity -AgentUPN $AgentUPN -AgentName $Agent.Name -Department $Agent.Dept `
            -Action 'DownloadFile' -TargetName $SourceFileName -TargetPath $SourcePath -TargetType $targetType `
            -ExtraProperties @{ DownloadedBytes = $downloadBytes.Length }
        $script:totalFileOps++
    }
    catch {
        Push-FileOperationActivity -AgentUPN $AgentUPN -AgentName $Agent.Name -Department $Agent.Dept `
            -Action 'DownloadFile' -TargetName $SourceFileName -TargetPath $SourcePath -TargetType $targetType `
            -Outcome 'Failed' -ErrorMessage (Get-GraphErrorDetails -ErrorRecord $_)
    }

    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $suffix = Get-Random -Minimum 100 -Maximum 999
    $noteName = "ActivityExplorer_Note_${stamp}_${suffix}.txt"
    $notePath = "$Folder/$noteName"
    $noteText = @"
Activity Explorer simulation note
Actor: $($Agent.Name) <$AgentUPN>
Source file: $SourcePath
Purpose: Generate low-complexity SharePoint upload/text activity for Purview Activity Explorer validation.
Sensitive sample: SSN 384-29-5187; routing 021000021; employee id EMP-$(Get-Random -Minimum 10000 -Maximum 99999)
"@

    try {
        $noteBytes = [System.Text.Encoding]::UTF8.GetBytes($noteText)
        $noteItem = Invoke-Graph -Token $Token -Method PUT `
            -Uri "https://graph.microsoft.com/v1.0/sites/$SiteId/drive/root:/$notePath`:/content" `
            -Body $noteBytes -ContentType 'text/plain'
        Write-Output "    [$TimeStr] Upload text: $notePath"
        Push-FileOperationActivity -AgentUPN $AgentUPN -AgentName $Agent.Name -Department $Agent.Dept `
            -Action 'UploadText' -TargetName $noteName -TargetPath $notePath -TargetType 'Text'
        Push-FileOperationActivity -AgentUPN $AgentUPN -AgentName $Agent.Name -Department $Agent.Dept `
            -Action 'FileCreated' -TargetName $noteName -TargetPath $notePath -TargetType 'Text'
        $script:totalFileOps += 2

        $modifiedText = $noteText + "`nReview status: modified during simulated daily work."
        $modifiedBytes = [System.Text.Encoding]::UTF8.GetBytes($modifiedText)
        Invoke-Graph -Token $Token -Method PUT `
            -Uri "https://graph.microsoft.com/v1.0/sites/$SiteId/drive/items/$($noteItem.id)/content" `
            -Body $modifiedBytes -ContentType 'text/plain' | Out-Null
        Write-Output "    [$TimeStr] File modified: $notePath"
        Push-FileOperationActivity -AgentUPN $AgentUPN -AgentName $Agent.Name -Department $Agent.Dept `
            -Action 'FileModified' -TargetName $noteName -TargetPath $notePath -TargetType 'Text'
        $script:totalFileOps++
    }
    catch {
        Push-FileOperationActivity -AgentUPN $AgentUPN -AgentName $Agent.Name -Department $Agent.Dept `
            -Action 'UploadText' -TargetName $noteName -TargetPath $notePath -TargetType 'Text' `
            -Outcome 'Failed' -ErrorMessage (Get-GraphErrorDetails -ErrorRecord $_)
    }

    $scratchName = "ActivityExplorer_WorkingCopy_${stamp}_$(Get-Random -Minimum 100 -Maximum 999).txt"
    $renamedScratchName = "ActivityExplorer_Renamed_${stamp}_$(Get-Random -Minimum 100 -Maximum 999).txt"
    $scratchPath = "$Folder/$scratchName"
    $renamedScratchPath = "$Folder/$renamedScratchName"
    $scratchContent = if ($SourceBytes -and $SourceBytes.Length -gt 0) {
        $SourceBytes
    } else {
        [System.Text.Encoding]::UTF8.GetBytes("Working copy generated by $($Agent.Name) for Activity Explorer simulation.")
    }

    try {
        $scratchItem = Invoke-Graph -Token $Token -Method PUT `
            -Uri "https://graph.microsoft.com/v1.0/sites/$SiteId/drive/root:/$scratchPath`:/content" `
            -Body $scratchContent -ContentType 'application/octet-stream'
        Write-Output "    [$TimeStr] File created: $scratchPath"
        Push-FileOperationActivity -AgentUPN $AgentUPN -AgentName $Agent.Name -Department $Agent.Dept `
            -Action 'FileCreated' -TargetName $scratchName -TargetPath $scratchPath
        $script:totalFileOps++

        $renamedItem = Invoke-Graph -Token $Token -Method PATCH `
            -Uri "https://graph.microsoft.com/v1.0/sites/$SiteId/drive/items/$($scratchItem.id)" `
            -Body @{ name = $renamedScratchName }
        Write-Output "    [$TimeStr] File renamed: $scratchName -> $renamedScratchName"
        Push-FileOperationActivity -AgentUPN $AgentUPN -AgentName $Agent.Name -Department $Agent.Dept `
            -Action 'FileRenamed' -TargetName $renamedScratchName -TargetPath $renamedScratchPath `
            -ExtraProperties @{ PreviousTargetName = $scratchName; PreviousTargetPath = $scratchPath }
        $script:totalFileOps++

        Invoke-Graph -Token $Token -Method DELETE `
            -Uri "https://graph.microsoft.com/v1.0/sites/$SiteId/drive/items/$($renamedItem.id)" | Out-Null
        Write-Output "    [$TimeStr] File deleted: $renamedScratchPath"
        Push-FileOperationActivity -AgentUPN $AgentUPN -AgentName $Agent.Name -Department $Agent.Dept `
            -Action 'FileDeleted' -TargetName $renamedScratchName -TargetPath $renamedScratchPath
        $script:totalFileOps++
    }
    catch {
        Push-FileOperationActivity -AgentUPN $AgentUPN -AgentName $Agent.Name -Department $Agent.Dept `
            -Action 'FileLifecycleSimulation' -TargetName $scratchName -TargetPath $scratchPath `
            -Outcome 'Failed' -ErrorMessage (Get-GraphErrorDetails -ErrorRecord $_)
    }
}

