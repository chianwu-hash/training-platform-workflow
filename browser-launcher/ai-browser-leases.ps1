function Invoke-AiBrowserLease {
  [CmdletBinding()]
  param(
    [ValidateSet('Acquire','Heartbeat','Release','Status')][string] $Action,
    [string] $Owner,
    [string] $Instance = 'auto',
    [string] $LeaseId,
    [int] $WorkerProcessId = 0,
    [string] $StateDir = (Join-Path $PSScriptRoot 'state'),
    [string] $ConfigPath = (Join-Path $PSScriptRoot 'ai-browser-config.json')
  )
  $ErrorActionPreference = 'Stop'
  $Configuration = Get-Content -LiteralPath $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json
  $Pool = @($Configuration.allocation.pool)
  $LeaseSeconds = [int] $Configuration.allocation.leaseSeconds
  if (-not $Pool.Count -or $LeaseSeconds -lt 1) { throw 'Invalid allocation configuration.' }
  if (@($Pool | Select-Object -Unique).Count -ne $Pool.Count) { throw 'Allocation pool contains duplicates.' }
  foreach ($PoolInstance in $Pool) {
    if (-not $Configuration.instances.PSObject.Properties[$PoolInstance]) { throw 'Allocation pool contains an unregistered instance.' }
  }
  if ($Action -ne 'Status' -and [string]::IsNullOrWhiteSpace($Owner)) { throw 'A stable conversation owner ID is required.' }
  if ($Instance -ne 'auto' -and -not $Configuration.instances.PSObject.Properties[$Instance]) { throw 'Unknown browser instance.' }
  New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
  $StatePath = Join-Path $StateDir 'leases.json'
  $LockPath = Join-Path $StateDir 'leases.lock'
  $Lock = $null
  $LockDeadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
  while (-not $Lock) {
    try { $Lock = [IO.File]::Open($LockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
    catch [IO.IOException] {
      if ([DateTimeOffset]::UtcNow -ge $LockDeadline) { throw 'Allocation lock timeout.' }
      Start-Sleep -Milliseconds 100
    }
  }
  try {
    $State = @{ version = 1; leases = @(); bindings = @{} }
    if (Test-Path -LiteralPath $StatePath) {
      $State = Get-Content -LiteralPath $StatePath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -DateKind String
      if ($State.version -ne 1 -or -not $State.ContainsKey('leases') -or -not $State.ContainsKey('bindings')) { throw 'Invalid lease registry; refusing to overwrite.' }
    }
    $Now = [DateTimeOffset]::UtcNow
    $Active = @()
    foreach ($Lease in @($State.leases)) {
      $WorkerAlive = $false
      if ([int] $Lease.WorkerProcessId -gt 0) {
        $Worker = Get-Process -Id ([int] $Lease.WorkerProcessId) -ErrorAction SilentlyContinue
        if ($Worker) { $WorkerAlive = $Worker.StartTime.ToUniversalTime().ToString('o') -eq $Lease.WorkerStartUtc }
      }
      if ([DateTimeOffset]::Parse($Lease.ExpiresUtc) -gt $Now -or $WorkerAlive) { $Active += $Lease }
    }
    if ($Action -eq 'Status') { return [pscustomobject]@{ Action='status'; Pool=$Pool; Leases=$Active; FreeInstances=@($Pool | Where-Object { $_ -notin $Active.Instance }) } }
    $State.leases = $Active
    $Mine = @($Active | Where-Object { $_.Owner -ceq $Owner }) | Select-Object -First 1
    if ($Action -eq 'Release') {
      if (-not $Mine -or -not $LeaseId -or $Mine.LeaseId -cne $LeaseId) { throw 'Release rejected: lease is absent or changed.' }
      if ([int] $Mine.WorkerProcessId -gt 0) {
        $RunningWorker = Get-Process -Id ([int] $Mine.WorkerProcessId) -ErrorAction SilentlyContinue
        if ($RunningWorker -and $RunningWorker.StartTime.ToUniversalTime().ToString('o') -eq $Mine.WorkerStartUtc) { throw 'Stop the registered browser worker before releasing its lease.' }
      }
      $State.leases = @($Active | Where-Object { $_.LeaseId -cne $LeaseId })
      $Result = [pscustomobject]@{ Action='released'; Instance=$Mine.Instance; LeaseId=$LeaseId }
    } else {
      $IsNew = $false
      if ($Action -eq 'Heartbeat') {
        if (-not $Mine -or -not $LeaseId -or $Mine.LeaseId -cne $LeaseId) { throw 'Heartbeat rejected: lease expired or changed; stop browser actions.' }
      } elseif ($Mine) {
        if ($Instance -ne 'auto' -and $Instance -ne $Mine.Instance) { throw 'Conversation already owns another instance; release it before switching.' }
        if ($LeaseId -and $LeaseId -cne $Mine.LeaseId) { throw 'Lease token changed; stop browser actions.' }
      } else {
        if ($LeaseId) { throw 'Previous lease expired; do not silently acquire a different instance.' }
        $Candidates = if ($Instance -eq 'auto') { $Pool } else { @($Instance) }
        if ($Instance -eq 'auto' -and $State.bindings.ContainsKey($Owner) -and $State.bindings[$Owner] -in $Pool) {
          $Preferred = $State.bindings[$Owner]
          $Candidates = @($Preferred) + @($Pool | Where-Object { $_ -ne $Preferred })
        }
        $Chosen = @($Candidates | Where-Object { $_ -notin $Active.Instance }) | Select-Object -First 1
        if (-not $Chosen) { return [pscustomobject]@{ Action='busy'; RetryAfterSeconds=8; Pool=$Candidates } }
        $Mine = @{ Owner=$Owner; Instance=[string]$Chosen; LeaseId=[Guid]::NewGuid().ToString(); WorkerProcessId=0; WorkerStartUtc=$null }
        $State.leases += $Mine
        $State.bindings[$Owner] = [string] $Chosen
        $IsNew = $true
      }
      if ($WorkerProcessId -gt 0) {
        $Worker = Get-Process -Id $WorkerProcessId -ErrorAction Stop
        if ([int]$Mine.WorkerProcessId -gt 0 -and [int]$Mine.WorkerProcessId -ne $WorkerProcessId) {
          $OldWorker = Get-Process -Id ([int]$Mine.WorkerProcessId) -ErrorAction SilentlyContinue
          if ($OldWorker -and $OldWorker.StartTime.ToUniversalTime().ToString('o') -eq $Mine.WorkerStartUtc) { throw 'Another worker is still registered for this lease.' }
        }
        $Mine.WorkerProcessId = $WorkerProcessId
        $Mine.WorkerStartUtc = $Worker.StartTime.ToUniversalTime().ToString('o')
      }
      $Mine.HeartbeatUtc = $Now.ToString('o')
      $Mine.ExpiresUtc = $Now.AddSeconds($LeaseSeconds).ToString('o')
      $Port = [int] $Configuration.instances.PSObject.Properties[$Mine.Instance].Value.port
      $Result = [pscustomobject]@{ Action=if($IsNew){'acquired'}else{'renewed'}; Instance=$Mine.Instance; LeaseId=$Mine.LeaseId; ExpiresUtc=$Mine.ExpiresUtc; CdpUrl="http://127.0.0.1:$Port"; IsNew=$IsNew }
    }
    $TempPath = Join-Path $StateDir ([Guid]::NewGuid().ToString()+'.tmp')
    try {
      [IO.File]::WriteAllText($TempPath,($State | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
      [IO.File]::Move($TempPath,$StatePath,$true)
    } finally { if (Test-Path -LiteralPath $TempPath) { Remove-Item -LiteralPath $TempPath } }
    return $Result
  } finally { $Lock.Dispose() }
}
