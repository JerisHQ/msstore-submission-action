# Reads the steps of the composite action.yml at the repository root, line by
# line (no YAML parser ships with pwsh). action.yml keeps one layout: each
# step starts with "    - name: ", its keys are indented 6 spaces, env
# entries 8, and the run: | body 8.

$script:ActionPath = Join-Path $PSScriptRoot '..' '..' 'action.yml'

function Get-ActionYamlPath { (Resolve-Path -LiteralPath $script:ActionPath).Path }

function Get-ActionLines { @(Get-Content -LiteralPath $script:ActionPath) }

# The lines of the step with this id, from its "    - name: " line to the
# line before the next step (or the end of the file).
function Get-ActionStepLines([string]$Id) {
  $lines = Get-ActionLines
  $at = [array]::IndexOf($lines, "      id: $Id")
  if ($at -lt 0) { throw "action.yml has no step with id $Id" }
  $start = $at
  while ($start -gt 0 -and -not $lines[$start].StartsWith('    - name: ')) { $start-- }
  $end = $at + 1
  while ($end -lt $lines.Count -and -not $lines[$end].StartsWith('    - name: ')) { $end++ }
  , @($lines[$start..($end - 1)])
}

# The run script of a step (by its id), dedented, exactly as the runner gets it.
function Get-ActionStepScript([string]$Id) {
  $lines = Get-ActionStepLines $Id
  $at = [array]::IndexOf($lines, '      run: |')
  if ($at -lt 0) { throw "step $Id has no run: | script" }
  $body = [System.Collections.Generic.List[string]]::new()
  for ($i = $at + 1; $i -lt $lines.Count; $i++) {
    $l = $lines[$i]
    if ($l.Trim() -and -not $l.StartsWith('        ')) { break }
    $body.Add($(if ($l.Length -ge 8) { $l.Substring(8) } else { '' }))
  }
  while ($body.Count -and -not $body[$body.Count - 1].Trim()) { $body.RemoveAt($body.Count - 1) }
  $body -join "`n"
}

# The env: block of a step as an ordered name -> value text map.
function Get-ActionStepEnv([string]$Id) {
  $lines = Get-ActionStepLines $Id
  $map = [ordered]@{}
  $at = [array]::IndexOf($lines, '      env:')
  if ($at -lt 0) { return $map }
  for ($i = $at + 1; $i -lt $lines.Count; $i++) {
    $m = [regex]::Match($lines[$i], '^        ([A-Z0-9_]+): (.*)$')
    if (-not $m.Success) { break }
    $map[$m.Groups[1].Value] = $m.Groups[2].Value
  }
  $map
}

# The value of a one-line key of a step (if, shell, ...), or '' when absent.
function Get-ActionStepKey([string]$Id, [string]$Key) {
  foreach ($l in (Get-ActionStepLines $Id)) {
    if ($l.StartsWith("      ${Key}: ")) { return $l.Substring(8 + $Key.Length) }
  }
  ''
}

# The ids of all steps, in order.
function Get-ActionStepIds {
  @(Get-ActionLines | Where-Object { $_ -cmatch '^      id: ' } | ForEach-Object { $_.Substring(10) })
}

Export-ModuleMember -Function Get-ActionYamlPath, Get-ActionLines, Get-ActionStepLines, Get-ActionStepScript, Get-ActionStepEnv, Get-ActionStepKey, Get-ActionStepIds
