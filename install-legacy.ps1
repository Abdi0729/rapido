# holos-agent-legacy installer — Windows Server 2008 / 2008 R2 ONLY.
#
# This installs a SEPARATE service ("HolosAgentLegacy") that does not touch the
# modern "HolosAgent" in any way. Use it only on hosts too old for the modern
# agent (Server 2008 / 2008 R2). Everything else should use install.ps1.
#
# Usage (PowerShell as Administrator):
#   .\install-legacy.ps1 -TenantId acme -ApiKey sk-xxx
#
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TenantId,
    [Parameter(Mandatory = $true)][string]$ApiKey,
    [string]$Endpoint    = "https://collector.holos.tech",
    [string]$Site        = $env:COMPUTERNAME,
    [string]$LocalBinary = ""
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ServiceName = 'HolosAgentLegacy'
$DisplayName = 'Holos Agent (Legacy) - Server 2008 telemetry collector'
$InstallDir  = 'C:\Program Files\Holos\AgentLegacy'
$ConfigDir   = 'C:\ProgramData\Holos\AgentLegacy'
$BinaryPath  = Join-Path $InstallDir 'holos-agent-legacy.exe'
$ConfigPath  = Join-Path $ConfigDir  'config.yaml'
$EnvPath     = Join-Path $ConfigDir  'agent.env'
$ReleaseBase = if ($env:HOLOS_RELEASE_URL) { $env:HOLOS_RELEASE_URL } else { 'https://releases.holos.tech' }

function Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host " ok  $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[!] $m"  -ForegroundColor Yellow }

# Architecture: Server 2008 non-R2 can be 32-bit. The 386 build excludes Sybase.
$arch = if ([Environment]::Is64BitOperatingSystem) { 'amd64' } else { '386' }
Step "Detected OS architecture: $arch"
if ($arch -eq '386') { Warn "32-bit host: the Sybase plugin is not available in this build." }

New-Item -ItemType Directory -Force -Path $InstallDir, $ConfigDir | Out-Null

# Stop existing legacy service (upgrade) before replacing the binary.
$existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existing -and $existing.Status -eq 'Running') {
    Step "Stopping existing $ServiceName for upgrade..."
    Stop-Service -Name $ServiceName -Force
    Start-Sleep -Seconds 2
}

if ($LocalBinary) {
    Step "Installing local binary: $LocalBinary"
    Copy-Item -Path $LocalBinary -Destination $BinaryPath -Force
} else {
    $url = "$ReleaseBase/holos-agent-legacy-windows-$arch.exe"
    Step "Downloading $url"
    Invoke-WebRequest -Uri $url -OutFile "$BinaryPath.new" -UseBasicParsing
    Move-Item -Path "$BinaryPath.new" -Destination $BinaryPath -Force
}
Ok "Binary installed: $BinaryPath"

# agent.env (credentials) — readable only by SYSTEM/Administrators.
Step "Saving credentials..."
"HOLOS_API_KEY=$ApiKey" | Set-Content -Path $EnvPath -Encoding UTF8
$acl = Get-Acl $EnvPath
$acl.SetAccessRuleProtection($true, $false)
$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule('BUILTIN\Administrators','FullControl','Allow')))
$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule('NT AUTHORITY\SYSTEM','FullControl','Allow')))
Set-Acl -Path $EnvPath -AclObject $acl
Ok "Credentials saved to $EnvPath"

# config.yaml — never overwrite an existing one (preserves plugins on upgrade).
if (Test-Path $ConfigPath) {
    Ok "Existing config.yaml kept (plugins preserved)."
} else {
    $queuePath = ($ConfigDir.Replace('\','/')) + '/queue.ndjson'
    @(
        'agent:',
        "  tenant_id:   `"$TenantId`"",
        '  environment: "prod"',
        "  site:        `"$Site`"",
        '  log_level:   "info"',
        '',
        'transport:',
        "  endpoint: `"$Endpoint`"",
        '  tls:',
        '    insecure: false',
        '  queue:',
        '    enabled: true',
        "    path: `"$queuePath`"",
        '    max_size_mb: 500',
        '',
        'collection:',
        '  interval: "30s"',
        '',
        '# Add database plugin blocks here (see holos-agent-legacy.example.yaml).',
        'plugins: []'
    ) -join "`r`n" | Set-Content -Path $ConfigPath -Encoding UTF8
    Ok "config.yaml generated at $ConfigPath"
}

# Install / update the service (own name — never collides with HolosAgent).
$binArgs = "`"$BinaryPath`" --config `"$ConfigPath`""
if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
    sc.exe config $ServiceName binPath= $binArgs | Out-Null
    Ok "Service updated"
} else {
    New-Service -Name $ServiceName -DisplayName $DisplayName -BinaryPathName $binArgs -StartupType Automatic | Out-Null
    Ok "Service '$ServiceName' registered"
}
sc.exe failure $ServiceName reset= 86400 actions= restart/10000/restart/30000/restart/60000 | Out-Null

Step "Starting $ServiceName..."
Restart-Service -Name $ServiceName -Force
Start-Sleep -Seconds 2
if ((Get-Service -Name $ServiceName).Status -eq 'Running') {
    Ok "holos-agent-legacy running"
} else {
    Warn "Service did not start. Check Windows Event Log."
}

Write-Host ""
Write-Host "holos-agent-legacy installed." -ForegroundColor Green
Write-Host "  Service : $ServiceName  (separate from the modern HolosAgent)"
Write-Host "  Config  : $ConfigPath"
Write-Host "  Arch    : $arch$(if ($arch -eq '386') { '  (Sybase not available)' })"
Write-Host "  Add DB plugins by editing config.yaml, then: Restart-Service $ServiceName"
