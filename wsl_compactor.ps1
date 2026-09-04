<#PSScriptInfo

.VERSION 1.0.6
.GUID 0bdb28b7-a42d-433c-ac30-eaabd48eae63
.AUTHOR hyperphantasia
.COMPANYNAME
.COPYRIGHT (c) 2026 hyperphantasia. All rights reserved.
.DESCRIPTION Save disk space on WSL2! PowerShell script that helps compacting the distro's ext4.vhdx and reclaim some hard drive space (using Optimize-VHD and diskpart as fallback). More on : https://github.com/hyperphantasia/WSL-VHDX-Compact
.TAGS WSL WSL2 WindowsSubsystemForLinux VHDX vhd ext4 linux Compact DiskCleanup Hyper-V powershell disk-cleanup Optimize-VHD diskpart fstrim virtualization windows disk hdd space disk-management storage-management
.LICENSEURI https://unlicense.org/
.PROJECTURI https://github.com/hyperphantasia/WSL-VHDX-Compact
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES

#>

<#
.SYNOPSIS
  Compact a WSL2 ext4.vhdx the automated way.

.DESCRIPTION
  1. Enumerates installed WSL2 distros via registry.
  2. Distro(s) selection.
  3. Resolves the distro BasePath from the registry.
  4. Trims free space inside WSL.
  5. Shuts down WSL.
  6. Compacts ext4.vhdx using Optimize-VHD. Falls back to diskpart.
  7. Report summary.

.PARAMETER DistroName
One or more WSL distro names to compact. Skips the interactive menu and confirmation prompt.

.PARAMETER All
Compact every registered WSL distro sequentially. Skips the interactive menu and confirmation
prompt.

.NOTES
  Must run as Administrator.
  On Windows Pro with Hyper-V, Optimize-VHD is preferred.
  On systems without the Hyper-V module, diskpart is used as fallback.

.USAGE
In an elevated terminal.

  Interactive:
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\wsl_compactor.ps1

  Non-interactive:
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\wsl_compactor.ps1 -DistroName Ubuntu
#>

[CmdletBinding()]
param(
  [string[]]$DistroName,
  [switch]$All
)

#------------------------------------------------------------
# Step 0 - Admin check
#------------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
  throw "This script must be run as Administrator."
}

if ($All -and $DistroName) {
  throw "Specify either -DistroName or -All, not both."
}

#------------------------------------------------------------
# Step 1 - Enumerate distros from the registry
#------------------------------------------------------------
$lxssKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'

# Grab all subkeys that have a DistributionName value
$distros = Get-ChildItem $lxssKey |
           ForEach-Object {
             $props = Get-ItemProperty $_.PSPath
             [PSCustomObject]@{
               Name        = $props.DistributionName
               BasePath    = $props.BasePath
               VhdFileName = $props.VhdFileName
               WSLVer      = $props.Version
             }
           }

if ($distros.Count -eq 0) {
  throw "No WSL distros found in the registry."
}

#------------------------------------------------------------
# Step 2 - Select distro(s)
#   -All            -> every distro, non-interactive
#   -DistroName ...  -> one or more named distros, non-interactive
#                       (e.g. -DistroName Ubuntu, Debian)
#   no args, 1 distro -> that distro, still confirms
#   no args, >1 distro -> menu, pick a number OR "A" for all
#------------------------------------------------------------
$nonInteractive = $false

if ($All) {
  $selectedList   = @($distros)
  $nonInteractive = $true
}
elseif ($DistroName) {
  $selectedList = foreach ($name in $DistroName) {
    $match = $distros | Where-Object { $_.Name -ieq $name } | Select-Object -First 1
    if (-not $match) {
      $available = ($distros | Select-Object -ExpandProperty Name) -join ', '
      throw "Distro '$name' was not found. Available distros: $available"
    }
    $match
  }
  $nonInteractive = $true
}
elseif ($distros.Count -gt 1) {
  Write-Host "Multiple distros detected. Please choose which one(s) to compact:`n" -ForegroundColor Cyan
  for ($i = 0; $i -lt $distros.Count; $i++) {
    Write-Host ("[{0}] {1} (WSL{2})" -f ($i + 1), $distros[$i].Name, $distros[$i].WSLVer)
  }
  Write-Host "[A] All distros"

  do {
    $choice = Read-Host "`nEnter a number (1-$($distros.Count)), or 'A' to compact all"
    if ($choice -match '^(a|all)$') {
      $selectedList = @($distros)
      $valid = $true
    }
    else {
      $valid = ($choice -as [int]) -and ($choice -ge 1) -and ($choice -le $distros.Count)
      if ($valid) {
        $selectedList = @($distros[[int]$choice - 1])
      }
      else {
        Write-Warning "Please enter a valid integer between 1 and $($distros.Count), or 'A' for all."
      }
    }
  } until ($valid)
}
else {
  $selectedList = @($distros[$distros.Count - 1])
}

