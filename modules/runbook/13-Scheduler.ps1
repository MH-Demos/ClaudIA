# =============================================================================
# ACTIVITY SCHEDULER - random working hour simulation
# =============================================================================
function Get-RandomWorkSchedule {
    param([int]$StartHour, [int]$EndHour, [int]$FileCount, [int]$EmailCount)

    $activities = @()

    for ($i = 0; $i -lt $FileCount; $i++) {
        $maxH = [Math]::Max($StartHour + 1, $EndHour)
        $hour   = Get-Random -Minimum $StartHour -Maximum $maxH
        $minute = Get-Random -Minimum 0 -Maximum 60
        $activities += @{ Time = ($hour * 60 + $minute); Type = 'file'; Index = $i }
    }

    for ($i = 0; $i -lt $EmailCount; $i++) {
        $eMin = [Math]::Min($StartHour + 1, $EndHour - 1)
        $eMax = [Math]::Max($eMin + 1, $EndHour)
        $emailHour = Get-Random -Minimum $eMin -Maximum $eMax
        $minute    = Get-Random -Minimum 0 -Maximum 60
        $activities += @{ Time = ($emailHour * 60 + $minute); Type = 'email'; Index = $i }
    }

    $activities | Sort-Object { $_.Time }
}

function Get-DelaySeconds {
    param([int]$CurrentTimeMin, [int]$NextTimeMin)
    $diff = ($NextTimeMin - $CurrentTimeMin) * 60
    if ($diff -lt 3) { $diff = Get-Random -Minimum 3 -Maximum 15 }
    if ($diff -gt 60) { $diff = Get-Random -Minimum 10 -Maximum 60 }
    $diff
}

