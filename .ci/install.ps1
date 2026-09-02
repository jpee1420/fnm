[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$InstallDir,
    [switch]$SkipShell,
    [string]$Release = "latest",
    [switch]$SetupCMD
)

$ErrorActionPreference = "Stop"

# Ensure TLS 1.2 is enabled for older Windows PowerShell 5.1 environments
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {
    # Ignore if not supported or restricted
}

# --- H1 Fix: Environment variable fallbacks for `irm | iex` compatibility ---
# When invoked via `irm ... | iex`, the param() block is parsed but all parameters
# are $null/default. Environment variables provide a way to configure the installer
# through the pipe: $env:FNM_SKIP_SHELL="1"; irm ... | iex
if (-not $InstallDir -and $env:FNM_INSTALL_DIR) {
    $InstallDir = $env:FNM_INSTALL_DIR
}
if (-not $SkipShell -and $env:FNM_SKIP_SHELL -eq "1") {
    $SkipShell = [switch]::new($true)
}
if ($Release -eq "latest" -and $env:FNM_RELEASE) {
    $Release = $env:FNM_RELEASE
}
if (-not $SetupCMD -and $env:FNM_SETUP_CMD -eq "1") {
    $SetupCMD = [switch]::new($true)
}

function Get-DefaultInstallDir {
    if ($InstallDir) {
        return $InstallDir
    }
    if ($env:FNM_DIR -and (Test-Path $env:FNM_DIR)) {
        return $env:FNM_DIR
    }
    if (Test-Path "$HOME\.fnm") {
        return "$HOME\.fnm"
    }
    if ($env:USERPROFILE -and (Test-Path "$env:USERPROFILE\.fnm")) {
        return "$env:USERPROFILE\.fnm"
    }
    if ($env:LOCALAPPDATA) {
        return (Join-Path $env:LOCALAPPDATA "fnm")
    }
    if ($env:APPDATA) {
        return (Join-Path $env:APPDATA "fnm")
    }
    return (Join-Path $HOME ".fnm")
}

