[CmdletBinding()]
param(
  [Parameter(Position = 0)][string] $Url,
  [string] $Instance,
  [string] $Owner = $env:CODEX_THREAD_ID,
  [string] $LeaseId,
  [switch] $Acquire,
  [switch] $Heartbeat,
  [switch] $Release,
  [switch] $LeaseStatus,
  [int] $WorkerProcessId = 0,
  [ValidateRange(0,30)][int] $WaitSeconds = 0,
  [switch] $Status,
  [switch] $Json
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ai-browser-leases.ps1')
function Write-LaunchResult($Value) {
  if ($Json) { $Value | ConvertTo-Json -Depth 8 } else { $Value }
}
$Controls = @($Heartbeat,$Release,$LeaseStatus | Where-Object { $_ })
if ($Controls.Count -gt 1) { throw 'Choose only one lease control action.' }
if (($Heartbeat -or $Release -or $LeaseStatus) -and ($Url -or $Acquire -or $Status)) { throw 'Lease control actions cannot open pages or launch browsers.' }
if ($LeaseStatus) {
  Write-LaunchResult (Invoke-AiBrowserLease -Action Status)
  exit 0
}
if ($Heartbeat -or $Release) {
  $Action = if ($Heartbeat) { 'Heartbeat' } else { 'Release' }
  Write-LaunchResult (Invoke-AiBrowserLease -Action $Action -Owner $Owner -LeaseId $LeaseId -WorkerProcessId $WorkerProcessId)
  exit 0
}
# Read-only status never allocates a browser.
if ($Status -and -not $Acquire) {
  if (-not $Instance -or $Instance -eq 'auto') {
    $Snapshot = Invoke-AiBrowserLease -Action Status
    $Mine = @($Snapshot.Leases | Where-Object { $_.Owner -ceq $Owner }) | Select-Object -First 1
    $Instance = if ($Mine) { $Mine.Instance } else { 'main' }
  }
  & (Join-Path $PSScriptRoot 'ai-browser-engine.ps1') -Instance $Instance -Status -Json:$Json
  exit $LASTEXITCODE
}
if (-not $Instance) { $Instance = if ($Owner -or $Acquire) { 'auto' } else { 'main' } }
$Lease = $null
if ($Owner -or $Acquire -or $Instance -eq 'auto') {
  $Deadline = [DateTimeOffset]::UtcNow.AddSeconds($WaitSeconds)
  do {
    $Lease = Invoke-AiBrowserLease -Action Acquire -Owner $Owner -Instance $Instance -LeaseId $LeaseId -WorkerProcessId $WorkerProcessId
    if ($Lease.Action -ne 'busy') { break }
    if ([DateTimeOffset]::UtcNow -ge $Deadline) {
      Write-LaunchResult $Lease
      exit 2
    }
    Start-Sleep -Milliseconds ([Math]::Min(8000,[Math]::Max(1,($Deadline-[DateTimeOffset]::UtcNow).TotalMilliseconds)))
  } while ($true)
  $Instance = $Lease.Instance
}
try {
  $EngineArgs = @{ Instance=$Instance; Json=$true }
  if ($Url) { $EngineArgs.Url=$Url }
  if ($Status) { $EngineArgs.Status=$true }
  # Isolate the engine's exit statements from this wrapper.
  # Captured native pipelines can keep waiting on inherited handles after Chrome
  # starts. Redirect to files and wait only for the engine process, not its tree.
  $RunId = [Guid]::NewGuid().ToString('N')
  $LogDir = Join-Path $PSScriptRoot 'logs'
  [void](New-Item -ItemType Directory -Path $LogDir -Force)
  $OutFile = Join-Path $LogDir "launch-$RunId.stdout.json"
  $ErrFile = Join-Path $LogDir "launch-$RunId.stderr.txt"
  $ArgsJson = $EngineArgs | ConvertTo-Json -Compress
  $ArgsBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($ArgsJson))
  $EnginePath = (Join-Path $PSScriptRoot 'ai-browser-engine.ps1').Replace("'", "''")
  $EngineCommand = "[Console]::OutputEncoding = [Text.UTF8Encoding]::new(`$false); `$OutputEncoding = [Console]::OutputEncoding; `$a = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$ArgsBase64')) | ConvertFrom-Json -AsHashtable; & '$EnginePath' @a; exit `$LASTEXITCODE"
  $EncodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($EngineCommand))
  $EngineProcess = Start-Process -FilePath (Get-Command pwsh).Source -ArgumentList @('-NoProfile','-EncodedCommand',$EncodedCommand) -WindowStyle Hidden -RedirectStandardOutput $OutFile -RedirectStandardError $ErrFile -PassThru
  if (-not $EngineProcess.WaitForExit(30000)) {
    # Stop the wrapper only; Chrome and the user's tabs remain available.
    Stop-Process -Id $EngineProcess.Id -ErrorAction SilentlyContinue
    throw "Browser engine did not return within 30 seconds. Diagnostics: $ErrFile"
  }
  $EngineProcess.Refresh()
  if ($EngineProcess.ExitCode -ne 0) { throw "Browser launch failed. Diagnostics: $ErrFile" }
  $EngineOutput = Get-Content -LiteralPath $OutFile -Encoding utf8
  $Result = ($EngineOutput -join [Environment]::NewLine) | ConvertFrom-Json
  if ($Lease) {
    $Result | Add-Member -NotePropertyName LeaseId -NotePropertyValue $Lease.LeaseId
    $Result | Add-Member -NotePropertyName ExpiresUtc -NotePropertyValue $Lease.ExpiresUtc
  }
  Write-LaunchResult $Result
} catch {
  if ($Lease -and $Lease.IsNew -and -not $WorkerProcessId) {
    Invoke-AiBrowserLease -Action Release -Owner $Owner -LeaseId $Lease.LeaseId | Out-Null
  }
  throw
}
