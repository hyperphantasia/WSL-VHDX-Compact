#Requires -Version 7.0
<#
.SYNOPSIS
    Tasks of the 'publish' job. Usage: ./Publish.ps1 -Task <name>
.DESCRIPTION
    Inputs come from environment variables (set per step in the workflow):

    VerifyChecksums    DIST_DIR
    VerifyAttestation  DIST_DIR, GITHUB_REPOSITORY, GITHUB_WORKFLOW_REF, GH_TOKEN
    PublishGallery     DIST_DIR, APP_NAME, NUGET_API_KEY
    CreateRelease      DIST_DIR, RELEASE_TAG, RELEASE_VERSION, REF_TYPE,
                       RELEASE_SHA, GH_TOKEN, GH_REPO
    Summary            DIST_DIR, APP_NAME, JOB_STATUS, GALLERY_OUTCOME,
                       RELEASE_OUTCOME, RELEASE_VERSION, RELEASE_TAG,
                       GITHUB_REPOSITORY, GITHUB_STEP_SUMMARY
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('VerifyChecksums', 'VerifyAttestation', 'PublishGallery',
        'CreateRelease', 'Summary')]
    [string]$Task
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ManifestName = 'checksums.txt'
$ManifestLine = '^([0-9a-fA-F]{64}) [ *]([^\\/]+)$'   # "<sha256>  <name>", no paths

function Get-Setting {
    param([Parameter(Mandatory)][string]$Name)
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Missing environment variable $Name"
    }
    $value
}

function Read-Manifest {
    # Returns @{ Name; Hash } entries from the checksum manifest.
    param([Parameter(Mandatory)][string]$Directory)

    $manifest = Join-Path $Directory $ManifestName
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
        throw "Missing manifest: $manifest"
    }
    foreach ($line in Get-Content -LiteralPath $manifest) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -notmatch $ManifestLine) { throw "Malformed manifest line: '$line'" }
        @{ Hash = $Matches[1].ToLowerInvariant(); Name = $Matches[2] }
    }
}

# ----------------------------------------------------------------------------
function Invoke-VerifyChecksums {
    # Two-way check: every listed file matches, no unlisted file is present.
    # Proves the artifacts were not altered between jobs; provenance is
    # checked by VerifyAttestation.
    $dir = (Resolve-Path -LiteralPath (Get-Setting DIST_DIR)).Path
    $entries = @(Read-Manifest -Directory $dir)
    if ($entries.Count -eq 0) { throw 'The manifest lists no files' }

    foreach ($entry in $entries) {
        $file = Join-Path $dir $entry.Name
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            throw "Missing downloaded artifact: $($entry.Name)"
        }
        $actual = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $entry.Hash) {
            throw "Checksum verification failed for $($entry.Name)"
        }
        Write-Host "OK  $($entry.Name)"
    }

    $listed = $entries.Name
    $unlisted = @(Get-ChildItem -LiteralPath $dir -File |
        Where-Object { $_.Name -ne $ManifestName -and $_.Name -notin $listed })
    if ($unlisted.Count -gt 0) {
        throw "Files not covered by the manifest: $($unlisted.Name -join ', ')"
    }
    Write-Host "All $($entries.Count) artifacts passed checksum verification"
}

function Invoke-VerifyAttestation {
    # Provenance: produced by THIS workflow file in THIS repository.
    # GITHUB_WORKFLOW_REF looks like "owner/repo/.github/workflows/x.yml@refs/..."
    $dir = Get-Setting DIST_DIR
    $repo = Get-Setting GITHUB_REPOSITORY
    $signerWorkflow = ((Get-Setting GITHUB_WORKFLOW_REF) -split '@')[0]

    $files = @(Get-ChildItem -LiteralPath $dir -File | Where-Object Name -NE $ManifestName)
    if ($files.Count -eq 0) { throw "No files to verify in $dir" }

    foreach ($file in $files) {
        gh attestation verify $file.FullName --repo $repo --signer-workflow $signerWorkflow
        if ($LASTEXITCODE -ne 0) {
            throw "Attestation verification failed for $($file.Name)"
        }
    }
    Write-Host "All $($files.Count) artifacts have a valid provenance attestation"
}

function Invoke-PublishGallery {
    # Publish-Script derives the package name from the file name.
    $path = Join-Path (Get-Setting DIST_DIR) "$(Get-Setting APP_NAME).ps1"

    $publishParams = @{
        Path        = $path
        NuGetApiKey = Get-Setting NUGET_API_KEY
        Repository  = 'PSGallery'
    }
    Publish-Script @publishParams
    Write-Host "Published $(Split-Path -Path $path -Leaf) to PSGallery"
}

function Invoke-CreateRelease {
    # Every file in DIST_DIR becomes an asset, attached at creation time (also
    # what immutable releases need). Needs GH_TOKEN and GH_REPO, no checkout.
    $tag = Get-Setting RELEASE_TAG
    $assets = @(Get-ChildItem -LiteralPath (Get-Setting DIST_DIR) -File |
        Sort-Object Name | ForEach-Object FullName)
    if ($assets.Count -eq 0) { throw 'No release assets found' }

    $ghArgs = @('release', 'create', $tag) + $assets +
        @('--title', "v$(Get-Setting RELEASE_VERSION)", '--generate-notes')

    if ((Get-Setting REF_TYPE) -eq 'tag') {
        $ghArgs += '--verify-tag'
    }
    else {
        $ghArgs += @('--target', (Get-Setting RELEASE_SHA))
    }

    & gh @ghArgs
    if ($LASTEXITCODE -ne 0) {
        throw "gh release create failed with exit code $LASTEXITCODE"
    }
    Write-Host "Release created: $tag"
}

function Invoke-Summary {
    # Reports the REAL step outcomes; hashes come from the manifest (no re-hash).
    $dir = Get-Setting DIST_DIR
    $tag = Get-Setting RELEASE_TAG
    $package = Get-Setting APP_NAME
    $t = '`'

    $gallery = if ((Get-Setting GALLERY_OUTCOME) -eq 'success') {
        "Published as $t$package$t"
    } else { "Not published ($env:GALLERY_OUTCOME)" }

    $release = if ((Get-Setting RELEASE_OUTCOME) -eq 'success') {
        "https://github.com/$(Get-Setting GITHUB_REPOSITORY)/releases/tag/$tag"
    } else { "Not created ($env:RELEASE_OUTCOME)" }

    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('## Release summary')
    $lines.Add('')
    $lines.Add('| Item | Value |')
    $lines.Add('|---|---|')
    $lines.Add("| Job status | $t$(Get-Setting JOB_STATUS)$t |")
    $lines.Add("| Version | $t$(Get-Setting RELEASE_VERSION)$t |")
    $lines.Add("| PowerShell Gallery | $gallery |")
    $lines.Add("| GitHub Release | $release |")

    if (Test-Path -LiteralPath (Join-Path $dir $ManifestName)) {
        foreach ($entry in Read-Manifest -Directory $dir) {
            $file = Join-Path $dir $entry.Name
            $size = if (Test-Path -LiteralPath $file -PathType Leaf) {
                '{0:N2} MB' -f ((Get-Item -LiteralPath $file).Length / 1MB)
            } else { 'n/a' }
            $lines.Add("| $($entry.Name) SHA256 | $t$($entry.Hash)$t |")
            $lines.Add("| $($entry.Name) size | $size |")
        }
    }

    $text = ($lines -join "`n") + "`n"
    if ($env:GITHUB_STEP_SUMMARY) {
        $text | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
    } else {
        Write-Host $text
    }
}

& "Invoke-$Task"
