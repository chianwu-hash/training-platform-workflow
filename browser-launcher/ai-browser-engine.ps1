[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [string] $Url,
  [string] $Instance = 'main',
  [switch] $Status,
  [switch] $Json
)

$ErrorActionPreference = 'Stop'
$ConfigPath = Join-Path $PSScriptRoot 'ai-browser-config.json'

function Get-NormalizedPath {
  param([Parameter(Mandatory)][string] $InputPath)
  return [System.IO.Path]::GetFullPath($InputPath).TrimEnd('\')
}

function Test-CdpEndpoint {
  param([Parameter(Mandatory)][string] $CdpUrl)
  try {
    Invoke-RestMethod -Uri "$CdpUrl/json/version" -TimeoutSec 2 | Out-Null
    return $true
  } catch {
    return $false
  }
}

function Get-ChromeCdpSessions {
  $Processes = @(Get-CimInstance Win32_Process -Filter "name = 'chrome.exe'" -ErrorAction SilentlyContinue)
  foreach ($Process in $Processes) {
    $CommandLine = [string] $Process.CommandLine
    if (-not $CommandLine -or $CommandLine -match ' --type=') {
      continue
    }

    $Profile = $null
    if ($CommandLine -match '--user-data-dir="([^"]+)"') {
      $Profile = $Matches[1]
    } elseif ($CommandLine -match '--user-data-dir=([^\s]+)') {
      $Profile = $Matches[1]
    }

    $Port = $null
    if ($CommandLine -match '--remote-debugging-port=(\d+)') {
      $Port = [int] $Matches[1]
    }

    if ($Profile) {
      [pscustomobject]@{
        ProcessId = $Process.ProcessId
        Profile = Get-NormalizedPath -InputPath $Profile
        Port = $Port
      }
    }
  }
}

function Open-CdpUrl {
  param(
    [Parameter(Mandatory)][string] $CdpUrl,
    [Parameter(Mandatory)][string] $TargetUrl
  )
  $EscapedUrl = [Uri]::EscapeDataString($TargetUrl)
  $OpenedTarget = Invoke-RestMethod -Method Put -Uri "$CdpUrl/json/new?$EscapedUrl" -TimeoutSec 5
  $script:OpenedTargetId = $OpenedTarget.id
}

function Write-Result {
  param([Parameter(Mandatory)] $Value)
  if ($Json) {
    $Value | ConvertTo-Json -Depth 5
  } else {
    $Value
  }
}

if ($PSVersionTable.PSVersion.Major -lt 7) {
  throw 'ai-browser-launch requires PowerShell 7 or newer (pwsh).'
}

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
  throw "AI browser config not found: $ConfigPath"
}

$Config = Get-Content -Raw -Encoding utf8 -LiteralPath $ConfigPath | ConvertFrom-Json
if ($Config.schemaVersion -eq 2) {
  $Selected = $Config.instances.PSObject.Properties[$Instance]
  if (-not $Selected) {
    throw "Unknown browser instance '$Instance'. Configured: $($Config.instances.PSObject.Properties.Name -join ', ')"
  }
  $Names = @($Config.instances.PSObject.Properties.Value.profileName)
  $Ports = @($Config.instances.PSObject.Properties.Value.port)
  if (@($Names | Select-Object -Unique).Count -ne $Names.Count -or @($Ports | Select-Object -Unique).Count -ne $Ports.Count) {
    throw 'Each browser instance must have a unique profile name and port.'
  }
  $Entry = $Selected.Value
  if ([string] $Entry.profileName -notmatch '^ai-work-(main|[0-9]{2,})$') {
    throw 'Invalid configured profile name.'
  }
  $Config.displayName = [string] $Entry.displayName
  $Config.profileName = [string] $Entry.profileName
  $Config.profileDir = Join-Path ([string] $Config.profileRoot) ([string] $Entry.profileName)
  $Config.port = [int] $Entry.port
  $Config.cdpUrl = "http://127.0.0.1:$($Config.port)"
} elseif ($Instance -ne 'main') {
  throw 'This configuration does not support browser instances.'
}
$ExpectedRoot = Get-NormalizedPath -InputPath ([string] $Config.profileRoot)
$ExpectedProfile = Get-NormalizedPath -InputPath ([string] $Config.profileDir)
$ExpectedFromName = Get-NormalizedPath -InputPath (Join-Path $ExpectedRoot ([string] $Config.profileName))
$Port = [int] $Config.port
$CdpUrl = [string] $Config.cdpUrl

if ($ExpectedProfile -ine $ExpectedFromName) {
  throw "Configured profileDir does not match profileRoot/profileName: $ExpectedProfile"
}
if ($Port -lt 1024 -or $Port -gt 65535) {
  throw "Invalid configured CDP port: $Port"
}
if ($CdpUrl -ne "http://127.0.0.1:$Port") {
  throw "Configured cdpUrl does not match port ${Port}: $CdpUrl"
}
if ([bool] $Config.requireExistingProfile -and -not (Test-Path -LiteralPath $ExpectedProfile -PathType Container)) {
  throw "Required AI browser profile does not exist: $ExpectedProfile"
}

