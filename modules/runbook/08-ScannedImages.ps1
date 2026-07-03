# =============================================================================
# SCANNED DOCUMENT IMAGE GENERATION (PNG with PII for OCR detection)
# Locale-aware: uses $locale for labels, PII formats, bank details, tax rates.
# =============================================================================
Add-Type -AssemblyName System.Drawing

function New-ScanImage {
    param([string]$Type, [string]$AgentName, [string]$Dept)
    $bmp = New-Object System.Drawing.Bitmap(850, 1100)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.TextRenderingHint = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::FromArgb(248, 245, 238))

    $titleFont  = New-Object System.Drawing.Font("Arial", 16, [System.Drawing.FontStyle]::Bold)
    $headerFont = New-Object System.Drawing.Font("Arial", 11, [System.Drawing.FontStyle]::Bold)
    $bodyFont   = New-Object System.Drawing.Font("Courier New", 10)
    $smallFont  = New-Object System.Drawing.Font("Arial", 8)
    $black = [System.Drawing.Brushes]::Black
    $gray  = [System.Drawing.Brushes]::DarkGray
    $red   = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(180, 0, 0))
    $pen   = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(200, 200, 200), 2)
    $g.DrawRectangle($pen, 30, 30, 790, 1040)

    # Locale-aware PII generation
    $sc = if ($locale -and $locale.scanTemplates) { $locale.scanTemplates } else { $null }
    $pii = if ($locale -and $locale.piiGenerators) { $locale.piiGenerators } else { $null }
    $cur = if ($locale) { $locale.currency } else { 'EUR' }
    $emailDom = if ($pii -and $pii.emailDomain) { $pii.emailDomain } else { 'corp.fr' }

    # Generate country-appropriate PII values
    switch ($country) {
        'US' {
            $idLabel = 'SSN'; $idValue = "$(Get-Random -Min 100 -Max 899)-$(Get-Random -Min 10 -Max 99)-$(Get-Random -Min 1000 -Max 9999)"
            $bankLabel = 'Routing'; $bankValue = "$(Get-Random -Min 100000000 -Max 999999999)"
            $bank2Label = 'Account'; $bank2Value = "$(Get-Random -Min 1000000000 -Max 9999999999)"
            $taxLabel = 'EIN'; $taxValue = "$(Get-Random -Min 10 -Max 99)-$(Get-Random -Min 1000000 -Max 9999999)"
            $phonePrefix = @('212','310','415','312') | Get-Random
            $phone = "($phonePrefix) $(Get-Random -Min 100 -Max 999)-$(Get-Random -Min 1000 -Max 9999)"
            $bankName = 'Chase Bank'; $bic = 'CHASUS33'; $taxRateLabel = 'Sales Tax'; $taxRate = 8.875; $supplierSuffix = 'LLC'
        }
        'UK' {
            $letters = 'ABCEGHJKLMNPRSTWXYZ'; $sl = $letters[(Get-Random -Max $letters.Length)]; $sl2 = $letters[(Get-Random -Max $letters.Length)]
            $idLabel = 'NI Number'; $idValue = "$sl$sl2 $(Get-Random -Min 10 -Max 99) $(Get-Random -Min 10 -Max 99) $(Get-Random -Min 10 -Max 99) $(@('A','B','C','D') | Get-Random)"
            $bankLabel = 'Sort Code'; $bankValue = "$(Get-Random -Min 10 -Max 99)-$(Get-Random -Min 10 -Max 99)-$(Get-Random -Min 10 -Max 99)"
            $bank2Label = 'Account'; $bank2Value = "$(Get-Random -Min 10000000 -Max 99999999)"
            $taxLabel = 'UTR'; $taxValue = "$(Get-Random -Min 1000000000 -Max 9999999999)"
            $phonePrefix = @('07700','07800') | Get-Random; $phone = "$phonePrefix $(Get-Random -Min 100000 -Max 999999)"
            $bankName = 'Barclays'; $bic = 'BARCGB22'; $taxRateLabel = 'VAT'; $taxRate = 20; $supplierSuffix = 'Ltd'
        }
        'DE' {
            $idLabel = 'Steuer-ID'; $idValue = -join ((0..10) | ForEach-Object { Get-Random -Min 0 -Max 10 })
            $deIban = -join ((0..17) | ForEach-Object { Get-Random -Min 0 -Max 10 })
            $bankLabel = 'IBAN'; $bankValue = "DE$($deIban.Substring(0,2)) $($deIban.Substring(2,4)) $($deIban.Substring(6,4)) $($deIban.Substring(10,4)) $($deIban.Substring(14,4))"
            $bank2Label = ''; $bank2Value = ''
            $taxLabel = 'SV-Nummer'; $taxValue = "$(Get-Random -Min 10 -Max 99) $(Get-Random -Min 100000 -Max 999999) $(Get-Random -Min 1 -Max 9)"
            $phonePrefix = @('0151','0160','0170') | Get-Random; $phone = "$phonePrefix $(Get-Random -Min 1000000 -Max 9999999)"
            $bankName = 'Deutsche Bank'; $bic = 'DEUTDEFF'; $taxRateLabel = 'MwSt'; $taxRate = 19; $supplierSuffix = 'GmbH'
        }
        default {
            # FR (default)
            $nirPrefix = @('1','2') | Get-Random; $nirBody = -join ((0..12) | ForEach-Object { Get-Random -Min 0 -Max 10 })
            $idLabel = 'NIR'; $idValue = "$nirPrefix $($nirBody.Substring(0,2)) $($nirBody.Substring(2,2)) $($nirBody.Substring(4,2)) $($nirBody.Substring(6,3)) $($nirBody.Substring(9,3)) $($nirBody.Substring(12,1))$(Get-Random -Min 10 -Max 99)"
            $ibanBody = -join ((0..19) | ForEach-Object { Get-Random -Min 0 -Max 10 })
            $bankLabel = 'IBAN'; $bankValue = "FR76 $($ibanBody.Substring(0,4)) $($ibanBody.Substring(4,4)) $($ibanBody.Substring(8,4)) $($ibanBody.Substring(12,4)) $($ibanBody.Substring(16,4))"
            $bank2Label = ''; $bank2Value = ''
            $taxLabel = 'N. Fiscal'; $taxValue = -join ((0..12) | ForEach-Object { Get-Random -Min 0 -Max 10 })
            $phonePrefix = @('06','07') | Get-Random; $phone = "$phonePrefix $(Get-Random -Min 10 -Max 99) $(Get-Random -Min 10 -Max 99) $(Get-Random -Min 10 -Max 99) $(Get-Random -Min 10 -Max 99)"
            $bankName = 'BNP Paribas'; $bic = 'BNPAFRPP'; $taxRateLabel = 'TVA'; $taxRate = 20; $supplierSuffix = 'SAS'
        }
    }

    $nameParts = $AgentName -split ' '
    $nom = if ($nameParts.Count -ge 2) { "$($nameParts[-1]), $($nameParts[0])" } else { $AgentName }
    $email = "$($nameParts[0].ToLower()[0])$($nameParts[-1].ToLower())@$emailDom"
    $date = Get-Date -Format 'MMMM yyyy'
    $salBrut = Get-Random -Min 2800 -Max 5500

    # Resolve scan type to generic category (locale scan types may have different names)
    $scanCategory = if ($Type -match 'Paie|Pay|Lohn|Payslip') { 'payslip' }
                    elseif ($Type -match 'Badge|Ausweis') { 'badge' }
                    elseif ($Type -match 'Facture|Invoice|Rechnung') { 'invoice' }
                    else { 'payslip' }

    $payslipTitle = if ($sc -and $sc.payslip) { $sc.payslip.title } else { 'PAYSLIP' }
    $badgeTitle   = if ($sc -and $sc.badge) { $sc.badge.title } else { 'EMPLOYEE BADGE' }
    $invoiceTitle = if ($sc -and $sc.invoice) { $sc.invoice.title } else { 'INVOICE' }

    switch ($scanCategory) {
        'payslip' {
            $g.DrawString($payslipTitle, $titleFont, $black, 250, 50)
            $g.DrawString("$date", $headerFont, $gray, 330, 80)
            $g.DrawLine($pen, 50, 110, 800, 110)
            $y = 130
            $g.DrawString("Name:         $nom", $bodyFont, $black, 60, $y); $y += 22
            $g.DrawString("Department:   $Dept", $bodyFont, $black, 60, $y); $y += 22
            $g.DrawString("${idLabel}:$((' ' * [Math]::Max(1, 14 - $idLabel.Length)))$idValue", $bodyFont, $black, 60, $y); $y += 22
            $g.DrawString("${taxLabel}:$((' ' * [Math]::Max(1, 14 - $taxLabel.Length)))$taxValue", $bodyFont, $black, 60, $y); $y += 22
            $g.DrawString("${bankLabel}:$((' ' * [Math]::Max(1, 14 - $bankLabel.Length)))$bankValue", $bodyFont, $black, 60, $y); $y += 22
            if ($bank2Label) { $g.DrawString("${bank2Label}:$((' ' * [Math]::Max(1, 14 - $bank2Label.Length)))$bank2Value", $bodyFont, $black, 60, $y); $y += 22 }
            $y += 10; $g.DrawLine($pen, 50, $y, 800, $y); $y += 15
            $g.DrawString("Gross:        $($salBrut.ToString('N2')) $cur", $bodyFont, $black, 60, $y); $y += 22
            $deductions = [Math]::Round($salBrut * 0.34, 2)
            $net = [Math]::Round($salBrut - $deductions, 2)
            $g.DrawString("Deductions:   -$($deductions.ToString('N2')) $cur", $bodyFont, $black, 60, $y); $y += 22
            $g.DrawString("Net Pay:      $($net.ToString('N2')) $cur", $bodyFont, $black, 60, $y); $y += 30
            $g.DrawString("Bank: $bankName | BIC: $bic", $bodyFont, $gray, 60, $y)
        }
        'badge' {
            $g.DrawString($badgeTitle, $titleFont, $red, 150, 50)
            $g.DrawLine($pen, 50, 90, 800, 90)
            $g.FillRectangle([System.Drawing.Brushes]::LightGray, 60, 120, 200, 250)
            $g.DrawString("PHOTO", $headerFont, $gray, 120, 230)
            $g.DrawRectangle($pen, 60, 120, 200, 250)
            $y = 130
            $g.DrawString("Name:    $nom", $bodyFont, $black, 290, $y); $y += 28
            $g.DrawString("Dept:    $Dept", $bodyFont, $black, 290, $y); $y += 28
            $g.DrawString("${idLabel}:$((' ' * [Math]::Max(1, 9 - $idLabel.Length)))$idValue", $bodyFont, $black, 290, $y); $y += 28
            $g.DrawString("${taxLabel}:$((' ' * [Math]::Max(1, 9 - $taxLabel.Length)))$taxValue", $bodyFont, $black, 290, $y); $y += 28
            $g.DrawString("${bankLabel}:$((' ' * [Math]::Max(1, 9 - $bankLabel.Length)))$bankValue", $bodyFont, $black, 290, $y); $y += 28
            $g.DrawString("Email:   $email", $bodyFont, $black, 290, $y); $y += 28
            $g.DrawString("Phone:   $phone", $bodyFont, $black, 290, $y)
        }
        'invoice' {
            $g.DrawString($invoiceTitle, $titleFont, $black, 330, 50)
            $g.DrawString("N. INV-2026-$(Get-Random -Min 1000 -Max 9999)", $headerFont, $gray, 280, 80)
            $g.DrawLine($pen, 50, 110, 800, 110)
            $y = 130
            $g.DrawString("$supplierSuffix TechServices | ${taxLabel}: $($taxRateLabel.Substring(0,2))$(Get-Random -Min 10 -Max 99) $(Get-Random -Min 100000000 -Max 999999999)", $bodyFont, $black, 60, $y); $y += 30
            $g.DrawString("TO: $nom | Dept: $Dept", $bodyFont, $black, 60, $y); $y += 30
            $g.DrawLine($pen, 50, $y, 800, $y); $y += 20
            $m1 = Get-Random -Min 500 -Max 5000; $m2 = Get-Random -Min 200 -Max 2000
            $g.DrawString("IT Consulting Services      $($m1.ToString('N2')) $cur", $bodyFont, $black, 60, $y); $y += 22
            $g.DrawString("Annual Software License     $($m2.ToString('N2')) $cur", $bodyFont, $black, 60, $y); $y += 30
            $total = $m1 + $m2; $tax = [Math]::Round($total * $taxRate / 100, 2)
            $g.DrawLine($pen, 50, $y, 800, $y); $y += 15
            $g.DrawString("Subtotal:   $($total.ToString('N2')) $cur", $bodyFont, $black, 400, $y); $y += 22
            $g.DrawString("$taxRateLabel ${taxRate}%:  $($tax.ToString('N2')) $cur", $bodyFont, $black, 400, $y); $y += 22
            $g.DrawString("TOTAL:      $([Math]::Round($total + $tax, 2).ToString('N2')) $cur", $headerFont, $black, 380, $y); $y += 40
            $g.DrawLine($pen, 50, $y, 800, $y); $y += 15
            $g.DrawString("${bankLabel}: $bankValue", $bodyFont, $black, 60, $y); $y += 22
            $g.DrawString("BIC: $bic", $bodyFont, $black, 60, $y)
        }
    }

    $g.DrawString("Scanned $(Get-Date -Format 'dd/MM/yyyy HH:mm')", $smallFont, $gray, 280, 1050)

    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bytes = $ms.ToArray()
    $g.Dispose(); $bmp.Dispose(); $ms.Dispose()
    return ,$bytes
}

