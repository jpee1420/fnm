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

function Get-DefaultInstallDir {
    if ($InstallDir) {
        return $InstallDir
    }
    if ($env:FNM_INSTALL_DIR) {
        return $env:FNM_INSTALL_DIR
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

$TargetInstallDir = Get-DefaultInstallDir
if ($env:FNM_RELEASE -and ($Release -eq "latest")) {
    $Release = $env:FNM_RELEASE
}

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
        if ($p.TrimEnd('\/') -ieq $TargetInstallDir.TrimEnd('\/')) {
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
        if ($p.TrimEnd('\/') -ieq $TargetInstallDir.TrimEnd('\/')) {
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

    $TargetProfiles = [System.Collections.Generic.List[string]]::new()

    # 1. Current active host profile
    if ($PROFILE) {
        $activeProfile = $PROFILE.ToString()
        if (-not [string]::IsNullOrWhiteSpace($activeProfile)) {
            $TargetProfiles.Add($activeProfile)
        }
    }

    # 2. Known standard Documents locations for Windows PowerShell (v5.1) and PowerShell Core (v6+)
    $DocumentsDir = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
    if (-not [string]::IsNullOrWhiteSpace($DocumentsDir)) {
        $Ps5Profile = Join-Path $DocumentsDir "WindowsPowerShell\Microsoft.PowerShell_profile.ps1"
        $PsCoreProfile = Join-Path $DocumentsDir "PowerShell\Microsoft.PowerShell_profile.ps1"

        if (-not $TargetProfiles.Contains($Ps5Profile)) {
            $TargetProfiles.Add($Ps5Profile)
        }
        if (-not $TargetProfiles.Contains($PsCoreProfile)) {
            $TargetProfiles.Add($PsCoreProfile)
        }
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

            Add-Content -Path $ProfilePath -Value $ProfileHook
            Write-Host "Appended fnm configuration to PowerShell profile: $ProfilePath"
        } catch {
            Write-Warning "Could not configure PowerShell profile at '$ProfilePath': $_"
        }
    }
}

function Setup-CmdAutoRun {
    param([string]$InstallDir)

    try {
        $CmdScriptPath = Join-Path $InstallDir "fnm_autorun.cmd"
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