$Sessions = @(Get-ChromeCdpSessions)
$ProfileSessions = @($Sessions | Where-Object { $_.Profile -ieq $ExpectedProfile })
$PortSessions = @($Sessions | Where-Object { $_.Port -eq $Port })
$Reachable = Test-CdpEndpoint -CdpUrl $CdpUrl
$MatchedSession = @($PortSessions | Where-Object { $_.Profile -ieq $ExpectedProfile }) | Select-Object -First 1

if ($Status) {
  Write-Result -Value ([pscustomobject]@{
    DisplayName = [string] $Config.displayName
    Instance = $Instance
    Profile = $ExpectedProfile
    Port = $Port
    CdpUrl = $CdpUrl
    Reachable = $Reachable
    ProfileMatched = $null -ne $MatchedSession
    ProcessId = if ($MatchedSession) { $MatchedSession.ProcessId } else { $null }
  })
  exit 0
}

if ($Reachable) {
  if (-not $MatchedSession) {
    throw "CDP port $Port is reachable but is not using the configured profile $ExpectedProfile."
  }
  if ($PSBoundParameters.ContainsKey('Url') -and $Url) {
    Open-CdpUrl -CdpUrl $CdpUrl -TargetUrl $Url
  }
  Write-Result -Value ([pscustomobject]@{
    Action = 'reused'
    Instance = $Instance
    DisplayName = [string] $Config.displayName
    Profile = $ExpectedProfile
    Port = $Port
    CdpUrl = $CdpUrl
    ProcessId = $MatchedSession.ProcessId
    OpenedUrl = if ($PSBoundParameters.ContainsKey('Url')) { $Url } else { $null }
    TargetId = $script:OpenedTargetId
  })
  exit 0
}

if ($PortSessions.Count -gt 0) {
  throw "CDP port $Port is already assigned to another Chrome profile."
}
if ($ProfileSessions.Count -gt 0) {
  $OtherPorts = ($ProfileSessions | ForEach-Object { $_.Port }) -join ', '
  throw "The configured profile is already running on another CDP port: $OtherPorts"
}

$Launcher = Get-Command cdp-launch -ErrorAction SilentlyContinue
if (-not $Launcher) {
  throw 'cdp-launch was not found on PATH.'
}

$TargetUrl = if ($PSBoundParameters.ContainsKey('Url') -and $Url) { $Url } else { [string] $Config.defaultUrl }
$LaunchArgs = @(
  [string] $Config.profileName,
  '--port', [string] $Port,
  '--url', $TargetUrl,
  '--profile-root', $ExpectedRoot,
  '--json'
)
if ([bool] $Config.allowExtensions) {
  $LaunchArgs += '--allow-extensions'
}

$LaunchOutput = @(& $Launcher.Source @LaunchArgs 2>&1)
if ($LASTEXITCODE -ne 0) {
  throw "cdp-launch failed: $($LaunchOutput -join [Environment]::NewLine)"
}

for ($Attempt = 1; $Attempt -le 30; $Attempt++) {
  if (Test-CdpEndpoint -CdpUrl $CdpUrl) {
    break
  }
  Start-Sleep -Milliseconds 500
}
if (-not (Test-CdpEndpoint -CdpUrl $CdpUrl)) {
  throw "Chrome CDP did not become ready at $CdpUrl."
}

$MatchedSession = @(Get-ChromeCdpSessions | Where-Object { $_.Port -eq $Port -and $_.Profile -ieq $ExpectedProfile }) | Select-Object -First 1
if (-not $MatchedSession) {
  throw "Chrome started on port $Port but the configured profile could not be verified."
}

if ($PSBoundParameters.ContainsKey('Url') -and $Url) {
  # The cold launch already passes TargetUrl to Chrome. Bind to that page
  # instead of opening the URL again. If restored tabs make it ambiguous,
  # create one explicit target rather than selecting an arbitrary tab.
  $LaunchTargets = @(Invoke-RestMethod -Uri "$CdpUrl/json/list" -TimeoutSec 5)
  $MatchingTargets = @($LaunchTargets | ForEach-Object { $_ } | Where-Object { $_.type -eq 'page' -and $_.url -eq $TargetUrl })
  if ($MatchingTargets.Count -eq 1) {
    $script:OpenedTargetId = $MatchingTargets[0].id
  } else {
    Open-CdpUrl -CdpUrl $CdpUrl -TargetUrl $TargetUrl
  }
}

Write-Result -Value ([pscustomobject]@{
  Action = 'launched'
  Instance = $Instance
  DisplayName = [string] $Config.displayName
  Profile = $ExpectedProfile
  Port = $Port
  CdpUrl = $CdpUrl
  ProcessId = $MatchedSession.ProcessId
  OpenedUrl = $TargetUrl
  TargetId = $script:OpenedTargetId
})
