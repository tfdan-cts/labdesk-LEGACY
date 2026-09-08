param([Parameter(Mandatory=$true)][string]$Executable)
$ErrorActionPreference = 'Stop'
$file = Get-Item -LiteralPath $Executable
$version = $file.VersionInfo.FileVersion
if ($version -notmatch '^\d+\.\d+\.\d+\.\d+$' -or [version]$version -eq [version]'0.0.0.0') {
    throw 'The bundled VPN executable requires a nonzero Windows file version for safe MSI upgrades.'
}
$cliVersion = (& $file.FullName version | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $cliVersion -notmatch '^(\d+\.\d+\.\d+)(?:-labdesk\.(\d+))?$') {
    throw 'The bundled VPN executable did not report a supported release version.'
}
$revision = if ($Matches[2]) { $Matches[2] } else { '0' }
if ($version -ne ($Matches[1]+'.'+$revision)) {
    throw 'VPN command-line and Windows file versions disagree.'
}
[pscustomobject]@{ result='PASS'; fileVersion=$version; cliVersion=$cliVersion; sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash } | ConvertTo-Json -Compress
