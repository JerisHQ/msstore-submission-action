# Pester 5 tests for action.yml: static checks on its steps, and the check
# and package steps run as written (the Store API steps are run as written
# against the fake Store in MsStoreRunner.Tests.ps1, "HTTP path").
# Run: Invoke-Pester -Path scripts/tests -Output Detailed

BeforeAll {
  Import-Module (Join-Path $PSScriptRoot 'ActionSteps.psm1') -Force
  $script:Root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..' '..')).Path
  $script:Yaml = Get-ActionLines
  $script:StoreSteps = 'submit', 'read-back', 'diagnose', 'delete-draft'
  $script:Identity = 'Contoso.ExampleApp'
  $script:Publisher = 'CN=00000000-0000-0000-0000-000000000000'
  $script:MakePackage = Join-Path $PSScriptRoot 'New-TestMsixUpload.ps1'

  # Runs a step script as GitHub's pwsh shell does ($ErrorActionPreference
  # Stop), from the repository root, with ACTION_PATH set to it, the given
  # environment variables, and GITHUB_OUTPUT and GITHUB_STEP_SUMMARY in a
  # new folder. Returns Err (the error, '' when none), Out (every stream),
  # Output and Summary (what the step wrote to those files).
  function script:Invoke-Step([string]$Id, [hashtable]$StepEnv) {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('step-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $dir | Out-Null
    $files = @{ GITHUB_OUTPUT = (Join-Path $dir 'output'); GITHUB_STEP_SUMMARY = (Join-Path $dir 'summary') }
    foreach ($f in $files.Values) { New-Item -ItemType File $f | Out-Null }
    $all = @{ ACTION_PATH = $Root } + $files + $StepEnv
    $saved = @{}; foreach ($n in $all.Keys) { $saved[$n] = [Environment]::GetEnvironmentVariable($n) }
    $global:StepScript = Get-ActionStepScript $Id
    $err = ''; $out = ''
    Push-Location $Root
    try {
      foreach ($n in $all.Keys) { [Environment]::SetEnvironmentVariable($n, $all[$n]) }
      try {
        $out = & { $ErrorActionPreference = 'Stop'; . ([scriptblock]::Create($global:StepScript)) } *>&1 | Out-String
      } catch { $err = "$_" }
    } finally {
      Pop-Location
      foreach ($n in $all.Keys) { [Environment]::SetEnvironmentVariable($n, $saved[$n]) }
      Remove-Variable -Name StepScript -Scope Global -ErrorAction SilentlyContinue
    }
    $r = [pscustomobject]@{
      Err = $err; Out = $out
      Output = @(Get-Content -LiteralPath $files.GITHUB_OUTPUT)
      Summary = (Get-Content -Raw -LiteralPath $files.GITHUB_STEP_SUMMARY)
    }
    Remove-Item -LiteralPath $dir -Recurse -Force
    $r
  }
}

Describe 'action.yml (static checks)' {
  It 'is a composite action whose steps are, in order: <Want>' -ForEach @(@{ Want = 'check, package, submit, read-back, diagnose, delete-draft' }) {
    ($Yaml -ceq '  using: composite').Count | Should -Be 1
    (Get-ActionStepIds) -join ', ' | Should -BeExactly $Want
  }
  It 'runs every step in pwsh' {
    foreach ($id in Get-ActionStepIds) { Get-ActionStepKey $id 'shell' | Should -BeExactly 'pwsh' -Because "step $id" }
  }
  It 'runs each step only in its modes: <Id>' -ForEach @(
    @{ Id = 'check'; If = '' }
    @{ Id = 'package'; If = "inputs.mode == 'inspect' || inputs.mode == 'publish'" }
    @{ Id = 'submit'; If = "inputs.mode == 'publish'" }
    @{ Id = 'read-back'; If = "inputs.mode == 'publish'" }
    @{ Id = 'diagnose'; If = "inputs.mode == 'diagnose'" }
    @{ Id = 'delete-draft'; If = "inputs.mode == 'delete-draft'" }
  ) {
    Get-ActionStepKey $Id 'if' | Should -BeExactly $If
  }
  # An expression in a run: script is pasted into the script before it runs
  # (script injection); in env: it is only a value.
  It 'puts expressions only in env values and output values, never in a run: script' {
    $bad = for ($i = 0; $i -lt $Yaml.Count; $i++) {
      $l = $Yaml[$i]
      if ($l -notmatch '\$\{\{') { continue }
      if ($l -cmatch '^        [A-Z0-9_]+: \$\{\{ (inputs\.[a-z0-9-]+|github\.action_path|steps\.(package|submit)\.outputs\.[a-z0-9_]+) \}\}$') { continue }
      if ($l -cmatch '^    value: \$\{\{ steps\.(package|submit)\.outputs\.[a-z0-9_]+ \}\}$') { continue }
      "line $($i + 1): $l"
    }
    @($bad) | Should -BeNullOrEmpty
    foreach ($id in Get-ActionStepIds) { Get-ActionStepScript $id | Should -Not -Match '\$\{\{' -Because "step $id" }
  }
  It 'uses every input it declares, and declares every input it uses' {
    $at = [array]::IndexOf($Yaml, 'inputs:'); $end = [array]::IndexOf($Yaml, 'outputs:')
    $declared = @($Yaml[($at + 1)..($end - 1)] | Where-Object { $_ -cmatch '^  [a-z0-9-]+:$' } | ForEach-Object { $_.Trim().TrimEnd(':') })
    $used = @(([regex]::Matches(($Yaml -join "`n"), 'inputs\.([a-z0-9-]+)')) | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    $declared.Count | Should -BeGreaterThan 10
    @($declared | Sort-Object) | Should -Be @($used)
  }
  It 'never runs the Store CLI or another HTTP client, and never passes the test-only parameters' {
    $text = ($Yaml | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    $text | Should -Not -Match '(?i)\bmsstore\b|Invoke-WebRequest|Invoke-RestMethod|\bcurl\b|\bwget\b|HttpClient'
    $text | Should -Not -Match '-ApiBase|-AuthorityHost|-LoopbackTestServer'
  }
  It 'gives the Partner Center credentials only to the check step and the steps that sign in' {
    foreach ($id in Get-ActionStepIds) {
      $envMap = Get-ActionStepEnv $id
      $script = Get-ActionStepScript $id
      $hasCreds = @('PC_TENANT_ID', 'PC_CLIENT_ID', 'PC_CLIENT_SECRET' | Where-Object { $envMap.Contains($_) }).Count
      if ($id -cin $StoreSteps) {
        $hasCreds | Should -Be 3 -Because "step $id signs in"
        $envMap['PC_CLIENT_SECRET'] | Should -BeExactly '${{ inputs.client-secret }}'
        ([regex]::Matches($script, 'Connect-StoreApi ')).Count | Should -Be 1 -Because "step $id signs in once"
      } elseif ($id -ceq 'check') {
        $hasCreds | Should -Be 3
        $script | Should -Not -Match 'Connect-StoreApi|Import-Module|Write-Host' -Because 'the check step only checks presence'
      } else {
        $hasCreds | Should -Be 0 -Because "step $id does not sign in"
        $script | Should -Not -Match 'Connect-StoreApi'
      }
    }
  }
  It 'imports the module from the action path in every step that uses it' {
    foreach ($id in 'package', 'submit', 'read-back', 'diagnose', 'delete-draft') {
      (Get-ActionStepEnv $id)['ACTION_PATH'] | Should -BeExactly '${{ github.action_path }}'
      Get-ActionStepScript $id | Should -Match ([regex]::Escape("Import-Module (Join-Path `$env:ACTION_PATH 'scripts' 'MsStoreRunner.psm1')"))
    }
  }
  It 'sets the submit deadline first, then signs in, then publishes once with that deadline' {
    $code = @((Get-ActionStepScript 'submit') -split "`n" | Where-Object { $_.Trim() -and $_ -notmatch '^\s*#' })
    $code[0] | Should -BeExactly '$deadline = [DateTime]::UtcNow.AddMinutes([int]$env:SUBMIT_MINUTES)'
    $code[1] | Should -Match '^Import-Module '
    $code[2] | Should -Match '^Connect-StoreApi '
    $code[3] | Should -Match '^\$id = Publish-StoreSubmission .* -DeadlineUtc \$deadline$'
    @($code | Where-Object { $_ -match 'Publish-StoreSubmission' }).Count | Should -Be 1
    $code[-1] | Should -BeExactly '"submission_id=$id" >> $env:GITHUB_OUTPUT'
  }
  It 'reads back the id the submit step wrote, with the version and file name the package step read' {
    $e = Get-ActionStepEnv 'read-back'
    $e['SUBMISSION_ID'] | Should -BeExactly '${{ steps.submit.outputs.submission_id }}'
    $e['EXPECTED_VERSION'] | Should -BeExactly '${{ steps.package.outputs.version }}'
    $e['PKG_NAME'] | Should -BeExactly '${{ steps.package.outputs.file_name }}'
    $s = Get-ActionStepEnv 'submit'
    $s['PKG_FILE'] | Should -BeExactly '${{ steps.package.outputs.file }}'
    $s['EXPECTED_VERSION'] | Should -BeExactly '${{ steps.package.outputs.version }}'
    Get-ActionStepScript 'read-back' | Should -Match 'Assert-SubmissionHasPackage -ProductId \$env:STORE_PRODUCT_ID -SubmissionId \$env:SUBMISSION_ID '
  }
  It 'checks the submission id before the sign-in in step <Id>' -ForEach @(@{ Id = 'diagnose' }, @{ Id = 'delete-draft' }) {
    $code = @((Get-ActionStepScript $Id) -split "`n" | Where-Object { $_.Trim() -and $_ -notmatch '^\s*#' })
    $check = [array]::IndexOf($code, "if (`$env:SUBMISSION_ID -cnotmatch '^[0-9]{1,20}\z') { throw 'submission-id must be a number' }")
    $check | Should -BeGreaterOrEqual 0
    $check | Should -BeLessThan ([array]::IndexOf(@($code | ForEach-Object { $_ -match '^Import-Module ' }), $true))
  }
}

Describe 'action.yml check step' {
  BeforeAll {
    $script:Ok = @{ MODE = 'publish'; STORE_PRODUCT_ID = '9TESTAPP0001'; PACKAGE_DIR = 'pkg'; EXPECTED_IDENTITY_NAME = $Identity; EXPECTED_PUBLISHER = $Publisher
      PC_TENANT_ID = 'tenant-1'; PC_CLIENT_ID = 'client-1'; PC_CLIENT_SECRET = 'dummy-client-secret-Zx9'
      SUBMIT_MINUTES = '18'; READ_BACK_MINUTES = '30'; READ_BACK_INTERVAL_SECONDS = '60'; DELETE_MINUTES = '4' }
  }
  It 'passes the defaults for mode=<Mode>' -ForEach @(@{ Mode = 'inspect' }, @{ Mode = 'publish' }, @{ Mode = 'diagnose' }, @{ Mode = 'delete-draft' }) {
    $e = $Ok.Clone(); $e.MODE = $Mode
    if ($Mode -ceq 'inspect') { foreach ($n in 'STORE_PRODUCT_ID', 'PC_TENANT_ID', 'PC_CLIENT_ID', 'PC_CLIENT_SECRET') { $e[$n] = '' } }
    if ($Mode -cin 'diagnose', 'delete-draft') { foreach ($n in 'PACKAGE_DIR', 'EXPECTED_IDENTITY_NAME', 'EXPECTED_PUBLISHER') { $e[$n] = '' } }
    $r = Invoke-Step 'check' $e
    $r.Err | Should -BeNullOrEmpty
    $r.Out | Should -BeNullOrEmpty
  }
  It 'stops when <Case>' -ForEach @(
    @{ Case = 'the mode is unknown'; Set = @{ MODE = 'Publish' }; Err = 'mode must be one of: inspect, publish, diagnose, delete-draft' }
    @{ Case = 'the mode is empty'; Set = @{ MODE = '' }; Err = 'mode must be one of: inspect, publish, diagnose, delete-draft' }
    @{ Case = 'submit-minutes is below 8'; Set = @{ SUBMIT_MINUTES = '7' }; Err = 'submit-minutes must be a whole number from 8 to 120' }
    @{ Case = 'submit-minutes is not a number'; Set = @{ SUBMIT_MINUTES = '18; exit 0' }; Err = 'submit-minutes must be a whole number from 8 to 120' }
    @{ Case = 'read-back-minutes is negative'; Set = @{ READ_BACK_MINUTES = '-1' }; Err = 'read-back-minutes must be a whole number from 0 to 240' }
    @{ Case = 'the read-back interval is 0'; Set = @{ READ_BACK_INTERVAL_SECONDS = '0' }; Err = 'read-back-interval-seconds must be a whole number from 5 to 600' }
    @{ Case = 'delete-minutes is too large'; Set = @{ DELETE_MINUTES = '31' }; Err = 'delete-minutes must be a whole number from 1 to 30' }
    @{ Case = 'publish has no package-dir'; Set = @{ PACKAGE_DIR = '' }; Err = 'mode=publish needs package-dir, identity-name and publisher' }
    @{ Case = 'inspect has no publisher'; Set = @{ MODE = 'inspect'; EXPECTED_PUBLISHER = '' }; Err = 'mode=inspect needs package-dir, identity-name and publisher' }
    @{ Case = 'diagnose has no product-id'; Set = @{ MODE = 'diagnose'; STORE_PRODUCT_ID = '' }; Err = 'mode=diagnose needs product-id' }
    @{ Case = 'publish has no client secret'; Set = @{ PC_CLIENT_SECRET = '' }; Err = 'mode=publish needs tenant-id, client-id and client-secret (pass them from secrets)' }
    @{ Case = 'delete-draft has no tenant id'; Set = @{ MODE = 'delete-draft'; PC_TENANT_ID = '' }; Err = 'mode=delete-draft needs tenant-id, client-id and client-secret (pass them from secrets)' }
  ) {
    $e = $Ok.Clone(); foreach ($k in $Set.Keys) { $e[$k] = $Set[$k] }
    $r = Invoke-Step 'check' $e
    $r.Err | Should -BeExactly $Err
    $r.Out + $r.Err | Should -Not -Match 'dummy-client-secret|tenant-1|client-1'
  }
}

Describe 'action.yml package step' {
  BeforeEach {
    $script:Dir = Join-Path ([IO.Path]::GetTempPath()) ('pkgdir-' + [guid]::NewGuid().ToString('N'))
    $script:PkgPath = & $MakePackage -Dir $Dir -Version '1.2.3.0'
    $script:Sha = (Get-FileHash -LiteralPath $PkgPath -Algorithm SHA256).Hash.ToLower()
    $script:Base = @{ MODE = 'inspect'; PACKAGE_DIR = $Dir; EXPECTED_IDENTITY_NAME = $Identity; EXPECTED_PUBLISHER = $Publisher
      EXPECTED_VERSION = ''; EXPECTED_FILE = ''; EXPECTED_SHA256 = '' }
  }
  AfterEach { Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue }

  It 'inspect writes the file, name, version and SHA-256 to the outputs and the job summary' {
    $r = Invoke-Step 'package' $Base
    $r.Err | Should -BeNullOrEmpty
    $r.Output | Should -Be @("file=$PkgPath", 'file_name=ExampleApp-1.2.3.0-x64.msixupload', 'version=1.2.3.0', "sha256=$Sha")
    $r.Summary | Should -Match ([regex]::Escape("- SHA-256: ``$Sha``"))
    $r.Summary | Should -Match ([regex]::Escape('- Version: `1.2.3.0`'))
  }
  It 'publish checks the package against the inspected name and hash, and writes no summary' {
    $e = $Base.Clone(); $e.MODE = 'publish'; $e.EXPECTED_FILE = 'ExampleApp-1.2.3.0-x64.msixupload'; $e.EXPECTED_SHA256 = $Sha; $e.EXPECTED_VERSION = '1.2.3.0'
    $r = Invoke-Step 'package' $e
    $r.Err | Should -BeNullOrEmpty
    $r.Out | Should -Match ([regex]::Escape("Publishing ExampleApp-1.2.3.0-x64.msixupload Version=1.2.3.0 SHA256=$Sha"))
    $r.Output[0] | Should -BeExactly "file=$PkgPath"
    $r.Summary | Should -BeNullOrEmpty
  }
  It 'stops when <Case>' -ForEach @(
    @{ Case = 'the identity name differs'; Set = @{ EXPECTED_IDENTITY_NAME = 'Contoso.OtherApp' }; Err = 'unexpected Identity Name' }
    @{ Case = 'the publisher differs'; Set = @{ EXPECTED_PUBLISHER = 'CN=11111111-2222-3333-4444-555555555555' }; Err = 'unexpected Identity Publisher' }
    @{ Case = 'the version is not the expected one'; Set = @{ EXPECTED_VERSION = '1.2.4.0' }; Err = 'package version 1.2.3.0 does not match the expected version (1.2.4.0)' }
    @{ Case = 'publish gets another file name'; Set = @{ MODE = 'publish'; EXPECTED_FILE = 'ExampleApp-1.2.2.0-x64.msixupload' }
       Err = 'package file ExampleApp-1.2.3.0-x64.msixupload is not the one shown before approval (ExampleApp-1.2.2.0-x64.msixupload)' }
    @{ Case = 'publish gets another SHA-256'; Set = @{ MODE = 'publish'; EXPECTED_SHA256 = ('0' * 64) }; Err = 'package SHA-256 differs from the one shown before approval' }
  ) {
    $e = $Base.Clone(); foreach ($k in $Set.Keys) { $e[$k] = $Set[$k] }
    $r = Invoke-Step 'package' $e
    $r.Err | Should -BeExactly $Err
    $r.Output | Should -BeNullOrEmpty
  }
  It 'stops when the version does not end in .0' {
    Remove-Item -LiteralPath $PkgPath
    $null = & $MakePackage -Dir $Dir -Version '1.2.3.4'
    (Invoke-Step 'package' $Base).Err | Should -BeExactly 'Store versions must end in .0'
  }
  It 'stops when the folder holds <Count> .msixupload files' -ForEach @(@{ Count = 0 }, @{ Count = 2 }) {
    if ($Count -eq 0) { Remove-Item -LiteralPath $PkgPath } else { $null = & $MakePackage -Dir $Dir -Version '1.2.4.0' }
    (Invoke-Step 'package' $Base).Err | Should -Match "^expected exactly one \.msixupload in .*, found $Count$"
  }
}
