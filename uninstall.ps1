Import-Module (Join-Path $PSScriptRoot 'AgentDoneToast.psm1') -Force
$report = Sync-AgentDoneToast -Mode Remove
foreach ($change in $report.Files) {
    Write-Output ("{0} {1}" -f $change.Outcome, $change.Path)
}
exit 0