#------------------------------------------------------------
# Step 3 - Resolve BasePath & vhdx for each selected distro
#------------------------------------------------------------
$jobs = foreach ($sel in $selectedList) {
  $basePath = $sel.BasePath
  if ($basePath -like '\\?\*') { $basePath = $basePath.Substring(4) }

  if (-not (Test-Path -LiteralPath $basePath)) {
    throw "BasePath '$basePath' does not exist on disk for distro '$($sel.Name)'."
  }

  $vhdx = $null
  if ($sel.VhdFileName) {
    $candidate = Join-Path $basePath $sel.VhdFileName
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      $vhdx = $candidate
    }
  }

  if (-not $vhdx) {
    if ((Test-Path -LiteralPath $basePath -PathType Leaf) -and $basePath -match '\.vhdx$') {
      $vhdx = $basePath
    }
    else {
      $vhdx = @(
        Join-Path $basePath 'ext4.vhdx'
        Join-Path $basePath 'LocalState\ext4.vhdx'
      ) | Where-Object { Test-Path $_ } | Select-Object -First 1

      if (-not $vhdx) {
        $vhdx = Get-ChildItem -LiteralPath $basePath -Filter '*.vhdx' -File -ErrorAction SilentlyContinue |
                Sort-Object Length -Descending | Select-Object -First 1 -ExpandProperty FullName
      }
    }
  }

  if (-not $vhdx) {
    throw "No .vhdx file found at or under '$basePath' for distro '$($sel.Name)'."
  }

  [PSCustomObject]@{
    Name     = $sel.Name
    BasePath = $basePath
    Vhdx     = $vhdx
    PrevSize = (Get-Item $vhdx).Length
  }
}

Write-Host "`nThe following distro(s) will be compacted:" -ForegroundColor Magenta
foreach ($j in $jobs) {
  Write-Host ("  - {0}" -f $j.Name) -ForegroundColor DarkYellow
  Write-Host ("      BasePath : {0}" -f $j.BasePath)
  Write-Host ("      VHDX file: {0}" -f $j.Vhdx)
}
Write-Host ""

if (-not $nonInteractive) {
  Write-Host "Are you sure you want to proceed? (Y/N)" -ForegroundColor DarkCyan -NoNewline
  $answer = Read-Host
  if ($answer.ToUpper() -ne 'Y') {
    Write-Warning "Operation canceled."
    exit
  }
}
else {
  Write-Host "Non-interactive mode enabled (via -DistroName / -All)" -ForegroundColor Gray
}

#------------------------------------------------------------
# Step 4 - Optional fstrim (per distro, while each is still running)
#------------------------------------------------------------
foreach ($j in $jobs) {
  Write-Host "`nPreparation: logical cleanup with fstrim to discard unused blocks on '$($j.Name)'..." -ForegroundColor Cyan
  & wsl.exe -d "$($j.Name)" -u root -- fstrim -av
  if ($LASTEXITCODE -ne 0) {
    Write-Warning "fstrim returned a non-zero exit code for '$($j.Name)'. Continuing anyway."
  }
}

#------------------------------------------------------------
# Step 5 - Shutdown WSL (once, shuts down all running distros)
#------------------------------------------------------------
Write-Host "`nShutting down WSL..." -ForegroundColor Cyan
& wsl.exe --shutdown
if ($LASTEXITCODE -ne 0) {
  throw "Failed to shut down WSL."
}

#------------------------------------------------------------
# Step 6 - Hyper-V Optimize-VHD first, fallback to diskpart (per distro)
#------------------------------------------------------------
$hypervAvailable = $false
try {
  Import-Module Hyper-V -ErrorAction Stop
  $hypervAvailable = $true
}
catch {
  $hypervAvailable = $false
}

