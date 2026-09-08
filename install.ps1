<#
.SYNOPSIS
    Installs LabDesk on Windows from the newest release that ships an installer.

.DESCRIPTION
    Downloads the LabDesk installer for this machine's architecture and runs it
    unattended. Re-running the script upgrades an existing installation.

    Must be run from an elevated PowerShell session.

.PARAMETER Server
    ID / rendezvous server to configure after installing.

.PARAMETER Relay
    Relay server to configure after installing.

.PARAMETER Api
    API server to configure after installing.

.PARAMETER Key
    Server public key to configure after installing.

.EXAMPLE
    irm https://raw.githubusercontent.com/tfdan-cts/LabDesk/master/install.ps1 | iex

.EXAMPLE
    To pass server settings you need the script on disk, and Windows blocks
    downloaded scripts by default, so bypass the policy for this one run:

    irm https://raw.githubusercontent.com/tfdan-cts/LabDesk/master/install.ps1 -OutFile install.ps1
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -Server id.example.com -Key abc123

.NOTES
    Nothing is written to the server settings unless you supply a value.

    Trust model: the installer is downloaded over TLS from github.com and is not
    signed or checksummed by this project. A working TLS connection to GitHub is
    the whole of the trust chain.
#>

[CmdletBinding()]
param(
    [string]$Server,
    [string]$Relay,
    [string]$Api,
    [string]$Key
)

$ErrorActionPreference = 'Stop'
$repo = 'tfdan-cts/LabDesk'
$uninstallKey = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\LabDesk'

function Write-Step { param([string]$Message) Write-Host "labdesk: $Message" }
function Write-Warn { param([string]$Message) [Console]::Error.WriteLine("labdesk: warning: $Message") }

# Writes the message and exits with a real code. Write-Error is deliberately not
# used: $ErrorActionPreference is Stop, which turns it into a terminating throw,
# so the caller would get a stack trace naming this function instead of the
# message, and the exit code would never be set.
function Stop-WithError {
    param([string]$Message)
    [Console]::Error.WriteLine("labdesk: $Message")
    exit 1
}

# The installer writes DisplayVersion as crate::VERSION with dashes turned into
# dots (src/platform/windows.rs), so a suffixed upstream version such as 1.4.9-1
# is recorded as 1.4.9.1 while the asset name still reads 1.4.9. Accept the
# expected version, or a longer one that extends it, so a successful install is
# not reported as a failure. A different version, which is what a failed upgrade
# leaves behind, still is.
function Test-VersionMatch {
    param([string]$Installed, [string]$Expected)
    if (-not $Installed) { return $false }
    return ($Installed -eq $Expected) -or $Installed.StartsWith("$Expected.")
}

# Settings are written through the LabDesk service over IPC, and the service is
# created by the installer, so on a first install the write races the service
# coming up. Wait for it rather than guessing at a sleep.
function Wait-LabDeskService {
    param([int]$TimeoutSeconds = 60)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $started = $false
    while ((Get-Date) -lt $deadline) {
        $svc = Get-Service -Name 'LabDesk' -ErrorAction SilentlyContinue
        if ($svc) {
            if ($svc.Status -eq 'Running') { return $true }
            if (-not $started) {
                $started = $true
                try { Start-Service -Name 'LabDesk' -ErrorAction SilentlyContinue } catch { }
            }
        }
        Start-Sleep -Seconds 2
    }
    return $false
}

$identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Stop-WithError 'must run from an elevated PowerShell session. Right-click PowerShell and choose Run as administrator.'
}

# Windows PowerShell 5.1 still defaults to SSL3/TLS1.0, which github.com refuses.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# PROCESSOR_ARCHITECTURE reports the architecture of the *process*, so a 32-bit
# PowerShell (SysWOW64, which plenty of RMM agents still launch) says x86 on a
# 64-bit machine. PROCESSOR_ARCHITEW6432 is set only in that case and holds the
# real one.
$machineArch = $env:PROCESSOR_ARCHITEW6432
if (-not $machineArch) { $machineArch = $env:PROCESSOR_ARCHITECTURE }

# Select the setup entry point; its filename enables installer mode in the client.
switch ($machineArch) {
    'AMD64' { $assetPattern = '^LabDesk-.*-x86_64-install\.exe$' }
    'ARM64' { $assetPattern = '^LabDesk-.*-aarch64-install\.exe$' }
    default { Stop-WithError "unsupported architecture '$machineArch'. LabDesk ships x86_64 and ARM64 builds." }
}

