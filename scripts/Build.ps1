#Requires -Version 7.0
<#
.SYNOPSIS
    Tasks of the 'build' job. Usage: ./Build.ps1 -Task <name>
.DESCRIPTION
    Inputs come from environment variables (set per step in the workflow):

    AssertRef        EVENT_NAME, REF_TYPE, REF_NAME
    ComputeVersion   REF_TYPE, REF_NAME, INPUT_VERSION   -> writes GITHUB_OUTPUT
    Preflight        VERSION, TAG, REF_TYPE, APP_NAME, GITHUB_REPOSITORY, GH_TOKEN
    StampVersion     VERSION, APP_NAME
    InstallPs2exe    PS2EXE_VERSION
    InstallSignPath  SIGNPATH_MODULE_VERSION
    BuildExe         VERSION, APP_NAME
    Sign             APP_NAME, DIST_DIR, SIGNPATH_API_TOKEN, SIGNPATH_ORG_ID,
                     SIGNPATH_PROJECT_SLUG, SIGNPATH_POLICY_SLUG,
                     REQUIRE_TRUSTED_SIGNATURE
    Checksums        DIST_DIR
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('AssertRef', 'ComputeVersion', 'Preflight', 'StampVersion',
        'InstallPs2exe', 'InstallSignPath', 'BuildExe', 'Sign', 'Checksums')]
    [string]$Task
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Branch manual (workflow_dispatch) releases may start from.
$AllowedBranch = 'main'
# EXE metadata.
$ExeTitle = 'WSL VHDX Compactor'
$ExeDescription = 'Compacts WSL2 distro VHDX files to reclaim disk space'
$ExeCompany = 'hyperphantasia'

function Get-Setting {
    param([Parameter(Mandatory)][string]$Name)
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Missing environment variable $Name"
    }
    $value
}

# ----------------------------------------------------------------------------
function Invoke-AssertRef {
    # Defense in depth only, NOT a security boundary: whoever can push a branch
    # controls the workflow and scripts that run from it. The real restriction
    # is the deployment branch/tag policy on the environments.
    $eventName = Get-Setting EVENT_NAME
    $refType = Get-Setting REF_TYPE
    $refName = Get-Setting REF_NAME

    # Tag pushes pin an exact commit; manual runs can start from any branch.
    if ($eventName -eq 'workflow_dispatch' -and
        -not ($refType -eq 'branch' -and $refName -eq $AllowedBranch)) {
        throw ("workflow_dispatch releases are only allowed from the " +
            "'$AllowedBranch' branch. Triggered from ref_type='$refType', " +
            "ref_name='$refName'.")
    }
    Write-Host "Ref check passed for event '$eventName'"
}

function Invoke-ComputeVersion {
    $refType = Get-Setting REF_TYPE
    $refName = Get-Setting REF_NAME

    if ($refType -eq 'tag') {
        if ($refName -notmatch '^v\d+\.\d+\.\d+$') {
            throw "Expected a tag such as v1.2.3, got '$refName'"
        }
        $tag = $refName
        $version = $tag.Substring(1)
    }
    else {
        $version = $env:INPUT_VERSION
        if ($version -notmatch '^\d+\.\d+\.\d+$') {
            throw "Expected a semantic version such as 1.2.3, got '$version'"
        }
        $tag = "v$version"
    }

    if ($env:GITHUB_OUTPUT) {
        "version=$version", "tag=$tag" |
            Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
    }
    Write-Host "Release version: $version"
    Write-Host "Release tag:     $tag"
}

