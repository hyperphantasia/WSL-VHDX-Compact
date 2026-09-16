# WSL2 ext4.vhdx compactor

[![Release (PowerShell Gallery + GitHub Release)](https://github.com/hyperphantasia/WSL-VHDX-Compact/actions/workflows/release.yml/badge.svg)](https://github.com/hyperphantasia/WSL-VHDX-Compact/actions/workflows/release.yml)

**♫ Garbage - Only Happy When It Rains (1995) ♪**

![Banner Image](<img/compactor.png> "A custom tshirt with a mysterious teaser message").<br>*Declutter your WSL - the easy way. (Photograph by Gerald Herbert/AP)*

## Description

This PowerShell script automates the process of compacting WSL2 `ext4.vhdx` files, which can help free up **a lot** of disk space on your Windows system.

## Learning

>[!NOTE]
> The [initial release](https://github.com/hyperphantasia/WSL-VHDX-Compact/blob/c5c2e346ab0dd1a8dbc6130f8d372af8022ddd60/wsl_compactor.ps1) is the subject of a tutorial designed as a practical introduction to PowerShell. It is available on [fCC News](https://www.freecodecamp.org/news/how-to-free-up-and-automatically-manage-disk-space-for-wsl-on-windows-1011/).

## Table of contents

<details>
<summary>Contents - click to expand</summary>

- [WSL2 ext4.vhdx compactor](#wsl2-ext4vhdx-compactor)
  - [Description](#description)
  - [Learning](#learning)
  - [Table of contents](#table-of-contents)
  - [Why?](#why)
    - [The big issue](#the-big-issue)
  - [Benefits](#benefits)
  - [Screenshot](#screenshot)
  - [Requirements](#requirements)
  - [Usage](#usage)
    - [The executable](#the-executable)
    - [PowerShell gallery](#powershell-gallery)
  - [The Windows .exe](#the-windows-exe)
    - [Verifying your download](#verifying-your-download)
    - [Code signing](#code-signing)
  - [Algorithm](#algorithm)
  - [Notes](#notes)
    - [Exit codes & errors](#exit-codes--errors)
    - [Misc](#misc)
  - [Compatibility](#compatibility)
  - [Changelog](#changelog)
    - [July 2026 - Latest](#july-2026---latest)
    - [May 2026](#may-2026)
    - [April & May 2026](#april--may-2026)
    - [August 2025](#august-2025)
  - [Contributing](#contributing)
  - [License](#license)

</details>

## Why?

Windows Subsystem for Linux (WSL 2) uses a virtualization platform to install Linux distributions alongside the host Windows operating system. For that, it creates a Virtual Hard Disk (VHD) to store files for each of the Linux distributions that you install. These VHDs use the ext4 file system type and are represented on your Windows hard drive as an `ext4.vhdx` file.

WSL 2 automatically resizes these VHD files to meet storage needs. This means that the VHD file starts small and grows as needed. Initially, it may only take up a few gigabytes, but as you install applications and create files within your Linux environment, the VHD expands to accommodate the additional data.

### The big issue

>[!NOTE]
>When you delete files or uninstall applications, **the VHD does not automatically shrink**.

This is a bit problematic, especially when you deal with a lot of data and dependencies in your workflow (data science..). Furthermore, the process of regaining the lost space is a bit cumbersome.

>[!TIP]
>It's probably a matter of time before the issue is solved. Microsoft rolled out some new experimental features dealing with that, but careful, some users testing it have complained about data loss.
> More about this on [superuser](https://superuser.com/questions/1606213/how-do-i-get-back-unused-disk-space-from-ubuntu-on-wsl2#1612289).

Until then you are free to use this script :)

## Benefits

- **Storage efficiency**: helps recover unused space in WSL2 distributions without hassle.
- **Fast and universal**: prefers `Optimize‑VHD` on Hyper‑V systems (faster, more robust), with a `diskpart` fallback for broader compatibility.
- **Automation-friendly**: no need to manually locate and compact the `ext4.vhdx file`! Possibility to pass the distro name as an argument.
- **User-friendly**: simple interface with basic reporting.

## Screenshot

![Screenshot demo image](<img/wsl2-compact-disk-space-screenshot.gif> "Demo of WSL2 Compact - reclaim and save disk space on your WSL2 Linux distros")<br>*PowerShell screenshot : first distro selected in interactive mode (diskpart fallback).*

## Requirements

- **Administrator privileges**: the script needs to be run with administrative rights.
- **PowerShell**: make sure you have PowerShell installed on your system (by default on Windows 10/11).
- **WSL2**: this script is designed only for WSL2 distributions.

## Usage

To run the script, follow these steps:

1. Download or clone this repository.
2. Open Command Prompt or PowerShell **as an administrator**.
3. Navigate to the directory containing the `wsl_compactor.ps1` file.
4. Execute the script with the following  command:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\wsl_compactor.ps1
```

Non-interactive mode:

>[!TIP]
> You can list the distros available from your system with:

```powershell
wsl.exe --list
```

When `-DistroName` or `-All` are supplied, the script runs without confirmation prompt. Example with an Ubuntu distro:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\wsl_compactor.ps1 -DistroName Ubuntu
```

### The executable

Easy! Just click (you will be prompted for an Admin elevation). See the [section below](https://github.com/hyperphantasia/WSL-VHDX-Compact#the-windows-exe) and the [release](https://github.com/hyperphantasia/WSL-VHDX-Compact/releases/) section.

### PowerShell gallery

The script is also available in the [PowerShell gallery](https://www.powershellgallery.com/packages/wsl2compact). This can simplify automation tasks.
It is advised to use at least PowerShell 5.1 In an elevated PowerShell terminal (run as Administrator).

Make sure `PowerShellGet` and and `PackageManagement` are available on the system:

```powershell
Install-Module -Name PowerShellGet -Force -AllowClobber
Install-Module -Name PackageManagement -Force -AllowClobber
```

>[!NOTE]
> You might also be prompted to install NuGet.

Installation:

```powershell
Install-Script -Name wsl2compact
```

>[!TIP]
> You can install system-wide by appending the following argument `-Scope AllUsers` (by default the scope is `CurrentUser`) to the installation comand.
>
> If you get an ExecutionPolicy warning, you can precede the installation command and run PowerShell with `powershell.exe -NoProfile -ExecutionPolicy Bypass` or set a temporary policy `Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force`

Run the script:

>[!NOTE]
> `Get-Command wsl2compact` helps you locate the script on your system.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $((Get-Command wsl2compact).Source)
```

or optionally, specify a `-DistroName` or `-All` to run in non-interactive mode:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $((Get-Command wsl2compact).Source)
 -DistroName Ubuntu
```

## The Windows `.exe`

WSL-VHDX-Compact is now also a Windows executable! Check the [release](https://github.com/hyperphantasia/WSL-VHDX-Compact/releases/) section.

### Verifying your download

Every release includes a `checksums.txt` and is cryptographically attested by GitHub Actions, so you can confirm a binary actually came from this repo's build pipeline, unmodified.

**Check the SHA256 checksum:**

Open a terminal from the location of the `.exe` and compare the content of `checksums.txt` with the output of this command:

```powershell
Get-FileHash .\wsl2compact.exe -Algorithm SHA256
```

**Verify build provenance** (requires the [GitHub CLI](https://cli.github.com/)):

```powershell
gh attestation verify .\wsl2compact.exe -R hyperphantasia/WSL-VHDX-Compact
```

This command verifies and confirms that your `wsl2compact.exe` was built by this GitHub Actions workflow from the exact commit tagged in the release and not modified or built anywhere else.

### Code signing

This project is not yet code-signed. I've applied for a free certificate. This section will be updated once signing is in place.

>[!NOTE]
> `wsl2compact.exe` is built with [PS2EXE](https://github.com/MScholtes/PS2EXE) from the `.ps1` script in this repo. Nothing more.
> A small number of antivirus engines occasionally flag freshly-built, unsigned Windows executables as suspicious based on heuristics *rather than actual content*. This is a [well-documented](https://github.com/MScholtes/PS2EXE/issues/153) **false-positive** [pattern](https://stackoverflow.com/questions/70393526/how-do-i-compile-a-powershell-script-so-that-it-is-shown-as-safe-by-antivirus) for small open-source tools that is not unique to this project.

Since you will be prompted to run a powershell script with elevated rights, be rigorous: read below how to check the contents of the `.exe` by yourself. If you'd rather avoid it entirely, use the PowerShell Gallery install method above, or read and run `wsl_compactor.ps1` directly: it's plain, unobfuscated PowerShell.

After installing PS2Exe like this:

```powershell
Install-Module -Name ps2exe -Scope CurrentUser
```

You can unpack the `.exe` :

```powershell
Import-Module ps2exe
Invoke-PS2EXE -extract .\wsl2compact.exe -OutPath .\extracted
```

And then inspect its content :)

The only difference with [wsl_compactor.ps1](https://github.com/hyperphantasia/WSL-VHDX-Compact/blob/main/wsl_compactor.ps1) script should be the two lines bottom lines appended during packaging stage by the [`release.yml`](https://github.com/hyperphantasia/WSL-VHDX-Compact/blob/main/.github/workflows/release.yml) file (this maintains the terminal screen active and exit only on user input).

```powershell
Write-Host "`nPress any key to exit..." -ForegroundColor DarkCyan
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
```

## Algorithm

The script performs the following actions:

1. Verifies Administrator privileges.
2. Enumerates installed WSL2 distributions (from the registry).
3. Selects a distribution (via `-DistroName`, interactive menu if multiple, or all distros via `-All`, or the single installed distro).
4. Identifies the base path and locates the `ext4.vhdx` file.
5. Runs `fstrim` inside the distro to discard unused blocks.
6. Shuts down WSL.
7. Attempts to compact using Hyper‑V `Optimize-VHD -Mode Full`; if Hyper‑V is unavailable or `Optimize‑VHD` fails, falls back to the `diskpart` method.
8. Reports previous size, current size, and saved disk space.

## Notes

### Exit codes & errors

- The script throws errors on missing admin rights, missing registry entries, missing ext4.vhdx file, or failed WSL shutdown.
- When `fstrim` fails it logs a warning and continues.
- A failed DiskPart compaction is reported for that distro without marking it
  optimized. The remaining distros are still processed, and every result is
  included in the summary. After the summary, any failed compaction raises an
  aggregate error (`powershell.exe -File` exits with code 1); all-success runs
  exit with code 0. DiskPart's native exit code is checked, not localized text.

### Testing

Run the regression tests from the repository root in Windows PowerShell 5.1:

```powershell
powershell.exe -NoProfile -File .\tests\Test-Compaction.ps1
```

No administrator rights or additional modules are needed. The tests execute
the script's compaction loop and summary in isolated PowerShell processes,
substitute DiskPart and Optimize-VHD, and use only disposable text files. They
never enumerate distros, trim disks, shut down WSL, or compact a real VHDX.
They verify native process exit handling, per-distro results, continuation,
fallback and temporary-script cleanup, not physical VHD attachment or space
reclamation. Small synthetic diagnostic files are retained at the printed
temporary path.

### Misc

- If multiple distributions are installed, you'll be prompted to select one.
- In **interactive mode** (no `-DistroName`/`-All` argument passed) The script will confirm the selected distribution before proceeding with compaction.
- `Optimize‑VHD` is preferred on machines with Hyper‑V (Windows Pro/Enterprise). `diskpart` works on broader editions but may be slower.
- *Be patient*. If there is a lot of compacting ahead, **the script might take a while to execute**.

>[!WARNING]
> As always when dealing with important data: make sure to have backups!

## Compatibility

This script is compatible with Windows systems that have WSL2 installed. It has been tested on Windows 10 and Windows 11.

## Changelog

### July 2026 - Latest

- **Added**: implemented CI/CD pipeline powered by github actions. Each push on the main branch:
  - Pushes the `.ps1` script on [PowerShell Gallery](https://www.powershellgallery.com/packages/wsl2compact/)
  - Packages a Windows executable with [PS2EXE](https://github.com/MScholtes/PS2EXE) and pushes the `.exe` as a new github [release](https://github.com/hyperphantasia/WSL-VHDX-Compact/releases).
- **Added**: implemented *a one choice option* (`-All`) to compact all available distros sequentially.

### May 2026

- **Bugfixes**: fixed distro enumeration listing and early exit error. [PR#4](https://github.com/hyperphantasia/WSL-VHDX-Compact/pull/4) by @AlexanderDoerr

### April & May 2026

- **Added**: prefer `Optimize-VHD` (Hyper‑V module) with automatic fallback to diskpart if Hyper‑V is unavailable or Optimize‑VHD fails [issue#2](https://github.com/hyperphantasia/WSL-VHDX-Compact/issues/2).
- **Added**: `-DistroName` parameter for easier automation.
- **Added**: `fstrim` inside the distro prior to compaction to discard unused blocks [issue#2](https://github.com/hyperphantasia/WSL-VHDX-Compact/issues/2).
- **Added**: more explicit admin check (throws early if not elevated).
- **Added**: reporting of previous/current sizes and bytes saved. [PR#1](https://github.com/hyperphantasia/WSL-VHDX-Compact/pull/1) by @lrotova.
- **Released**: [WSL2Compact v1.0.0](https://github.com/hyperphantasia/WSL-VHDX-Compact/releases/tag/v1.0.0) Windows executable.

### v1.0 (August 2025)

- Initial release.

## Contributing

Contributions are welcome! If you have any improvements or bug fixes, feel free to submit them via GitHub.

## License

Do what you want with the code, this script is released under the [Unlicense](https://unlicense.org/) license.
