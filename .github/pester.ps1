$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$found = @(Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version.Major -eq 5 })
if ($found.Count -eq 0) {
    $nuget = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
    if (-not $nuget) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
    }
    Install-Module -Name Pester -MinimumVersion 5.0.0 -MaximumVersion 5.99.99 -Force -Scope CurrentUser -SkipPublisherCheck
}
Import-Module -Name Pester -MinimumVersion 5.0.0 -MaximumVersion 5.99.99 -Force
Invoke-Pester -Path ./tests -CI
