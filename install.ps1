Import-Module (Join-Path $PSScriptRoot 'AgentDoneToast.psm1') -Force
$report = Sync-AgentDoneToast -Mode Apply
foreach ($change in $report.Files) {
    Write-Output ("{0} {1}" -f $change.Outcome, $change.Path)
    if ($change.Outcome -eq [FileOutcome]::Conflict) {
        switch ($change.Conflict) {
            ForeignCodexNotify {
                Write-Output 'Codex config.toml already has a notify command. Left that command in place.'
            }
            UnreadableConfig {
                Write-Output 'A config file could not be parsed. Left that file in place.'
            }
            UnsupportedCursorHooksVersion {
                Write-Output 'Cursor hooks.json has a version other than 1. Left that file in place.'
            }
            default { throw "unknown conflict $($change.Conflict)" }
        }
    }
}
$conflicted = @($report.Files | Where-Object { $_.Outcome -eq [FileOutcome]::Conflict })
if ($conflicted.Count -gt 0) { exit 2 }
exit 0
