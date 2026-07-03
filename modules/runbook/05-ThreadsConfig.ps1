# =============================================================================
# MULTI-TURN EMAIL CONVERSATIONS (loaded from config variable)
# =============================================================================
# Each thread simulates a realistic multi-message discussion where PII
# accumulates through replies and forwards. AI generates each message
# based on the previous one, creating natural conversation flow.
# Threads are defined in config/email-threads.json and stored as an
# Automation variable (AgentEmailThreads) by Deploy-Runbook.ps1.
$emailThreadsJson = Get-AutomationVariable -Name 'AgentEmailThreads' -ErrorAction SilentlyContinue
if ($emailThreadsJson) {
    $rawThreads = $emailThreadsJson | ConvertFrom-Json
    $threadList = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($t in $rawThreads) {
        $msgs = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($m in $t.messages) {
            $msgs.Add(@{ From=$m.from; To=$m.to; Instruction=$m.instruction })
        }
        $threadList.Add(@{ ThreadName=$t.threadName; Messages=$msgs.ToArray() })
    }
    $emailThreads = $threadList.ToArray()
} else {
    Write-Output "[WARN] AgentEmailThreads variable not found -- multi-turn threads disabled"
    $emailThreads = @()
}