if (-not $hypervAvailable) {
  Write-Warning "Hyper-V module is not available. Compacting with diskpart."
}

foreach ($j in $jobs) {
  $optimized = $false

  if ($hypervAvailable) {
    try {
      Write-Host "`nCompacting: optimizing VHDX for '$($j.Name)' using Hyper-V Optimize-VHD..." -ForegroundColor Cyan
      Write-Host "This might take a while." -ForegroundColor Gray
      Optimize-VHD -Path $j.Vhdx -Mode Full -ErrorAction Stop
      $optimized = $true
    }
    catch {
      Write-Warning "Optimize-VHD failed for '$($j.Name)'. Falling back to diskpart."
    }
  }

  if (-not $optimized) {
    $dpScript = @"
select vdisk file="$($j.Vhdx)"
attach vdisk readonly
compact vdisk
detach vdisk
exit
"@

    $tempFile = [IO.Path]::GetTempFileName()
    Set-Content -LiteralPath $tempFile -Value $dpScript -Encoding ASCII

    Write-Host "Running DiskPart to compact the VHDX for '$($j.Name)'..." -ForegroundColor Cyan
    $lastPct = -1

    try {
      & diskpart /s $tempFile | ForEach-Object {
          if ($_ -match '(\d+)\s+percent') {
              $pct = [int]$Matches[1]
          if ($pct -ne $lastPct) {
            Write-Host "$pct% completed"
            $lastPct = $pct
          }
        }
        elseif ($_ -match '\S') {
          Write-Host $_
        }
      }
      $diskpartExitCode = $LASTEXITCODE
      if ($diskpartExitCode -ne 0) {
        throw "DiskPart failed for '$($j.Name)' with exit code $diskpartExitCode."
      }
      $optimized = $true
    }
    finally {
      Remove-Item $tempFile -ErrorAction SilentlyContinue
    }
  }

  $j | Add-Member -NotePropertyName Optimized -NotePropertyValue $optimized
  $j | Add-Member -NotePropertyName CurrentSize -NotePropertyValue (Get-Item $j.Vhdx).Length
}

#------------------------------------------------------------
# Step 7 - Report results
#------------------------------------------------------------
Write-Host "`n==================== Summary ====================" -ForegroundColor Yellow

$totalPrev    = 0
$totalCurrent = 0

foreach ($j in $jobs) {
  $saved = $j.PrevSize - $j.CurrentSize
  $totalPrev    += $j.PrevSize
  $totalCurrent += $j.CurrentSize

  Write-Host "`nDistro: $($j.Name)" -ForegroundColor DarkYellow
  Write-Host ("  Previous VHDX size: {0:N0} bytes ({1:N2} GB)" -f $j.PrevSize, ($j.PrevSize / 1GB)) -ForegroundColor Gray
  Write-Host ("  Current VHDX size:  {0:N0} bytes ({1:N2} GB)" -f $j.CurrentSize, ($j.CurrentSize / 1GB)) -ForegroundColor Gray
  Write-Host ("  Saved:              {0:N0} bytes ({1:N2} GB)" -f $saved, ($saved / 1GB)) -ForegroundColor Green

  if (-not $j.Optimized) {
    Write-Warning "  The compaction step did not complete successfully for '$($j.Name)'."
  }
}

if ($jobs.Count -gt 1) {
  $totalSaved = $totalPrev - $totalCurrent
  Write-Host "`n---------------- Total across all distros ----------------" -ForegroundColor Yellow
  Write-Host ("  Total previous size: {0:N0} bytes ({1:N2} GB)" -f $totalPrev, ($totalPrev / 1GB)) -ForegroundColor Gray
  Write-Host ("  Total current size:  {0:N0} bytes ({1:N2} GB)" -f $totalCurrent, ($totalCurrent / 1GB)) -ForegroundColor Gray
  Write-Host ("  Total saved:         {0:N0} bytes ({1:N2} GB)" -f $totalSaved, ($totalSaved / 1GB)) -ForegroundColor Green
}

if ($jobs | Where-Object { -not $_.Optimized }) {
  Write-Warning "`nOne or more distros did not compact successfully. See warnings above."
}
else {
  Write-Host "`nDone." -ForegroundColor Green
}