# --- M1 Fix: Helper to normalize paths for comparison ---
# Uses GetFullPath to resolve relative segments and char-array TrimEnd to strip
# trailing slashes, avoiding the subtle difference between "C:\" and "C:".
function Compare-PathEqual {
    param([string]$PathA, [string]$PathB)
    try {
        $a = [System.IO.Path]::GetFullPath($PathA).TrimEnd('\', '/')
        $b = [System.IO.Path]::GetFullPath($PathB).TrimEnd('\', '/')
        return $a -ieq $b
    } catch {
        return $PathA.TrimEnd('\', '/') -ieq $PathB.TrimEnd('\', '/')
    }
}

function Setup-PowerShellProfiles {
    param([string]$InstallDir)

    $ProfileHook = @"

# fnm
`$fnmPath = "$InstallDir"
if (Test-Path `$fnmPath) {
    if (`$env:PATH -notlike "*`$fnmPath*") {
        `$env:PATH = "`$fnmPath;`$env:PATH"
    }
    fnm env --use-on-cd --shell powershell | Out-String | Invoke-Expression
}
"@

    # --- M2 Fix: Normalize profile paths before dedup to handle OneDrive redirects ---
    $SeenProfiles = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $TargetProfiles = [System.Collections.Generic.List[string]]::new()

    # Helper to add a profile path only if we haven't seen its normalized form
    function Add-UniqueProfile {
        param([string]$Path)
        try {
            $normalized = [System.IO.Path]::GetFullPath($Path)
        } catch {
            $normalized = $Path
        }
        if ($SeenProfiles.Add($normalized)) {
            $TargetProfiles.Add($Path)
        }
    }

    # 1. Current active host profile
    if ($PROFILE) {
        $activeProfile = $PROFILE.ToString()
        if (-not [string]::IsNullOrWhiteSpace($activeProfile)) {
            Add-UniqueProfile $activeProfile
        }
    }

    # 2. Known standard Documents locations for Windows PowerShell (v5.1) and PowerShell Core (v6+)
    $DocumentsDir = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
    if (-not [string]::IsNullOrWhiteSpace($DocumentsDir)) {
        $Ps5Profile = Join-Path $DocumentsDir "WindowsPowerShell\Microsoft.PowerShell_profile.ps1"
        $PsCoreProfile = Join-Path $DocumentsDir "PowerShell\Microsoft.PowerShell_profile.ps1"

        Add-UniqueProfile $Ps5Profile
        Add-UniqueProfile $PsCoreProfile
    }

    foreach ($ProfilePath in $TargetProfiles) {
        try {
            $ProfileDir = Split-Path -Parent $ProfilePath
            if (-not (Test-Path $ProfileDir)) {
                New-Item -ItemType Directory -Path $ProfileDir -Force | Out-Null
            }

            if (Test-Path $ProfilePath) {
                $Content = Get-Content -Path $ProfilePath -Raw -ErrorAction SilentlyContinue
                if ($Content -and ($Content -match 'fnm env')) {
                    Write-Host "fnm is already configured in profile: $ProfilePath"
                    continue
                }
            }

            # --- L1 Fix: Echo the profile hook content before appending (parity with install.sh) ---
            Write-Host "Installing for PowerShell. Appending the following to ${ProfilePath}:"
            Write-Host $ProfileHook

            Add-Content -Path $ProfilePath -Value $ProfileHook
        } catch [System.UnauthorizedAccessException] {
            Write-Warning "Could not write to '$ProfilePath' — access was denied."
            Write-Warning "This is likely caused by Windows Controlled Folder Access (Ransomware protection)."
            Write-Host ""
            Write-Host "To configure fnm manually, open PowerShell as your normal user and run:" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "  Add-Content -Path `"$ProfilePath`" -Value 'fnm env --use-on-cd --shell powershell | Out-String | Invoke-Expression'" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "Or you can temporarily allow access:" -ForegroundColor Yellow
            Write-Host "  1. Open Windows Security > Virus & threat protection > Ransomware protection"
            Write-Host "  2. Under 'Controlled folder access', click 'Allow an app through Controlled folder access'"
            Write-Host "  3. Add your PowerShell executable (e.g. pwsh.exe or powershell.exe)"
            Write-Host "  4. Re-run this installer"
            Write-Host ""
        } catch {
            Write-Warning "Could not configure PowerShell profile at '$ProfilePath': $_"
        }
    }
}

function Setup-CmdAutoRun {
    param([string]$InstallDir)

    try {
        $CmdScriptPath = Join-Path $InstallDir "fnm_autorun.cmd"
        # Note: %%z uses doubled percent signs — this is required by batch file FOR
        # loop syntax. Do not "fix" this to %z, it will break.
        $CmdScriptContent = @"
@echo off
:: for /F will launch a new instance of cmd so we create a guard to prevent an infinite loop
if not defined FNM_AUTORUN_GUARD (
    set "FNM_AUTORUN_GUARD=AutorunGuard"
    FOR /f "tokens=*" %%z IN ('fnm env --use-on-cd --shell cmd') DO CALL %%z
)
"@
        Set-Content -Path $CmdScriptPath -Value $CmdScriptContent -Encoding Ascii

        $RegPath = "HKCU:\Software\Microsoft\Command Processor"
        if (-not (Test-Path $RegPath)) {
            New-Item -Path $RegPath -Force | Out-Null
        }

        $ExistingAutoRun = (Get-ItemProperty -Path $RegPath -Name "AutoRun" -ErrorAction SilentlyContinue).AutoRun
        if ($ExistingAutoRun) {
            if ($ExistingAutoRun -like "*fnm_autorun.cmd*" -or $ExistingAutoRun -like "*fnm env*") {
                Write-Host "fnm is already configured in CMD AutoRun registry."
                return
            }
            $NewAutoRun = "$ExistingAutoRun & `"$CmdScriptPath`""
        } else {
            $NewAutoRun = "`"$CmdScriptPath`""
        }

        Set-ItemProperty -Path $RegPath -Name "AutoRun" -Value $NewAutoRun
        Write-Host "Configured CMD AutoRun in $RegPath -> $CmdScriptPath"
    } catch {
        Write-Warning "Could not configure Command Prompt AutoRun: $_"
    }
}

# --- Main Installation Logic ---

$TargetInstallDir = Get-DefaultInstallDir

Write-Host "Installing fnm to: $TargetInstallDir"

# Determine download URL
if ($Release -eq "latest") {
    $DownloadUrl = "https://github.com/Schniz/fnm/releases/latest/download/fnm-windows.zip"
} else {
    $DownloadUrl = "https://github.com/Schniz/fnm/releases/download/$Release/fnm-windows.zip"
}

# Create temp directory
$TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("fnm_install_" + [System.Guid]::NewGuid().ToString("N"))
$TempZip = Join-Path $TempDir "fnm-windows.zip"
$TempExtractDir = Join-Path $TempDir "extracted"

New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

try {
    Write-Host "Downloading fnm from $DownloadUrl..."
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $TempZip -UseBasicParsing

    Write-Host "Extracting fnm..."
    New-Item -ItemType Directory -Path $TempExtractDir -Force | Out-Null
    Expand-Archive -Path $TempZip -DestinationPath $TempExtractDir -Force

    $FnmBinary = Get-ChildItem -Path $TempExtractDir -Filter "fnm.exe" -Recurse | Select-Object -First 1
    if (-not $FnmBinary) {
        throw "Could not locate fnm.exe in the downloaded archive."
    }

    if (-not (Test-Path $TargetInstallDir)) {
        New-Item -ItemType Directory -Path $TargetInstallDir -Force | Out-Null
    }

    $DestinationBinary = Join-Path $TargetInstallDir "fnm.exe"
    Copy-Item -Path $FnmBinary.FullName -Destination $DestinationBinary -Force
    Write-Host "Successfully placed fnm binary at: $DestinationBinary"

    # Add to persistent User PATH environment variable if not already present
    $UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $UserPaths = if ([string]::IsNullOrWhiteSpace($UserPath)) { @() } else { $UserPath -split ';' }
    
    $AlreadyInUserPath = $false
    foreach ($p in $UserPaths) {
        if (Compare-PathEqual $p $TargetInstallDir) {
            $AlreadyInUserPath = $true
            break
        }
    }

    if (-not $AlreadyInUserPath) {
        Write-Host "Adding $TargetInstallDir to User PATH..."
        $NewUserPath = if ([string]::IsNullOrWhiteSpace($UserPath)) { $TargetInstallDir } else { "$UserPath;$TargetInstallDir" }
        [Environment]::SetEnvironmentVariable("Path", $NewUserPath, "User")
    }

    # Update current session PATH so fnm is available immediately
    $SessionPaths = $env:PATH -split ';'
    $AlreadyInSessionPath = $false
    foreach ($p in $SessionPaths) {
        if (Compare-PathEqual $p $TargetInstallDir) {
            $AlreadyInSessionPath = $true
            break
        }
    }
    if (-not $AlreadyInSessionPath) {
        $env:PATH = "$TargetInstallDir;$env:PATH"
    }

    if (-not $SkipShell) {
        Setup-PowerShellProfiles -InstallDir $TargetInstallDir
        if ($SetupCMD) {
            Setup-CmdAutoRun -InstallDir $TargetInstallDir
        }
    }

    Write-Host ""
    Write-Host "fnm was installed successfully!"
    Write-Host "To get started, please restart your terminal or open a new shell session."
} finally {
    if (Test-Path $TempDir) {
        Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
