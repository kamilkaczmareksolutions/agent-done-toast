param(
    [Parameter(Mandatory = $true)]
    [string]$BindingId,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$PayloadArgument
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentDoneToast.psm1') -Force
$stdinText = [Console]::In.ReadToEnd()
$argumentText = ''
if ($PayloadArgument) { $argumentText = $PayloadArgument -join ' ' }
try {
    $null = Invoke-AgentDoneToast -BindingId $BindingId -StdinText $stdinText -ArgumentText $argumentText
}
catch {
    # A bug in the toast path must not block the agent or become a Stop decision.
}
exit 0