function Invoke-Preflight {
    # PSGallery versions are immutable and the Gallery publish happens before
    # the GitHub release, so every collision is caught up front.
    $version = Get-Setting VERSION
    $tag = Get-Setting TAG
    $name = Get-Setting APP_NAME
    $refType = Get-Setting REF_TYPE
    $repo = Get-Setting GITHUB_REPOSITORY

    if (Find-Script -Name $name -RequiredVersion $version `
            -Repository PSGallery -ErrorAction SilentlyContinue) {
        throw "$name $version already exists on PSGallery"
    }

    gh release view $tag *> $null
    $releaseExists = ($LASTEXITCODE -eq 0)
    $global:LASTEXITCODE = 0   # non-zero is the expected outcome here
    if ($releaseExists) { throw "Release $tag already exists" }

    # A tag push necessarily has its tag; a manual run must not reuse one.
    if ($refType -ne 'tag') {
        gh api "repos/$repo/git/ref/tags/$tag" *> $null
        $tagExists = ($LASTEXITCODE -eq 0)
        $global:LASTEXITCODE = 0
        if ($tagExists) { throw "Tag $tag already exists" }
    }
    Write-Host "Preflight passed: $name $version / $tag are free"
}

function Invoke-StampVersion {
    $version = Get-Setting VERSION
    $path = (Resolve-Path -LiteralPath "$(Get-Setting APP_NAME).ps1").Path
    $text = Get-Content -LiteralPath $path -Raw

    # [ \t]+ and [^\r\n]* leave the line ending untouched (no CRLF -> LF).
    $regex = [regex]::new('(?m)^\.VERSION[ \t]+[^\r\n]*')
    if (-not $regex.IsMatch($text)) {
        throw "No .VERSION directive found in $path"
    }
    # Instance Replace(input, replacement, count): first match only.
    $text = $regex.Replace($text, ".VERSION $version", 1)
    [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false))

    $info = Test-ScriptFileInfo -Path $path
    if ($info.Version.ToString() -ne $version) {
        throw "Script version mismatch. Expected $version, found $($info.Version)"
    }
    if ([string]::IsNullOrWhiteSpace($info.Name)) {
        throw 'Script metadata has no name'
    }
    if ([string]::IsNullOrWhiteSpace($info.Description)) {
        throw 'Script metadata has no description'
    }
    Write-Host 'Validated script metadata'
    Write-Host "Name:        $($info.Name)"
    Write-Host "Version:     $($info.Version)"
    Write-Host "Description: $($info.Description)"
}

function Install-PinnedModule {
    # -Force suppresses the untrusted-repository prompt (no Set-PSRepository).
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Version)

    Install-Module -Name $Name -RequiredVersion $Version -Scope CurrentUser -Force
    $module = Get-Module -Name $Name -ListAvailable |
        Where-Object { $_.Version -eq [version]$Version } |
        Select-Object -First 1
    if (-not $module) { throw "Expected $Name $Version was not installed" }

    Write-Host "Using $Name $($module.Version)"
    Write-Host "Module path: $($module.ModuleBase)"
}

function Invoke-InstallPs2exe {
    Install-PinnedModule -Name ps2exe -Version (Get-Setting PS2EXE_VERSION)
}

function Invoke-InstallSignPath {
    Install-PinnedModule -Name SignPath -Version (Get-Setting SIGNPATH_MODULE_VERSION)
}

function Invoke-BuildExe {
    $app = Get-Setting APP_NAME
    $exe = "$app.exe"

    $ps2exeParams = @{
        inputFile    = "$app.ps1"
        outputFile   = $exe
        version      = Get-Setting VERSION
        title        = $ExeTitle
        description  = $ExeDescription
        company      = $ExeCompany
        product      = $app
        copyright    = "(c) $(Get-Date -Format yyyy) $ExeCompany"
        requireAdmin = $true
    }
    Invoke-ps2exe @ps2exeParams

    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        throw "The EXE was not created: $exe"
    }
    $size = (Get-Item -LiteralPath $exe).Length
    Write-Host ('Built {0} ({1:N0} bytes / {2:N2} MB)' -f $exe, $size, ($size / 1MB))
}

function Assert-Signature {
    param([Parameter(Mandatory)][string]$File, [Parameter(Mandatory)][bool]$RequireTrusted)

    $name = Split-Path -Path $File -Leaf
    $sig = Get-AuthenticodeSignature -LiteralPath $File

    $broken = 'NotSigned', 'HashMismatch', 'Incompatible', 'NotSupportedFileFormat'
    if ($null -eq $sig.SignerCertificate -or $sig.Status -in $broken) {
        throw "$name is not validly signed (status: $($sig.Status))"
    }
    if ($sig.Status -ne 'Valid') {
        if ($RequireTrusted) {
            throw "$name signature is not trusted (status: $($sig.Status))"
        }
        Write-Host ("::warning::$name is signed but the certificate chain is " +
            "not trusted (status: $($sig.Status)). Expected only with a " +
            'test-signing policy.')
    }
    Write-Host ("{0}: status={1} signer='{2}' thumbprint={3}" -f $name,
        $sig.Status, $sig.SignerCertificate.Subject, $sig.SignerCertificate.Thumbprint)
}

function Invoke-Sign {
    # Signs through SignPath, promotes the SIGNED files into DIST_DIR and
    # verifies their Authenticode signatures. Everything downstream must use
    # DIST_DIR, never the unsigned inputs. The SignPath artifact configuration
    # must sign both files at the root of the zip.
    # REQUIRE_TRUSTED_SIGNATURE=false accepts an untrusted chain (SignPath
    # test certificate) with a warning; true requires status 'Valid'.
    $app = Get-Setting APP_NAME
    $dist = Get-Setting DIST_DIR
    $files = "$app.ps1", "$app.exe"
    $requireTrusted = (Get-Setting REQUIRE_TRUSTED_SIGNATURE) -eq 'true'
    $apiToken = Get-Setting SIGNPATH_API_TOKEN

    $tempRoot = $env:RUNNER_TEMP ?? [IO.Path]::GetTempPath()
    $work = Join-Path $tempRoot "signing-$([guid]::NewGuid().ToString('N'))"
    $staging = Join-Path $work 'input'
    $extracted = Join-Path $work 'signed'
    $inputZip = Join-Path $work 'input.zip'
    $outputZip = Join-Path $work 'output.zip'

    try {
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        foreach ($file in $files) {
            if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
                throw "Cannot sign missing file: $file"
            }
            Copy-Item -LiteralPath $file -Destination $staging
        }
        Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $inputZip -Force
        Write-Host "Input zip: $inputZip"

        # OutputArtifactPath is a zip file path, not a directory.
        $submitParams = @{
            InputArtifactPath  = $inputZip
            ApiToken           = $apiToken
            OrganizationId     = Get-Setting SIGNPATH_ORG_ID
            ProjectSlug        = Get-Setting SIGNPATH_PROJECT_SLUG
            SigningPolicySlug  = Get-Setting SIGNPATH_POLICY_SLUG
            OutputArtifactPath = $outputZip
            WaitForCompletion  = $true
        }
        Submit-SigningRequest @submitParams

        if (-not (Test-Path -LiteralPath $outputZip -PathType Leaf)) {
            throw "No signed zip was returned at $outputZip"
        }
        Expand-Archive -LiteralPath $outputZip -DestinationPath $extracted -Force
        New-Item -ItemType Directory -Path $dist -Force | Out-Null

        foreach ($file in $files) {
            $found = @(Get-ChildItem -LiteralPath $extracted -Recurse -File |
                Where-Object Name -EQ $file)
            if ($found.Count -ne 1) {
                throw "Expected exactly one signed '$file' in the output, found $($found.Count)"
            }
            $destination = Join-Path $dist $file
            Copy-Item -LiteralPath $found[0].FullName -Destination $destination -Force
            Assert-Signature -File $destination -RequireTrusted $requireTrusted
        }
    }
    finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-Checksums {
    # The manifest (shasum format, LF, no BOM) is the single source of truth for
    # what is attested, verified and released.
    $dir = (Resolve-Path -LiteralPath (Get-Setting DIST_DIR)).Path
    $files = @(Get-ChildItem -LiteralPath $dir -File |
        Where-Object Name -NE 'checksums.txt' | Sort-Object Name)
    if ($files.Count -eq 0) { throw "No files found in $dir" }

    $lines = foreach ($file in $files) {
        $hash = Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256
        '{0}  {1}' -f $hash.Hash.ToLowerInvariant(), $file.Name
    }
    [IO.File]::WriteAllText((Join-Path $dir 'checksums.txt'),
        (($lines -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))

    Write-Host '::group::SHA256 checksums'
    $lines | ForEach-Object { Write-Host $_ }
    Write-Host '::endgroup::'
}

& "Invoke-$Task"
