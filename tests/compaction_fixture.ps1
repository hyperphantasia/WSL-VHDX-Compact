param(
  [Parameter(Mandatory = $true)][string]$SourcePath,
  [Parameter(Mandatory = $true)][string]$ResultDirectory,
  [Parameter(Mandatory = $true)][string]$Scenario,
  [ValidateSet('Continue', 'Stop')][string]$ErrorPreference = 'Continue'
)

$ErrorActionPreference = 'Stop'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
  $SourcePath, [ref]$tokens, [ref]$parseErrors
)
if ($parseErrors.Count) { throw 'The compactor did not parse.' }

# Only the compaction loop and summary run; never admin, trim or shutdown code.
$loops = @($ast.EndBlock.Statements | Where-Object {
  $_ -is [System.Management.Automation.Language.ForEachStatementAst] -and
  $_.Body.Statements[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and
  $_.Body.Statements[0].Left.Extent.Text -eq '$optimized'
})
if ($loops.Count -ne 1) { throw 'Expected exactly one compaction loop.' }
$statements = @($ast.EndBlock.Statements | Where-Object {
  $_.Extent.StartOffset -ge $loops[0].Extent.StartOffset
})
$body = [scriptblock]::Create(($statements | ForEach-Object { $_.Extent.Text }) -join "`n")
$allowed = @('Write-Host', 'Write-Warning', 'Optimize-VHD', 'Set-Content',
  'diskpart', 'ForEach-Object', 'Remove-Item', 'Add-Member', 'Get-Item', 'Where-Object')
foreach ($command in $body.Ast.FindAll({
  param($node) $node -is [System.Management.Automation.Language.CommandAst]
}, $true)) {
  if ($command.GetCommandName() -notin $allowed) {
    throw "Unexpected fixture command: $($command.GetCommandName())"
  }
}

$cases = @{
  success = @(0)
  all_success = @(0, 0)
  failure = @(7)
  signed_failure = @(-2147024809)
  failure_then_success = @(7, 0)
  success_then_failure = @(0, 7)
  all_failed = @(7, 9)
  hyperv_success = @(0)
  fallback_success = @(0)
  fallback_failure = @(7)
  command_error = @(7, 0)
  silent_failure = @(7)
  localized_failure = @(7)
}
if (-not $cases.ContainsKey($Scenario)) { throw 'Unknown fixture scenario.' }
$env:TEMP = $ResultDirectory
$env:TMP = $ResultDirectory
$diskpartCalls = New-Object 'System.Collections.Generic.List[string]'
$hypervCalls = New-Object 'System.Collections.Generic.List[string]'
$nativeExits = New-Object 'System.Collections.Generic.List[int]'
$tempFiles = New-Object 'System.Collections.Generic.List[string]'
$codes = @($cases[$Scenario])
$jobs = @(for ($i = 0; $i -lt $codes.Count; $i++) {
  $path = Join-Path $ResultDirectory "synthetic-$i.txt"
  Set-Content -LiteralPath $path -Value 'Not a virtual disk.' -Encoding ASCII
  [PSCustomObject]@{
    Name = "fixture-$i"
    Vhdx = $path
    PrevSize = (Get-Item -LiteralPath $path).Length
    ExitCode = $codes[$i]
  }
})
$hypervAvailable = $Scenario -in @('hyperv_success', 'fallback_success', 'fallback_failure')
$global:LASTEXITCODE = 42

function Optimize-VHD {
  [CmdletBinding()]
  param([string]$Path, [string]$Mode)
  $hypervCalls.Add($j.Name)
  if ($Path -ne $j.Vhdx -or $Mode -ne 'Full') { throw 'Unexpected Hyper-V arguments.' }
  if ($Scenario -ne 'hyperv_success') { throw 'Synthetic Hyper-V failure.' }
}

function diskpart {
  param([string]$Mode, [string]$InputFile)
  $diskpartCalls.Add($j.Name)
  $tempFiles.Add($InputFile)
  if ($Mode -ne '/s' -or (Split-Path $InputFile) -ne $ResultDirectory) {
    throw 'Unexpected DiskPart arguments.'
  }
  if ($Scenario -eq 'command_error' -and $j.Name -eq 'fixture-0') {
    throw 'Synthetic command exception.'
  }
  if ($Scenario -eq 'localized_failure') { 'Error de disco simulado.' }
  elseif ($Scenario -ne 'silent_failure') { '100 percent' }
  # A real harmless native process supplies LASTEXITCODE, not a mocked integer.
  & "$env:SystemRoot\System32\cmd.exe" /d /c "exit $($j.ExitCode)"
  $nativeExits.Add($LASTEXITCODE)
}

foreach ($name in @('diskpart', 'Optimize-VHD')) {
  if ((Get-Command $name).CommandType -ne 'Function') {
    throw "The destructive command '$name' is not intercepted."
  }
}

try {
  $ErrorActionPreference = $ErrorPreference
  . $body
}
finally {
  $ErrorActionPreference = 'Stop'
  [PSCustomObject]@{
    Version = $PSVersionTable.PSVersion.ToString()
    ErrorPreference = $ErrorPreference
    Jobs = @($jobs | Select-Object Name, Optimized, CurrentSize)
    DiskpartCalls = @($diskpartCalls.ToArray())
    HypervCalls = @($hypervCalls.ToArray())
    NativeExits = @($nativeExits.ToArray())
    RemainingTemps = @($tempFiles | Where-Object { Test-Path -LiteralPath $_ })
  } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (
    Join-Path $ResultDirectory 'result.json'
  ) -Encoding UTF8
}
