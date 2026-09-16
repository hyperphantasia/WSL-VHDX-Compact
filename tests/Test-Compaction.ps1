param([string]$SourcePath = (Join-Path $PSScriptRoot '..\wsl_compactor.ps1'))

$ErrorActionPreference = 'Stop'
$SourcePath = (Resolve-Path -LiteralPath $SourcePath).ProviderPath
$fixture = Join-Path $PSScriptRoot 'compaction_fixture.ps1'
$engine = Join-Path $PSHOME 'powershell.exe'
if (-not (Test-Path -LiteralPath $engine)) { throw 'Run these tests in Windows PowerShell.' }
$root = Join-Path ([IO.Path]::GetTempPath()) ('wsl-compact-tests-' + [guid]::NewGuid())
$null = New-Item -ItemType Directory -Path $root
$failures = New-Object 'System.Collections.Generic.List[string]'
$cases = @(
  @{ Name = 'success'; Exit = 0; Optimized = @($true); Native = @(0); Hyperv = 0 },
  @{ Name = 'all_success'; Exit = 0; Optimized = @($true, $true); Native = @(0, 0); Hyperv = 0 },
  @{ Name = 'failure'; Exit = 1; Optimized = @($false); Native = @(7); Hyperv = 0 },
  @{ Name = 'signed_failure'; Exit = 1; Optimized = @($false); Native = @(-2147024809); Hyperv = 0 },
  @{ Name = 'failure_then_success'; Exit = 1; Optimized = @($false, $true); Native = @(7, 0); Hyperv = 0 },
  @{ Name = 'success_then_failure'; Exit = 1; Optimized = @($true, $false); Native = @(0, 7); Hyperv = 0 },
  @{ Name = 'all_failed'; Exit = 1; Optimized = @($false, $false); Native = @(7, 9); Hyperv = 0 },
  @{ Name = 'hyperv_success'; Exit = 0; Optimized = @($true); Native = @(); Hyperv = 1 },
  @{ Name = 'fallback_success'; Exit = 0; Optimized = @($true); Native = @(0); Hyperv = 1 },
  @{ Name = 'fallback_failure'; Exit = 1; Optimized = @($false); Native = @(7); Hyperv = 1 },
  @{ Name = 'command_error'; Exit = 1; Optimized = @($false, $true); Native = @(0); Hyperv = 0 },
  @{ Name = 'silent_failure'; Exit = 1; Optimized = @($false); Native = @(7); Hyperv = 0 },
  @{ Name = 'localized_failure'; Exit = 1; Optimized = @($false); Native = @(7); Hyperv = 0 }
)
$runs = @(foreach ($case in $cases) {
  foreach ($preference in @('Continue', 'Stop')) {
    @{ Case = $case; Preference = $preference }
  }
})

try {
  foreach ($run in $runs) {
    $case = $run.Case
    $name = "$($case.Name)-$($run.Preference)"
    $directory = Join-Path $root $name
    $null = New-Item -ItemType Directory -Path $directory
    $stdout = Join-Path $directory 'stdout.txt'
    $stderr = Join-Path $directory 'stderr.txt'
    $arguments = '-NoLogo -NoProfile -NonInteractive -File "{0}" -SourcePath "{1}" -ResultDirectory "{2}" -Scenario {3} -ErrorPreference {4}' -f (
      $fixture, $SourcePath, $directory, $case.Name, $run.Preference
    )
    $start = New-Object System.Diagnostics.ProcessStartInfo($engine, $arguments)
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $start
    $null = $process.Start()
    $outputTask = $process.StandardOutput.ReadToEndAsync()
    $errorTask = $process.StandardError.ReadToEndAsync()
    try {
      if (-not $process.WaitForExit(30000)) {
        $process.Kill()
        $process.WaitForExit()
        throw 'Fixture exceeded 30 seconds.'
      }
      $output = $outputTask.GetAwaiter().GetResult()
      $errorOutput = $errorTask.GetAwaiter().GetResult()
      Set-Content -LiteralPath $stdout -Value $output -Encoding UTF8
      Set-Content -LiteralPath $stderr -Value $errorOutput -Encoding UTF8
      $result = Get-Content -LiteralPath (Join-Path $directory 'result.json') -Raw | ConvertFrom-Json
      if ($result.ErrorPreference -ne $run.Preference) { throw 'Wrong error preference.' }
      if ($process.ExitCode -ne $case.Exit) { throw "Wrong process exit: $($process.ExitCode)." }
      if (@($result.Jobs).Count -ne $case.Optimized.Count) { throw 'Missing distro results.' }
      for ($i = 0; $i -lt $case.Optimized.Count; $i++) {
        if ($result.Jobs[$i].Optimized -isnot [bool] -or
            $result.Jobs[$i].Optimized -ne $case.Optimized[$i]) {
          throw "Wrong Optimized state for distro $i."
        }
        if ($null -eq $result.Jobs[$i].CurrentSize) { throw "Missing size for distro $i." }
        if ($output -notmatch "Distro: fixture-$i") { throw "Missing summary for distro $i." }
      }
      if (($result.NativeExits -join ',') -ne ($case.Native -join ',')) { throw 'Wrong native exit sequence.' }
      if (@($result.HypervCalls).Count -ne $case.Hyperv) { throw 'Wrong Hyper-V call count.' }
      $expectedDiskpart = if ($case.Name -eq 'hyperv_success') { 0 } else { $case.Optimized.Count }
      if (@($result.DiskpartCalls).Count -ne $expectedDiskpart) { throw 'Wrong DiskPart call count.' }
      if (@($result.RemainingTemps).Count -ne 0) { throw 'Temporary script was not removed.' }
      if ($case.Exit -ne 0 -and $output -match '(?m)^Done\.') { throw 'Failure reported as Done.' }
      if ($case.Exit -eq 0 -and $output -notmatch '(?m)^Done\.') { throw 'Success summary missing.' }
      if ($case.Exit -eq 0 -and -not [string]::IsNullOrWhiteSpace($errorOutput)) {
        throw 'Unexpected successful-run stderr.'
      }
      if ($case.Exit -ne 0 -and $errorOutput -notmatch 'One or more distros did not compact successfully') {
        throw 'Aggregate failure missing.'
      }
      if ($case.Optimized.Count -gt 1 -and $output -notmatch 'Total across all distros') {
        throw 'Multi-distro total missing.'
      }
      Write-Host "PASS $name (Windows PowerShell $($result.Version), exit $($process.ExitCode))"
    }
    catch {
      $failures.Add("${name}: $($_.Exception.Message)")
      Write-Warning $failures[$failures.Count - 1]
    }
    finally {
      if (-not $process.HasExited) {
        $process.Kill()
        $process.WaitForExit()
      }
      $process.Dispose()
    }
  }
  if ($failures.Count) { throw "$($failures.Count) of $($runs.Count) cases failed. Evidence: $root" }
  Write-Host "$($runs.Count) cases passed. Evidence: $root"
}
finally {
  # Retain small synthetic logs for diagnosis; no real disk or WSL operations ran.
  Write-Host "Fixture evidence: $root"
}
