# Runs the Pester suite in this folder for CI with Pester 5.7.1 (installed for
# the current user when missing) and fails unless every test passed.
# -PowerShellVersion: the version this pwsh must be, for a job that installs
# a given PowerShell and must not run the tests on another one.
param([string]$PowerShellVersion = '')
$ErrorActionPreference = 'Stop'
$ps = "$($PSVersionTable.PSVersion)"
if ($PowerShellVersion -and $ps -cne $PowerShellVersion) { throw "PowerShell is $ps, not $PowerShellVersion" }
$want = [version]'5.7.1'
function Find-Pester { Get-Module -ListAvailable Pester | Where-Object { $_.Version -eq $want } | Select-Object -First 1 }
$pester = Find-Pester
if (-not $pester) {
  if (Get-Command Install-Module -ErrorAction Ignore) { Install-Module Pester -RequiredVersion $want -Scope CurrentUser -Force -SkipPublisherCheck }
  else { Install-PSResource Pester -Version "$want" -Scope CurrentUser -TrustRepository -Quiet }
  $pester = Find-Pester
}
if (-not $pester) { throw "Pester $want is not installed" }
Import-Module $pester.Path -Force
Write-Host "PowerShell $ps on .NET $([Environment]::Version), Pester $($pester.Version)"
$cfg = New-PesterConfiguration
$cfg.Run.Path = $PSScriptRoot
$cfg.Run.PassThru = $true
$cfg.Output.Verbosity = 'Detailed'
# Test names and test output hold workflow command text on purpose, so on
# GitHub Actions the runner stops reading commands while Pester prints and
# resumes on a one-time token.
$stop = if ($env:GITHUB_ACTIONS -ceq 'true') { [guid]::NewGuid().ToString('N') }
if ($stop) { Write-Host "::stop-commands::$stop" }
try { $r = Invoke-Pester -Configuration $cfg }
finally { if ($stop) { Write-Host "::$($stop)::" } }
Write-Host "Pester: $($r.PassedCount) passed, $($r.FailedCount) failed, $($r.SkippedCount) skipped, $($r.NotRunCount) not run"
if ($r.Result -ne 'Passed' -or $r.PassedCount -lt 1) { throw "Pester: $($r.Result), $($r.FailedCount) failed, $($r.PassedCount) passed" }