# /releases/latest is not the newest release. It reports the newest release that
# is not marked pre-release, so it skips every pre-release however recent, and
# the setup binaries have so far only ever been published on pre-releases. Ask
# for the release list instead and pick the newest one that actually carries the
# asset this script needs, rather than trusting a single endpoint to point at a
# release that happens to have it.
Write-Step "looking for the newest release of $repo with a Windows installer for $machineArch"
try {
    $releases = @(Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases?per_page=100" -Headers @{ 'User-Agent' = 'labdesk-installer' })
} catch {
    $status = $null
    if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
    if ($status -eq 403 -or $status -eq 429) {
        Stop-WithError @"
GitHub rate-limited this address (HTTP $status). The API allows 60 unauthenticated
requests an hour per IP, so imaging several machines behind one address can hit it.
Wait and retry, or download the installer by hand:
  https://github.com/$repo/releases
"@
    }
    Stop-WithError "could not reach the GitHub API: $($_.Exception.Message)"
}

# GitHub returns the list newest first, but sort on the date rather than rely on
# that. Draft releases are not returned to an unauthenticated caller, so every
# release considered here is one somebody published.
$candidates = @(
    $releases |
        Where-Object { @($_.assets | Where-Object { $_.name -match $assetPattern }).Count -gt 0 } |
        Sort-Object -Property { [datetime]$_.created_at } -Descending
)

# Prefer a full release and take a pre-release only when no full release carries
# the installer, so this starts using stable builds by itself as soon as one
# ships the setup binary. Say which was chosen either way.
$release = $candidates | Where-Object { -not $_.prerelease } | Select-Object -First 1
if (-not $release) {
    $release = $candidates | Select-Object -First 1
    if ($release) {
        Write-Warn "no full release carries a Windows installer for $machineArch, so this will install the pre-release $($release.tag_name)."
    }
}
if (-not $release) {
    Stop-WithError @"
no release of $repo publishes a Windows installer for $machineArch.
This script installs LabDesk-<version>-$(if ($machineArch -eq 'ARM64') { 'aarch64' } else { 'x86_64' })-install.exe and nothing else,
See available release assets:
  https://github.com/$repo/releases
"@
}

$asset = $release.assets | Where-Object { $_.name -match $assetPattern } | Select-Object -First 1
Write-Step "using release $($release.tag_name)"

# The assets carry the application version rather than the release
# tag, and that version is what the installer writes to the registry. Reading it
# back afterwards is the only way to tell a finished install from one that
# changed nothing.
if ($asset.name -match '(\d+\.\d+\.\d+)') {
    $expectedVersion = $Matches[1]
} else {
    Stop-WithError "could not read a version out of the asset name '$($asset.name)'."
}

# The download URL comes out of an API response, so check it points where it
# should before running it elevated. Release assets are always served from these
# two hosts.
$downloadUrl = $asset.browser_download_url
if ($downloadUrl -notlike "https://github.com/$repo/releases/download/*" -and
    $downloadUrl -notlike 'https://objects.githubusercontent.com/*') {
    Stop-WithError @"
refusing to install from an unexpected location:
  $downloadUrl
Release assets should come from github.com/$repo.
"@
}

if (Get-Process -Name 'LabDesk' -ErrorAction SilentlyContinue) {
    Write-Warn 'LabDesk is running. The installer will try to replace files that are in use; close it first if the install fails.'
}

$installer = Join-Path ([IO.Path]::GetTempPath()) $asset.name
Write-Step "downloading $($asset.name) ($([math]::Round($asset.size / 1MB, 1)) MB)"
try {
    Invoke-WebRequest -Uri $downloadUrl -OutFile $installer -UseBasicParsing
} catch {
    Stop-WithError "download failed: $($_.Exception.Message)"
}

# LabDesk.exe is a GUI-subsystem binary, so the call operator returns immediately
# and $LASTEXITCODE would hold whatever the previous command left behind. Every
# invocation below goes through Start-Process -Wait for that reason. Output is
# redirected to a file because a GUI binary has no console to write to, though it
# does write to a handle it is handed. Redirecting forces UseShellExecute=$false,
# under which the window cannot be hidden, so each call may flash briefly.
function Invoke-LabDesk {
    param([string]$Exe, [string[]]$Arguments)
    $out = [IO.Path]::GetTempFileName()
    $err = [IO.Path]::GetTempFileName()
    try {
        # Windows PowerShell joins an -ArgumentList array with spaces and does not
        # quote the parts, so a value containing a space would arrive as two
        # arguments. Quote each one here instead.
        $quoted = ($Arguments | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join ' '
        $p = Start-Process -FilePath $Exe -ArgumentList $quoted -Wait -PassThru `
            -RedirectStandardOutput $out -RedirectStandardError $err
        [PSCustomObject]@{
            ExitCode = $p.ExitCode
            Output   = (Get-Content $out -Raw -ErrorAction SilentlyContinue)
        }
    } finally {
        Remove-Item $out, $err -Force -ErrorAction SilentlyContinue
    }
}

$priorVersion = (Get-ItemProperty -Path $uninstallKey -Name DisplayVersion -ErrorAction SilentlyContinue).DisplayVersion
if ($priorVersion) { Write-Step "found LabDesk $priorVersion already installed" }

try {
    Write-Step 'installing (this takes a minute)'
    $process = Start-Process -FilePath $installer -ArgumentList '--silent-install' -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        Stop-WithError "the installer exited with code $($process.ExitCode)."
    }

    # Wait for the registry to report the version that was just installed.
    # Waiting on InstallLocation alone would be satisfied immediately by an
    # earlier install, so a failed upgrade would report success.
    $installPath = $null
    $installedVersion = $null
    foreach ($attempt in 1..30) {
        $entry = Get-ItemProperty -Path $uninstallKey -ErrorAction SilentlyContinue
        $installPath = $entry.InstallLocation
        $installedVersion = $entry.DisplayVersion
        if ($installPath -and (Test-VersionMatch $installedVersion $expectedVersion)) { break }
        Start-Sleep -Seconds 1
    }
    if (-not $installPath) {
        Stop-WithError 'the installer finished but no LabDesk installation was registered.'
    }
    if (-not (Test-VersionMatch $installedVersion $expectedVersion)) {
        Stop-WithError @"
the installer exited cleanly but the registry still reports version
'$installedVersion' instead of '$expectedVersion', so the install did not take.
This usually means files were in use. Close LabDesk and run this again.
"@
    }

    $exe = Join-Path $installPath 'LabDesk.exe'
    if (-not (Test-Path $exe)) {
        Stop-WithError "expected $exe to exist after installing."
    }
    Write-Step "installed $installedVersion to $installPath"
    if ($priorVersion -eq $expectedVersion) {
        Write-Warn "version $expectedVersion was already installed, so this run cannot prove it replaced anything. The installer reported success."
    }

    $settings = [ordered]@{
        'custom-rendezvous-server' = $Server
        'relay-server'             = $Relay
        'api-server'               = $Api
        'key'                      = $Key
    }
    if (@($settings.Values | Where-Object { $_ }).Count -gt 0) {
        if (-not (Wait-LabDeskService)) {
            Stop-WithError @"
LabDesk installed, but its service did not reach Running within 60 seconds.
Settings are written through that service, so none were applied. Start it and
set them by hand:
  Start-Service LabDesk
  & '$exe' --option custom-rendezvous-server <host>
"@
        }
        $applied = @()
        $failed = @()
        foreach ($name in $settings.Keys) {
            $value = $settings[$name]
            if (-not $value) { continue }
            $null = Invoke-LabDesk -Exe $exe -Arguments @('--option', $name, $value)
            # An exit code is not trustworthy evidence here, so read the setting
            # back and compare. Anything else reports success on a silent no-op.
            $readback = (Invoke-LabDesk -Exe $exe -Arguments @('--option', $name)).Output
            # Compare the last non-empty line, not the whole stream: the binary
            # prints the value on its own line, but anything it logs first would
            # otherwise turn a correct setting into a reported failure. -ceq
            # because a server key is base64 and case is significant.
            $actual = $null
            if ($readback) {
                $actual = ($readback -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
                if ($actual) { $actual = $actual.Trim() }
            }
            if ($actual -cne $null -and $actual -ceq $value) {
                $applied += $name
            } else {
                $failed += $name
            }
        }
        if ($applied) { Write-Step "applied: $($applied -join ', ')" }
        if ($failed) {
            Write-Warn @"
could not apply: $($failed -join ', ')
The client is installed but only partly pointed at your server. Settings are
written through the LabDesk service, so make sure it is running and set them
by hand:
  & '$exe' --option custom-rendezvous-server <host>
"@
        }
    } else {
        Write-Step 'no server settings given, so none were changed'
    }

    Write-Step 'done. LabDesk is in the Start menu.'
} finally {
    Remove-Item $installer -Force -ErrorAction SilentlyContinue
}
